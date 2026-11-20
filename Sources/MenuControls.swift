import AppKit
import SwiftUI

struct MenuControls: View {
    @ObservedObject var model: Model
    @ObservedObject var builtIn: BuiltInDisplay
    let toggleBuiltIn: () -> Void
    let showSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            brightness
            Divider()
            connection
            Divider()
            HStack {
                Button("显示设置…", action: showSettings)
                Spacer()
                Button("退出", action: quit)
            }
        }
        .padding(16)
        .frame(width: 300)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var brightness: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let display = model.menuDisplay, let uuid = display.uuid {
                Label("\(display.name) 硬件亮度", systemImage: "sun.max")
                    .font(.headline)
                    .lineLimit(1)
                if let value = model.menuBrightness {
                    DisplayValueSlider(
                        label: "硬件亮度", value: value.current, maximum: value.maximum,
                        valueLabel: value.percentLabel, enabled: !model.hardwareBusy
                    ) { target in
                        Task { await model.writeHardware(.luminance, value: target, for: uuid) }
                    }
                } else if model.hardwareBusy {
                    ProgressView("正在读取外屏亮度…").controlSize(.small)
                } else {
                    if let message = model.menuBrightnessMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                    Button("重新读取") { Task { await model.readMenuBrightness() } }
                }
            } else {
                Label("未检测到外接显示器", systemImage: "display")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch builtIn.state {
            case .connected:
                Button("断开 MacBook 内建屏", action: toggleBuiltIn)
                    .disabled(model.modeTrial != nil)
            case .disconnected, .trial:
                Button("重新连接内建屏", action: toggleBuiltIn)
            case .switching:
                ProgressView("正在切换内建屏…").controlSize(.small)
            case .unavailable(let reason):
                Text(reason).foregroundStyle(.secondary)
            }
            if let message = builtIn.message {
                Text(message).foregroundStyle(.secondary)
            }
        }
    }
}

struct DisplayValueSlider: View {
    let label: String
    let value: Int
    let maximum: Int
    let valueLabel: String
    let enabled: Bool
    let change: (Int) -> Void

    var body: some View {
        HStack {
            ReleaseSlider(label: label, value: value, maximum: maximum, enabled: enabled, change: change)
            Text(valueLabel).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct ReleaseSlider: NSViewRepresentable {
    let label: String
    let value: Int
    let maximum: Int
    let enabled: Bool
    let change: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(change: change) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: Double(value), minValue: 0, maxValue: Double(maximum),
            target: context.coordinator, action: #selector(Coordinator.apply(_:))
        )
        slider.isContinuous = false
        slider.setAccessibilityLabel(label)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.change = change
        slider.maxValue = Double(maximum)
        slider.integerValue = value
        slider.isEnabled = enabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var change: (Int) -> Void

        init(change: @escaping (Int) -> Void) {
            self.change = change
        }

        @objc func apply(_ slider: NSSlider) { change(slider.integerValue) }
    }
}
