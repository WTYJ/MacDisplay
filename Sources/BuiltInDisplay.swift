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

    struct ExternalHardware: Codable {
        let location: String
        let edidUUID: String?
    }

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

    func externalRecoveryID(uuid: String, hardware: ExternalHardware) -> CGDirectDisplayID? {
        guard let ids = displayIDs() else { return nil }
        let identified = ids.map { (id: $0, uuid: Display.identifier(for: $0)) }
        let matches = identified.filter { $0.uuid == uuid }
        if !matches.isEmpty {
            guard matches.count == 1, let match = matches.first, CGDisplayIsBuiltin(match.id) == 0 else { return nil }
            return match.id
        }

        // WindowServer can keep the disabled slot and location but omit its display UUID.
        guard hardware.edidUUID != nil, isExternalAttached(hardware) else { return nil }
        let slots = identified.filter {
            $0.uuid == nil && CGDisplayIsBuiltin($0.id) == 0 && CGDisplayIsActive($0.id) == 0
                && displayLocation($0.id) == hardware.location
        }
        return slots.count == 1 ? slots.first?.id : nil
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
            && externalHardware(display.id) != nil
    }

    func externalHardware(_ id: CGDirectDisplayID) -> ExternalHardware? {
        guard id != 0, CGDisplayIsBuiltin(id) == 0,
              let location = displayLocation(id) else { return nil }
        let service = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return ExternalHardware(location: location, edidUUID: edidUUID(of: service))
    }

    private func displayLocation(_ id: CGDirectDisplayID) -> String? {
        let info = displayInfo(id)?.takeRetainedValue() as? [String: Any]
        return info?["IODisplayLocation"] as? String
    }

    func isExternalAttached(_ hardware: ExternalHardware) -> Bool {
        let service = IORegistryEntryCopyFromPath(kIOMainPortDefault, hardware.location as CFString)
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        guard let uuid = hardware.edidUUID else { return true }
        return edidUUID(of: service) == uuid
    }

    func externalLinkID(_ hardware: ExternalHardware) -> UInt64? {
        guard hardware.location.hasSuffix("/IOMobileFramebufferShim"),
              let controller = hardware.location.split(separator: "/").dropLast().last?
                .split(separator: "@", maxSplits: 1).first,
              controller.hasPrefix("dispext") else { return nil }
        // The framebuffer and the DP proxy live under separate driver branches for the same controller.
        let endpoint = "/\(controller):dcpdp-device-epic:"
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPDPDeviceProxy"), &iterator)
            == KERN_SUCCESS, iterator != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(iterator) }
        var match: UInt64?
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCopyPath(service, kIOServicePlane)?.takeRetainedValue() as String?,
                  path.contains(endpoint) else { continue }
            var id: UInt64 = 0
            guard match == nil, IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { return nil }
            match = id
        }
        return match
    }

    private func edidUUID(of service: io_registry_entry_t) -> String? {
        IORegistryEntryCreateCFProperty(service, "EDID UUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    func setEnabled(_ enabled: Bool, id: CGDirectDisplayID, externalUUID: String? = nil) throws {
        if let externalUUID {
            guard externalID(uuid: externalUUID) == id, enabled || externalHardware(id) != nil else {
                throw DisplayFailure("系统无法确认目标外接显示器。")
            }
        } else {
            guard id != 0, CGDisplayIsBuiltin(id) != 0 else {
                throw DisplayFailure("系统没有确认目标是内建屏。")
            }
        }
        try applyEnabled(enabled, id: id)
    }

    func restoreExternal(uuid: String, hardware: ExternalHardware) throws {
        guard let id = externalRecoveryID(uuid: uuid, hardware: hardware) else { return }
        try applyEnabled(true, id: id)
    }

    private func applyEnabled(_ enabled: Bool, id: CGDirectDisplayID) throws {
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

    private struct ManagedExternal: Codable {
        let id: CGDirectDisplayID
        let uuid: String
        let name: String
        let hardware: DisplayConnectionAPI.ExternalHardware
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
    private var wasAttachedWhileInactive = false
    private var externalLinkID: UInt64?
    private var phase: Phase?
    private var monitor: Task<Void, Never>?
    private let defaults: UserDefaults
    private static let recoveryKey = "PendingExternalDisplayRecovery"
    private var pendingExternals: [ManagedExternal] = []

    init(target: Target, defaults: UserDefaults = .standard) {
        self.target = target
        self.defaults = defaults
        if target == .external, let data = defaults.data(forKey: Self.recoveryKey),
           let records = try? PropertyListDecoder().decode([ManagedExternal].self, from: data) {
            pendingExternals = records
        }
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
            guard let external = managedExternal, let api else { return Display.menuExternal(in: displays) }
            return displays.first { matchesExternal($0, external, api: api) }
        }
    }

    private func matchesExternal(_ display: Display, _ external: ManagedExternal, api: DisplayConnectionAPI) -> Bool {
        guard !display.isBuiltIn else { return false }
        if display.uuid == external.uuid { return true }
        guard let edid = external.hardware.edidUUID, let hardware = api.externalHardware(display.id) else { return false }
        return hardware.location == external.hardware.location && hardware.edidUUID == edid
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
        let now = Date()
        if target == .external {
            if let displays, let external = managedExternal {
                if active == nil, observeExternalAttachment(external, api: api, now: now) {
                    if phase == nil {
                        refreshExternalAvailability(displays: displays, lidClosed: closed, api: api)
                    }
                    return
                }
            } else if managedExternal == nil, !pendingExternals.isEmpty {
                startMonitoring()
                if let displays, resumePendingExternal(in: displays, api: api, now: now) { return }
            }
        }
        let hasSurvivor = displays.map { hasSurvivor(in: $0, api: api) }
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

    private func observeExternalAttachment(_ external: ManagedExternal, api: DisplayConnectionAPI, now: Date) -> Bool {
        if api.isExternalAttached(external.hardware) {
            // A new hardware service also detects a replug that finished between samples.
            let link = api.externalLinkID(external.hardware)
            if let link {
                let previous = externalLinkID
                externalLinkID = link
                if let previous, link != previous {
                    switch phase {
                    case .trial, .disconnected, .recoveryFailed:
                        beginRecovery(api, now: now)
                        return true
                    default:
                        break
                    }
                }
            }
            wasAttachedWhileInactive = true
        } else if wasAttachedWhileInactive,
                  external.hardware.edidUUID != nil || api.isExternalMissing(uuid: external.uuid, originalID: external.id) {
            finish(forgetExternal: false)
            message = nil
            startMonitoring()
            return true
        }
        return false
    }

    private func resumePendingExternal(in displays: [Display], api: DisplayConnectionAPI, now: Date) -> Bool {
        let outstanding = pendingExternals.filter { external in
            !displays.contains { matchesExternal($0, external, api: api) }
        }
        if outstanding.count != pendingExternals.count {
            try? savePendingExternals(outstanding)
        }
        guard let external = outstanding.first(where: {
            api.isExternalAttached($0.hardware) && api.externalRecoveryID(uuid: $0.uuid, hardware: $0.hardware) != nil
        }) else {
            if outstanding.isEmpty { stopMonitoring() }
            return false
        }
        managedExternal = external
        beginRecovery(api, now: now)
        return true
    }

    private func savePendingExternals(_ records: [ManagedExternal]) throws {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.recoveryKey)
        } else {
            let data = try PropertyListEncoder().encode(records)
            defaults.set(data, forKey: Self.recoveryKey)
        }
        pendingExternals = records
    }

    func prepareExternalRecoveryOnQuit() -> Bool {
        guard target == .external else { return false }
        refresh()
        guard let external = managedExternal, let api else { return false }
        return api.isExternalAttached(external.hardware)
    }

    func waitForExternalRecoveryOnQuit() async {
        guard let api, managedExternal != nil else { return }
        if let displays = try? Display.active(), activeTarget(in: displays) != nil {
            finishRecovery()
            return
        }
        let deadline = ContinuousClock.now + .seconds(Self.recoveryDuration)
        switch phase {
        case .reconnecting:
            break
        default:
            beginRecovery(api, now: Date())
        }
        while ContinuousClock.now < deadline, case .reconnecting = phase {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    private func refreshExternalAvailability(
        displays: [Display]?, lidClosed: Bool?, api: DisplayConnectionAPI
    ) {
        if isManaged {
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
        guard state == .connected, let api, let displays else { return }
        let candidate = target == .external ? Display.menuExternal(in: displays) : activeTarget(in: displays)
        guard let display = candidate else { return }
        let external: ManagedExternal?
        if target == .external {
            guard let uuid = display.uuid, uuid == expectedExternalUUID,
                  let hardware = api.externalHardware(display.id) else { return }
            external = ManagedExternal(id: display.id, uuid: uuid, name: display.name, hardware: hardware)
        } else {
            external = nil
        }
        message = nil
        let previous = pendingExternals
        do {
            if let external {
                let other = previous.filter { $0.uuid != external.uuid }
                try savePendingExternals(other + [external])
            }
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
            if external != nil { try? savePendingExternals(previous) }
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
            guard let external = managedExternal else { return }
            // The monitor retries until the recovery deadline.
            try? api.restoreExternal(uuid: external.uuid, hardware: external.hardware)
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
        guard managedID != nil else { return }
        reconnect()
        stopMonitoring()
    }

    private var monitorInterval: Duration {
        if target == .external, phase == nil { return .seconds(2) }
        return .milliseconds(500)
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.monitorInterval else { return }
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }

    private func finish(forgetExternal: Bool = true) {
        if forgetExternal, let external = managedExternal {
            try? savePendingExternals(pendingExternals.filter { $0.uuid != external.uuid })
        }
        managedID = nil
        managedExternal = nil
        externalLinkID = nil
        wasAttachedWhileInactive = false
        phase = nil
        if pendingExternals.isEmpty { stopMonitoring() }
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
