import AppKit
import SwiftUI

@MainActor
final class Model: ObservableObject {
    let builtIn = DisplayConnection(target: .builtIn)
    let external = DisplayConnection(target: .external)

    @Published private(set) var displays: [Display] = []
    @Published var displayError: String?
    @Published var selectedDisplayID: Display.ID? {
        didSet {
            if oldValue != selectedDisplayID { diagnosticMessage = nil }
        }
    }
    @Published private(set) var modeTrial: ModeTrial?
    @Published var modeMessage: String?
    @Published var syncDimming = false
    @Published private(set) var hardwareBusy = false
    @Published private(set) var isExportingEDID = false
    @Published private(set) var diagnosticMessage: String?

    @Published private var readings: [String: [DDC.Control: DDC.Value]] = [:]
    @Published private var hardwareMessages: [String: String] = [:]

    private let dimming = Dimming()
    private var revertTask: Task<Void, Never>?

    struct ModeTrial {
        let uuid: String
        let original: CGDisplayMode
        let requested: DisplayMode
    }

    var selectedDisplay: Display? {
        displays.first { $0.id == selectedDisplayID }
    }

    var hardwareUUID: String? {
        guard let display = selectedDisplay, !display.isBuiltIn, let uuid = display.uuid,
              displays.filter({ $0.uuid == uuid }).count == 1 else { return nil }
        return uuid
    }

    var canReadHardware: Bool { DDC.helper != nil && hardwareUUID != nil }

    var menuDisplay: Display? {
        Display.menuExternal(in: displays)
    }

    var canDimSelectedDisplay: Bool {
        guard let display = selectedDisplay else { return false }
        return display.uuid != nil && Display.screen(for: display.id) != nil && CGDisplayIsInMirrorSet(display.id) == 0
    }

    var hardwareValues: [DDC.Control: DDC.Value] {
        hardwareUUID.flatMap { readings[$0] } ?? [:]
    }

    var hardwareMessage: String? {
        hardwareUUID.flatMap { hardwareMessages[$0] }
    }

    var menuBrightness: DDC.Value? {
        menuDisplay?.uuid.flatMap { readings[$0]?[.luminance] }
    }

    var menuBrightnessMessage: String? {
        menuDisplay?.uuid.flatMap { hardwareMessages[$0] }
    }

    var dimmingAmount: Int {
        guard let uuid = selectedDisplay?.uuid else { return 0 }
        return Int(((1 - dimming.level(for: uuid)) * 100).rounded())
    }

    init() { refreshDisplays() }

    func refreshDisplays() {
        let oldUUID = selectedDisplay?.uuid
        do {
            displays = try Display.active()
            displayError = nil
        } catch {
            displays = []
            displayError = error.localizedDescription
        }
        if let oldUUID, let display = displays.first(where: { $0.uuid == oldUUID }) {
            selectedDisplayID = display.id
        } else if oldUUID != nil || selectedDisplay == nil {
            selectedDisplayID = (menuDisplay ?? displays.first)?.id
        }
        let connected = Set(displays.compactMap(\.uuid))
        readings = readings.filter { connected.contains($0.key) }
        hardwareMessages = hardwareMessages.filter { connected.contains($0.key) }
        dimming.refresh(displays)
        let snapshot = displayError == nil ? displays : nil
        builtIn.refresh(displays: snapshot)
        external.refresh(displays: snapshot)
    }

    func disconnectBuiltIn() {
        guard modeTrial == nil, !external.isManaged else { return }
        builtIn.disconnect()
    }

    func disconnectExternal() {
        guard modeTrial == nil, !builtIn.isManaged, let uuid = menuDisplay?.uuid else { return }
        external.disconnect(expectedExternalUUID: uuid)
    }

    func setDimmingAmount(_ amount: Int) {
        guard canDimSelectedDisplay, let uuid = selectedDisplay?.uuid else { return }
        objectWillChange.send()
        let level = Double(100 - min(max(amount, 0), 90)) / 100
        dimming.setLevel(level, for: uuid, displays: displays, sync: syncDimming)
    }

    func tryMode(_ mode: DisplayMode) {
        guard modeTrial == nil, !builtIn.isTransitioning, !external.isTransitioning,
              let display = selectedDisplay, let uuid = display.uuid,
              let original = display.currentMode, DisplayMode(original) != mode,
              let candidate = display.modes.first(where: { DisplayMode($0) == mode }) else { return }
        do {
            try display.setMode(candidate)
            modeTrial = ModeTrial(uuid: uuid, original: original, requested: mode)
            modeMessage = nil
            revertTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.revertMode()
            }
            refreshDisplays()
        } catch {
            modeMessage = error.localizedDescription
        }
    }

    func keepMode() {
        finishModeTrial()
        modeMessage = "已保留当前显示模式。"
    }

    func revertMode() {
        guard let trial = modeTrial else { return }
        finishModeTrial()
        do {
            guard let display = try Display.active().first(where: { $0.uuid == trial.uuid }),
                  let current = display.currentMode, DisplayMode(current) == trial.requested else {
                modeMessage = "显示器或模式已变化，已结束试用。"
                return
            }
            try display.setMode(trial.original)
            modeMessage = "已恢复原显示模式。"
            refreshDisplays()
        } catch {
            modeMessage = error.localizedDescription
        }
    }

    private func finishModeTrial() {
        revertTask?.cancel()
        revertTask = nil
        modeTrial = nil
    }

    func readHardware() async {
        guard let uuid = hardwareUUID else { return }
        await readControls(for: uuid, brightnessOnly: false)
    }

    func readMenuBrightness() async {
        guard let uuid = menuDisplay?.uuid else { return }
        await readControls(for: uuid, brightnessOnly: true)
    }

    private func readControls(for uuid: String, brightnessOnly: Bool) async {
        // The popover and settings window can request reads at the same time.
        while hardwareBusy {
            do { try await Task.sleep(for: .milliseconds(75)) } catch { return }
        }
        let current = brightnessOnly ? menuDisplay?.uuid : hardwareUUID
        guard !Task.isCancelled, current == uuid else { return }
        hardwareBusy = true
        hardwareMessages.removeValue(forKey: uuid)
        defer { hardwareBusy = false }

        do {
            if brightnessOnly {
                let value = try await DDC.readBrightness(uuid: uuid)
                if isConnected(uuid) { readings[uuid, default: [:]][.luminance] = value }
            } else {
                let values = try await DDC.read(uuid: uuid)
                if isConnected(uuid) { readings[uuid] = values }
            }
        } catch {
            guard isConnected(uuid) else { return }
            if brightnessOnly {
                readings[uuid]?[.luminance] = nil
            } else {
                readings[uuid] = nil
            }
            hardwareMessages[uuid] = error.localizedDescription
        }
    }

    private func isConnected(_ uuid: String) -> Bool {
        displays.filter { $0.uuid == uuid }.count == 1
    }

    func exportEDID() async {
        guard !isExportingEDID, !hardwareBusy, let uuid = hardwareUUID,
              let name = selectedDisplay?.name else { return }
        isExportingEDID = true
        defer { isExportingEDID = false }
        diagnosticMessage = nil
        do {
            let data = try await readEDID(for: uuid)
            guard uuid == hardwareUUID else { return }
            let panel = NSSavePanel()
            panel.title = "导出 EDID"
            panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + "-EDID.bin"
            if await panel.begin() == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
                if uuid == hardwareUUID { diagnosticMessage = "已导出 \(data.count) 字节的 EDID。" }
            }
        } catch {
            if uuid == hardwareUUID { diagnosticMessage = error.localizedDescription }
        }
    }

    private func readEDID(for uuid: String) async throws -> Data {
        hardwareBusy = true
        defer { hardwareBusy = false }
        return try await DDC.edid(uuid: uuid)
    }

    func writeHardware(_ control: DDC.Control, value: Int, for uuid: String) async {
        guard !hardwareBusy, isConnected(uuid), let current = readings[uuid]?[control],
              (0...current.maximum).contains(value), value != current.current else { return }
        hardwareBusy = true
        hardwareMessages.removeValue(forKey: uuid)
        readings[uuid]?[control]?.current = value
        defer { hardwareBusy = false }

        do {
            let actual = try await DDC.write(uuid: uuid, control: control, value: value)
            guard isConnected(uuid) else { return }
            readings[uuid]?[control] = actual
            if actual.current != value {
                hardwareMessages[uuid] = "显示器返回 \(actual.current)，请求值为 \(value)。"
            }
        } catch {
            guard isConnected(uuid) else { return }
            readings[uuid]?[control] = nil
            hardwareMessages[uuid] = error.localizedDescription
        }
    }

    func shutDown() {
        external.restoreOnQuit()
        builtIn.restoreOnQuit()
        revertMode()
    }
}
