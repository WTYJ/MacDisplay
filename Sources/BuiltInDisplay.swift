import AppKit
import CoreGraphics
import IOKit
import SwiftUI

/// Runtime lookup keeps the app usable on macOS versions without these symbols.
@MainActor
private final class DisplayConnectionAPI {
    typealias Configure = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32
    typealias Enumerate = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>) -> Int32
    typealias DisplayInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private let configure: Configure
    private let enumerate: Enumerate
    private let displayInfo: DisplayInfo

    init?() {
        #if arch(arm64)
        // System frameworks stay loaded for the lifetime of the app.
        let coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        let setEnabled = coreGraphics.flatMap { dlsym($0, "CGSConfigureDisplayEnabled") }
            ?? skyLight.flatMap { dlsym($0, "SLSConfigureDisplayEnabled") }
        let list = coreGraphics.flatMap { dlsym($0, "CGSGetDisplayList") }
            ?? skyLight.flatMap { dlsym($0, "SLSGetDisplayList") }
        guard let setEnabled, let list,
              let info = coreDisplay.flatMap({ dlsym($0, "CoreDisplay_DisplayCreateInfoDictionary") }) else {
            return nil
        }
        configure = unsafeBitCast(setEnabled, to: Configure.self)
        enumerate = unsafeBitCast(list, to: Enumerate.self)
        displayInfo = unsafeBitCast(info, to: DisplayInfo.self)
        #else
        return nil
        #endif
    }

    func builtInID() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard enumerate(UInt32(ids.count), &ids, &count) == 0 else { return nil }
        let builtIn = ids.prefix(Int(count)).filter { $0 != 0 && CGDisplayIsBuiltin($0) != 0 }
        return builtIn.count == 1 ? builtIn[0] : nil
    }

    func isUsableExternal(_ display: Display) -> Bool {
        guard !display.isBuiltIn, CGDisplayIsAsleep(display.id) == 0,
              CGDisplayIsInMirrorSet(display.id) == 0,
              let info = displayInfo(display.id)?.takeRetainedValue() as? [String: Any],
              let location = info["IODisplayLocation"] as? String else { return false }
        let service = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
        guard service != IO_OBJECT_NULL else { return false }
        IOObjectRelease(service)
        return true
    }

    func setEnabled(_ enabled: Bool, id: CGDirectDisplayID) throws {
        guard id != 0, CGDisplayIsBuiltin(id) != 0 else {
            throw DisplayFailure("系统没有确认目标是内建屏。")
        }
        var configuration: CGDisplayConfigRef?
        let start = CGBeginDisplayConfiguration(&configuration)
        guard start == .success, let configuration else {
            throw DisplayFailure("无法开始修改显示器配置（\(start.rawValue)）。")
        }
        let result = configure(configuration, id, enabled)
        guard result == 0 else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayFailure("macOS 拒绝了显示器连接操作（\(result)）。")
        }
        let commit = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard commit == .success else {
            throw DisplayFailure("无法应用显示器配置（\(commit.rawValue)）。")
        }
    }
}

@MainActor
final class BuiltInDisplay: ObservableObject {
    static let confirmationDuration: TimeInterval = 10

    enum State: Equatable {
        case unavailable(String)
        case connected
        case disconnected
        case switching
        case trial
    }

    private enum Phase {
        case disconnecting(Date)
        case trial(Date)
        case disconnected
        case waitingForLid
        case reconnecting(Date)
        case recoveryFailed
    }

    @Published private(set) var state: State = .unavailable("正在检查显示器。")
    @Published private(set) var message: String?

    var isTransitioning: Bool { state == .switching || state == .trial }

    private let api = DisplayConnectionAPI()
    private let isBaseM3: Bool = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 1 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return false }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) == "Apple M3"
    }()

    private var managedID: CGDirectDisplayID?
    private var phase: Phase?
    private var monitor: Task<Void, Never>?

    private var lidClosed: Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    private var activeBuiltIn: Display? {
        try? Display.active().first { $0.isBuiltIn }
    }

    private var hasUsableExternal: Bool {
        !usableExternals.isEmpty
    }

    private var usableExternals: [Display] {
        guard let api, let displays = try? Display.active() else { return [] }
        return displays.filter { api.isUsableExternal($0) }
    }

    var confirmationScreen: NSScreen? {
        usableExternals.lazy.compactMap { Display.screen(for: $0.id) }.first
    }

    func confirmationSecondsRemaining(at date: Date) -> Int {
        guard case .trial(let deadline) = phase else { return 0 }
        return max(0, Int(ceil(deadline.timeIntervalSince(date))))
    }

    private func updateState(_ newState: State) {
        if state != newState { state = newState }
    }

    var diagnostics: [String] {
        [
            "connection-api: \(api == nil ? "unavailable" : "available")",
            "lid: \(lidClosed.map { $0 ? "closed" : "open" } ?? "unknown")",
            "built-in-enumerated: \(api?.builtInID().map(String.init) ?? "none")",
            "built-in-active: \(activeBuiltIn?.id.description ?? "none")",
            "usable-external: \(hasUsableExternal)",
            "state: \(state)"
        ]
    }

    func refresh() {
        guard let api, let closed = lidClosed else {
            updateState(.unavailable("需要支持显示器软断开的 Apple Silicon MacBook。"))
            return
        }
        if closed {
            if managedID != nil {
                phase = .waitingForLid
                updateState(.unavailable("已合盖，重新开盖后将尝试恢复内建屏。"))
            } else {
                updateState(.unavailable("MacBook 已合盖。"))
            }
            return
        }

        let active = activeBuiltIn
        let now = Date()
        switch phase {
        case .disconnecting(let deadline):
            if active == nil {
                if !hasUsableExternal {
                    reconnect()
                    return
                }
                phase = .trial(now.addingTimeInterval(Self.confirmationDuration))
                updateState(.trial)
                return
            }
            if now < deadline { return }
            finish()
            message = "系统仍将内建屏列为活动显示器。"
        case .trial(let deadline):
            if active == nil {
                if now >= deadline || !hasUsableExternal { reconnect() }
                return
            }
            finish()
            message = "内建屏已恢复。"
        case .disconnected:
            if active == nil {
                if !hasUsableExternal { reconnect() }
                else { updateState(.disconnected) }
                return
            }
            finish()
            message = "内建屏已恢复。"
        case .waitingForLid:
            if active == nil {
                reconnect()
                return
            }
            finish()
            message = "开盖后内建屏已恢复。"
        case .reconnecting(let deadline):
            if active == nil {
                if now < deadline { return }
                phase = .recoveryFailed
                stopMonitoring()
                message = "macOS 尚未恢复内建屏。可重试，或保持外屏连接并合盖后再开盖。"
            } else {
                finish()
                message = "内建屏已恢复。"
            }
        case .recoveryFailed:
            if active != nil {
                finish()
                message = "内建屏已恢复。"
            }
        case nil:
            break
        }

        if let active {
            if isBaseM3 {
                updateState(.unavailable("基础款 Apple M3 的内建屏可能需要重启才能恢复。"))
            } else if CGDisplayIsInMirrorSet(active.id) != 0 {
                updateState(.unavailable("请先退出内建屏镜像。"))
            } else if !hasUsableExternal {
                updateState(.unavailable("请先连接一台正在显示扩展桌面的实体外屏。"))
            } else {
                updateState(.connected)
            }
        } else if api.builtInID() != nil || managedID != nil {
            updateState(.disconnected)
        } else {
            updateState(.unavailable("系统尚未找到可控制的内建显示器。"))
        }
    }

    func disconnect() {
        refresh()
        guard state == .connected, let api, let display = activeBuiltIn else { return }
        message = nil
        do {
            try api.setEnabled(false, id: display.id)
            managedID = display.id
            phase = .disconnecting(Date().addingTimeInterval(4))
            updateState(.switching)
            startMonitoring()
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func keepDisconnected() {
        guard case .trial(let deadline) = phase, Date() < deadline, hasUsableExternal,
              lidClosed == false, activeBuiltIn == nil else {
            refresh()
            return
        }
        phase = .disconnected
        updateState(.disconnected)
    }

    func reconnect() {
        guard let api, lidClosed == false else { return }
        if activeBuiltIn != nil {
            finish()
            refresh()
            return
        }
        let original = managedID.flatMap { CGDisplayIsBuiltin($0) != 0 ? $0 : nil }
        guard let id = api.builtInID() ?? original else {
            phase = .recoveryFailed
            stopMonitoring()
            updateState(.disconnected)
            message = "系统没有找到内建屏。请保持外屏连接并合盖后再开盖。"
            return
        }
        do {
            try api.setEnabled(true, id: id)
            managedID = id
            phase = .reconnecting(Date().addingTimeInterval(5))
            updateState(.switching)
            startMonitoring()
            refresh()
        } catch {
            phase = .recoveryFailed
            stopMonitoring()
            updateState(.disconnected)
            message = error.localizedDescription
        }
    }

    func restoreOnQuit() {
        guard managedID != nil else { return }
        reconnect()
        stopMonitoring()
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }

    private func finish() {
        managedID = nil
        phase = nil
        stopMonitoring()
    }

    private func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }
}
