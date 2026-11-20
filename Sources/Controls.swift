import AppKit
import ServiceManagement
import SwiftUI

// Use SwiftUI's property wrapper with the standalone Command Line Tools build.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct Controls: View {
    @ObservedObject var model: Model

    var body: some View {
        TabView {
            displayControls.tabItem { Label("显示", systemImage: "display") }
            diagnosticControls.tabItem { Label("诊断", systemImage: "stethoscope") }
            ApplicationControls().tabItem { Label("应用", systemImage: "gearshape") }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 335, idealHeight: 440)
    }

    private var displaySelector: some View {
        Picker("显示器", selection: $model.selectedDisplayID) {
            if model.displays.isEmpty {
                Text("未检测到显示器").tag(nil as Display.ID?)
            }
            ForEach(model.displays) { display in
                Text(display.name).tag(Optional(display.id))
            }
        }
        .disabled(model.displays.isEmpty || model.modeTrial != nil || model.hardwareBusy)
    }

    private var displayControls: some View {
        let otherControls = DDC.Control.allCases.filter { $0 != .luminance && model.hardwareValues[$0] != nil }
        return Form {
            Section {
                displaySelector
            }
            Section("亮度与硬件控制") {
                if model.canReadHardware, let uuid = model.hardwareUUID {
                    if let value = model.hardwareValues[.luminance] {
                        hardwareSlider(.luminance, value: value, uuid: uuid)
                    } else if model.hardwareBusy {
                        ProgressView("正在读取显示器…").controlSize(.small)
                    } else if !model.hardwareValues.isEmpty {
                        Text("显示器未返回硬件亮度读数。").foregroundStyle(.secondary)
                    }
                    if let message = model.hardwareMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                    if !model.hardwareBusy && (model.hardwareValues[.luminance] == nil || model.hardwareMessage != nil) {
                        Button("重新读取") { Task { await model.readHardware() } }
                    }
                } else {
                    Text("请选择支持 DDC/CI 的外接显示器。").foregroundStyle(.secondary)
                }
                if model.canDimSelectedDisplay {
                    SettingsDisclosure("额外调暗（\(model.dimmingAmount)%）") {
                        LabeledContent("调暗幅度") {
                            DisplayValueSlider(
                                label: "额外调暗幅度", value: model.dimmingAmount, maximum: 90,
                                valueLabel: "\(model.dimmingAmount)%", enabled: true,
                                change: model.setDimmingAmount
                            )
                        }
                        if model.displays.count > 1 {
                            Toggle("同步调整其他扩展屏", isOn: $model.syncDimming)
                        }
                        Button("取消额外调暗") { model.setDimmingAmount(0) }
                            .disabled(model.dimmingAmount == 0 && !(model.syncDimming && model.displays.count > 1))
                    }
                }
                if let uuid = model.hardwareUUID, !otherControls.isEmpty {
                    SettingsDisclosure("对比度、音量与 RGB 增益") {
                        ForEach(otherControls) { control in
                            if let value = model.hardwareValues[control] {
                                hardwareSlider(control, value: value, uuid: uuid)
                            }
                        }
                    }
                }
            }
            .id(model.selectedDisplayID)

            BuiltInDisplayControls(display: model.builtIn, modeTrialActive: model.modeTrial != nil)
            Section("显示模式") {
                if let display = model.selectedDisplay {
                    let active = display.currentMode.map(DisplayMode.init)
                    let modes = display.modes.map(DisplayMode.init)
                    if let active, !modes.isEmpty {
                        modeSelectors(active: active, modes: modes)
                            .disabled(model.modeTrial != nil || display.uuid == nil)
                    } else {
                        LabeledContent("当前模式", value: display.details)
                    }
                }
                if model.modeTrial != nil {
                    Text("请在 15 秒内确认，否则自动恢复。")
                    HStack {
                        Button("恢复原模式") { model.revertMode() }
                        Button("保留新模式") { model.keepMode() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let message = model.modeMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: model.hardwareUUID) {
            if model.canReadHardware { await model.readHardware() }
        }
    }

    private func modeSelectors(active: DisplayMode, modes: [DisplayMode]) -> some View {
        var seen = Set<DisplayMode.Resolution>()
        let sizes = (modes + [active]).map(\.resolution).filter { seen.insert($0).inserted }
        let currentSizeModes = modes.filter { $0.resolution == active.resolution }
        let available = currentSizeModes.contains(active) ? currentSizeModes : currentSizeModes + [active]

        return Group {
            Picker("分辨率", selection: Binding(
                get: { active.resolution },
                set: { resolution in
                    let candidates = modes.filter { $0.resolution == resolution }
                    let chosen = candidates.min {
                        abs($0.refreshRate - active.refreshRate) < abs($1.refreshRate - active.refreshRate)
                    }
                    if let chosen { model.tryMode(chosen) }
                }
            )) {
                ForEach(sizes, id: \.self) { resolution in
                    Text(resolution.label).tag(resolution)
                }
            }
            Picker("刷新率", selection: Binding(get: { active }, set: model.tryMode)) {
                ForEach(available, id: \.self) { mode in
                    Text(mode.refreshLabel).tag(mode)
                }
            }
        }
    }

    private func hardwareSlider(_ control: DDC.Control, value: DDC.Value, uuid: String) -> some View {
        LabeledContent(control.label) {
            DisplayValueSlider(
                label: control.label, value: value.current, maximum: value.maximum,
                valueLabel: value.percentLabel, enabled: !model.hardwareBusy
            ) { target in
                Task { await model.writeHardware(control, value: target, for: uuid) }
            }
        }
    }

    private var diagnosticControls: some View {
        Form {
            Section("当前显示器") {
                if model.displays.isEmpty {
                    Text(model.displayError ?? "当前没有可用的显示器。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.displays) { display in
                    LabeledContent(display.name, value: display.details)
                }
            }

            Section("EDID") {
                displaySelector
                Button("导出 EDID…") { Task { await model.exportEDID() } }
                    .disabled(!model.canReadHardware || model.hardwareBusy)
                if !model.canReadHardware {
                    Text("请选择支持 EDID 导出的外接显示器。").foregroundStyle(.secondary)
                }
                if let message = model.diagnosticMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LoginLaunchControls: View {
    @ViewState private var status = SMAppService.Status.notRegistered
    @ViewState private var errorMessage: String?

    var body: some View {
        Section("启动") {
            Toggle("登录时启动 MacDisplay", isOn: Binding(
                get: { isRegistered(status) },
                set: setEnabled
            ))
            .toggleStyle(.switch)
            .onAppear(perform: refreshStatus)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshStatus()
            }

            if status == .requiresApproval {
                Text("需要在 macOS 的登录项设置中允许 MacDisplay。")
                    .foregroundStyle(.secondary)
                Button("打开登录项设置…") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
            }
        }
    }

    private func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    private func refreshStatus() {
        status = SMAppService.mainApp.status
    }

    private func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        errorMessage = nil
        defer { refreshStatus() }
        guard enabled != isRegistered(service.status) else { return }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BuiltInDisplayControls: View {
    @ObservedObject var display: BuiltInDisplay
    let modeTrialActive: Bool

    var body: some View {
        Section("开盖使用外屏") {
            switch display.state {
            case .connected:
                Button("断开 MacBook 内建屏") { display.disconnect() }
                    .disabled(modeTrialActive)
                Text("断开后请在外屏确认。未确认时将尝试恢复内建屏。")
                    .foregroundStyle(.secondary)
            case .disconnected:
                Button("重新连接内建屏") { display.reconnect() }
            case .switching, .trial:
                ProgressView("正在检查内建屏连接").controlSize(.small)
            case .unavailable(let reason):
                Text(reason).foregroundStyle(.secondary)
            }
            if let message = display.message {
                Text(message).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @ViewState private var expanded = false

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack {
                Text(title)
                Spacer(minLength: 16)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "已展开" : "已折叠")

        if expanded { content() }
    }
}

private struct ApplicationControls: View {
    private enum UpdateStatus: Equatable {
        case idle
        case checking
        case finished(UpdateCheck.Result)
        case failed
    }

    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private let license = Bundle.main.url(forResource: "m1ddc-LICENSE", withExtension: nil)
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    @ViewState private var updateStatus = UpdateStatus.idle

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "display")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MacDisplay").font(.title2.weight(.semibold))
                        HStack {
                            Text("版本 \(version)")
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer(minLength: 16)
                            Button("检查更新") { Task { await checkForUpdates() } }
                                .controlSize(.small)
                                .disabled(updateStatus == .checking)
                        }
                    }
                }
                .padding(.vertical, 4)

                switch updateStatus {
                case .idle:
                    EmptyView()
                case .checking:
                    ProgressView("正在检查更新…").controlSize(.small)
                case .finished(.noRelease):
                    Text("GitHub 上还没有正式发布的版本。").foregroundStyle(.secondary)
                case .finished(.upToDate):
                    Text("暂无可用更新。").foregroundStyle(.secondary)
                case .finished(.available(let latest)):
                    LabeledContent("有新版本 \(latest)") {
                        Link("查看发布…", destination: UpdateCheck.latestReleasePage)
                    }
                case .failed:
                    Text("无法检查更新，请稍后重试。").foregroundStyle(.secondary)
                }
            }

            LoginLaunchControls()

            if let license, let source = URL(string: "https://github.com/waydabber/m1ddc") {
                Section("开源组件") {
                    LabeledContent("DDC/CI 后端") {
                        Link("m1ddc", destination: source)
                    }
                    SettingsDisclosure("MIT 许可证") {
                        Text(license)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func checkForUpdates() async {
        guard updateStatus != .checking else { return }
        updateStatus = .checking
        do {
            updateStatus = .finished(try await UpdateCheck.check(installedVersion: version))
        } catch {
            updateStatus = .failed
        }
    }
}
