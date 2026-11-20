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

    private func displayIDs() -> [CGDirectDisplayID]? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard enumerate(UInt32(ids.count), &ids, &count) == 0 else { return nil }
        return ids.prefix(Int(count)).filter { $0 != 0 }
    }

    func builtInID() -> CGDirectDisplayID? {
        guard let builtIn = displayIDs()?.filter({ CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        return builtIn.count == 1 ? builtIn[0] : nil
    }

    func externalID(uuid: String) -> CGDirectDisplayID? {
        guard let matches = displayIDs()?.filter({ Display.identifier(for: $0) == uuid }),
              matches.count == 1, let id = matches.first, CGDisplayIsBuiltin(id) == 0 else { return nil }
        return id
    }

    func isExternalMissing(uuid: String, originalID: CGDirectDisplayID) -> Bool {
        guard let ids = displayIDs() else { return false }
        return ids.allSatisfy { id in
            if let identifier = Display.identifier(for: id) { return identifier != uuid }
            return id != originalID
        }
    }

    func isUsableExternal(_ display: Display) -> Bool {
        CGDisplayIsAsleep(display.id) == 0 && CGDisplayIsInMirrorSet(display.id) == 0
            && physicalExternalLocation(display.id) != nil
    }

    func physicalExternalLocation(_ id: CGDirectDisplayID) -> String? {
        guard id != 0, CGDisplayIsBuiltin(id) == 0,
              let info = displayInfo(id)?.takeRetainedValue() as? [String: Any],
              let location = info["IODisplayLocation"] as? String,
              isExternalAttached(at: location) else { return nil }
        return location
    }

    func isExternalAttached(at location: String) -> Bool {
        let service = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
        guard service != IO_OBJECT_NULL else { return false }
        IOObjectRelease(service)
        return true
    }

    func setEnabled(_ enabled: Bool, id: CGDirectDisplayID, externalUUID: String? = nil) throws {
        if let externalUUID {
            guard externalID(uuid: externalUUID) == id, enabled || physicalExternalLocation(id) != nil else {
                throw DisplayFailure("系统无法确认目标外接显示器。")
            }
        } else {
            guard id != 0, CGDisplayIsBuiltin(id) != 0 else {
                throw DisplayFailure("系统没有确认目标是内建屏。")
            }
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
final class DisplayConnection: ObservableObject {
    static let confirmationDuration: TimeInterval = 15
    private static let recoveryDuration: TimeInterval = 10
    private static let retryInterval: TimeInterval = 1.5

    enum State: Equatable {
        case unavailable(String)
        case connected
        case disconnected
        case switching
        case trial
    }

    enum Target {
        case builtIn
        case external
    }

    private enum Phase {
        case disconnecting(Date)
        case trial(Date)
        case disconnected
        case waitingForLid
        case reconnecting(deadline: Date, nextAttempt: Date)
        case recoveryFailed
    }

    private struct ManagedExternal {
        let id: CGDirectDisplayID
        let uuid: String
        let name: String
        let location: String
        var wasAttachedWhileInactive = false
    }

    @Published private(set) var state: State = .unavailable("正在检查显示器。")
    @Published private(set) var message: String?

    var isTransitioning: Bool { state == .switching || state == .trial }
    var isManaged: Bool { phase != nil }
    var name: String { target == .builtIn ? "内建屏" : managedExternal?.name ?? "外屏" }

    let target: Target
    private static let api = DisplayConnectionAPI()
    private var api: DisplayConnectionAPI? { Self.api }
    private let isBaseM3: Bool = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 1 else { return false }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return false }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) == "Apple M3"
    }()

    private var managedID: CGDirectDisplayID?
    private var managedExternal: ManagedExternal?
    private var phase: Phase?
    private var monitor: Task<Void, Never>?

    init(target: Target) {
        self.target = target
    }

    private var lidClosed: Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    private func activeTarget(in displays: [Display]) -> Display? {
        switch target {
        case .builtIn:
            return displays.first(where: \.isBuiltIn)
        case .external:
            guard let uuid = managedExternal?.uuid else { return Display.menuExternal(in: displays) }
            return displays.first { !$0.isBuiltIn && $0.uuid == uuid }
        }
    }

    private func usableBuiltIn(in displays: [Display]) -> NSScreen? {
        guard let display = displays.first(where: \.isBuiltIn),
              CGDisplayIsAsleep(display.id) == 0, CGDisplayIsInMirrorSet(display.id) == 0 else { return nil }
        return Display.screen(for: display.id)
    }

    private func hasSurvivor(in displays: [Display], api: DisplayConnectionAPI) -> Bool {
        switch target {
        case .builtIn: displays.contains(where: api.isUsableExternal)
        case .external: usableBuiltIn(in: displays) != nil
        }
    }

    var confirmationScreen: NSScreen? {
        guard let api, let displays = try? Display.active() else { return nil }
        switch target {
        case .builtIn:
            return displays.lazy.filter(api.isUsableExternal).compactMap { Display.screen(for: $0.id) }.first
        case .external:
            return usableBuiltIn(in: displays)
        }
    }

    func confirmationSecondsRemaining(at date: Date) -> Int {
        guard case .trial(let deadline) = phase else { return 0 }
        return max(0, Int(ceil(deadline.timeIntervalSince(date))))
    }

    private func updateState(_ newState: State) {
        if state != newState { state = newState }
    }

    var diagnostics: [String] {
        let displays = try? Display.active()
        return [
            "connection-api: \(api == nil ? "unavailable" : "available")",
            "lid: \(lidClosed.map { $0 ? "closed" : "open" } ?? "unknown")",
            "built-in-enumerated: \(api?.builtInID().map(String.init) ?? "none")",
            "built-in-active: \(displays?.first(where: \.isBuiltIn)?.id.description ?? "none")",
            "usable-external: \(displays?.contains(where: { api?.isUsableExternal($0) == true }) == true)",
            "state: \(state)"
        ]
    }

    func refresh() {
        refresh(displays: try? Display.active())
    }

    func refresh(displays: [Display]?) {
        guard let api else {
            updateState(.unavailable("需要支持显示器软断开的 Apple Silicon MacBook。"))
            return
        }
        let closed = lidClosed
        if target == .builtIn, closed != false {
            if phase != nil {
                phase = .waitingForLid
                updateState(.unavailable("已合盖，重新开盖后将尝试恢复内建屏。"))
                startMonitoring()
            } else if closed == true {
                updateState(.unavailable("MacBook 已合盖。"))
            } else {
                updateState(.unavailable("无法读取 MacBook 上盖状态。"))
            }
            return
        }

        let active = displays.flatMap { activeTarget(in: $0) }
        if let displays, active == nil, let external = managedExternal {
            if api.isExternalAttached(at: external.location) {
                // Verify that this registry entry survives soft disconnection before using its loss as evidence.
                managedExternal?.wasAttachedWhileInactive = true
            } else if external.wasAttachedWhileInactive,
                      api.isExternalMissing(uuid: external.uuid, originalID: external.id) {
                finish()
                message = nil
                refreshExternalAvailability(displays: displays, lidClosed: closed, api: api)
                return
            }
        }
        let hasSurvivor = displays.map { hasSurvivor(in: $0, api: api) }
        let now = Date()
        if target == .external, closed != false {
            switch phase {
            case .disconnecting, .trial, .disconnected:
                beginRecovery(api, now: now)
                return
            default:
                break
            }
        }
        switch phase {
        case .disconnecting(let deadline):
            if active == nil, let hasSurvivor {
                if hasSurvivor {
                    phase = .trial(now.addingTimeInterval(Self.confirmationDuration))
                    updateState(.trial)
                } else {
                    beginRecovery(api, now: now)
                }
                return
            }
            if now < deadline { return }
            if displays == nil {
                beginRecovery(api, now: now)
                return
            }
            let notice = "系统仍将\(name)列为活动显示器。"
            finish()
            message = notice
        case .trial, .disconnected:
            if active == nil {
                let timedOut: Bool
                if case .trial(let deadline) = phase {
                    timedOut = now >= deadline
                } else {
                    timedOut = false
                }
                if timedOut || hasSurvivor == false {
                    beginRecovery(api, now: now)
                } else if case .trial = phase {
                    updateState(.trial)
                } else {
                    updateState(.disconnected)
                }
                return
            }
            finishRecovery()
        case .waitingForLid:
            if active == nil {
                beginRecovery(api, now: now)
                return
            }
            finishRecovery("开盖后内建屏已恢复。")
        case .reconnecting(let deadline, let nextAttempt):
            if active == nil {
                if now < deadline {
                    if now >= nextAttempt { attemptRecovery(api, now: now, deadline: deadline) }
                    return
                }
                phase = .recoveryFailed
                if target == .builtIn { stopMonitoring() }
                message = target == .builtIn
                    ? "macOS 尚未恢复内建屏。可重试，或保持外屏连接并合盖后再开盖。"
                    : "macOS 尚未恢复\(name)。可重试，或重新插拔显示器连接线。"
            } else {
                finishRecovery()
            }
        case .recoveryFailed:
            if active != nil { finishRecovery() }
        case nil:
            break
        }

        if target == .external {
            refreshExternalAvailability(displays: displays, lidClosed: closed, api: api)
            return
        }

        if let active {
            if isBaseM3 {
                updateState(.unavailable("基础款 Apple M3 的内建屏可能需要重启才能恢复。"))
            } else if CGDisplayIsInMirrorSet(active.id) != 0 {
                updateState(.unavailable("请先退出内建屏镜像。"))
            } else if hasSurvivor != true {
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

    private func refreshExternalAvailability(
        displays: [Display]?, lidClosed: Bool?, api: DisplayConnectionAPI
    ) {
        if managedExternal != nil {
            updateState(.disconnected)
        } else if lidClosed != false {
            updateState(.unavailable("请打开 MacBook 上盖。"))
        } else if let displays, usableBuiltIn(in: displays) != nil {
            if let active = Display.menuExternal(in: displays), api.isUsableExternal(active),
               let uuid = active.uuid, api.externalID(uuid: uuid) == active.id {
                updateState(.connected)
            } else {
                updateState(.unavailable("需要可软断开的实体外屏。"))
            }
        } else {
            updateState(.unavailable("请先让 MacBook 内建屏显示扩展桌面。"))
        }
    }

    func disconnect(expectedExternalUUID: String? = nil) {
        let displays = try? Display.active()
        refresh(displays: displays)
        guard state == .connected, let api, let displays, let display = activeTarget(in: displays) else { return }
        let external: ManagedExternal?
        if target == .external {
            guard let uuid = display.uuid, uuid == expectedExternalUUID,
                  let location = api.physicalExternalLocation(display.id) else { return }
            external = ManagedExternal(id: display.id, uuid: uuid, name: display.name, location: location)
        } else {
            external = nil
        }
        message = nil
        do {
            try api.setEnabled(false, id: display.id, externalUUID: external?.uuid)
            if let external {
                managedExternal = external
            } else {
                managedID = display.id
            }
            phase = .disconnecting(Date().addingTimeInterval(4))
            updateState(.switching)
            startMonitoring()
            refresh()
        } catch {
            message = error.localizedDescription
        }
    }

    func keepDisconnected() {
        guard case .trial(let deadline) = phase, Date() < deadline, lidClosed == false,
              let api, let displays = try? Display.active(),
              activeTarget(in: displays) == nil, hasSurvivor(in: displays, api: api) else {
            refresh()
            return
        }
        phase = .disconnected
        updateState(.disconnected)
    }

    func reconnect() {
        guard let api else { return }
        if target == .builtIn {
            guard lidClosed == false else { return }
        } else {
            guard managedExternal != nil else { return }
        }
        if let displays = try? Display.active(), activeTarget(in: displays) != nil {
            finishRecovery()
            refresh()
            return
        }
        beginRecovery(api, now: Date())
        refresh()
    }

    private func beginRecovery(_ api: DisplayConnectionAPI, now: Date) {
        message = nil
        startMonitoring()
        attemptRecovery(api, now: now, deadline: now.addingTimeInterval(Self.recoveryDuration))
    }

    private func attemptRecovery(_ api: DisplayConnectionAPI, now: Date, deadline: Date) {
        phase = .reconnecting(deadline: deadline, nextAttempt: now.addingTimeInterval(Self.retryInterval))
        updateState(.switching)
        if target == .external {
            guard let uuid = managedExternal?.uuid, let id = api.externalID(uuid: uuid) else { return }
            // The monitor retries until the recovery deadline.
            try? api.setEnabled(true, id: id, externalUUID: uuid)
            return
        }
        let original = managedID.flatMap { CGDisplayIsBuiltin($0) != 0 ? $0 : nil }
        guard let id = api.builtInID() ?? original else { return }
        do {
            try api.setEnabled(true, id: id)
            managedID = id
        } catch { /* The monitor retries until the recovery deadline. */ }
    }

    func restoreOnQuit() {
        guard managedID != nil || managedExternal != nil else { return }
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
        managedExternal = nil
        phase = nil
        stopMonitoring()
    }

    private func finishRecovery(_ notice: String? = nil) {
        let restored = notice ?? "\(name)已恢复。"
        finish()
        message = restored
    }

    private func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }
}
