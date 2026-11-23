import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = Model()
    private var statusItem: NSStatusItem?
    private var controlWindow: NSWindow?
    private let statusPopover = NSPopover()
    private var confirmationPanel: NSPanel?
    private var confirmationConnection: DisplayConnection?
    private var connectionObserver: AnyCancellable?
    private var quitRecoveryTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "MacDisplay")
        item.button?.target = self
        item.button?.action = #selector(toggleMenuControls)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        statusPopover.behavior = .transient
        statusPopover.animates = false
        statusPopover.contentViewController = NSHostingController(rootView: MenuControls(
            model: model,
            builtIn: model.builtIn,
            external: model.external,
            toggleConnection: { [weak self] in self?.toggleConnection($0) },
            showSettings: { [weak self] in self?.showControls() },
            quit: { NSApp.terminate(nil) }
        ))

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出 MacDisplay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        connectionObserver = model.builtIn.$state.combineLatest(model.external.$state).sink { [weak self] builtIn, external in
            guard let self else { return }
            self.updateConfirmationPanel(for: self.trialConnection(builtIn: builtIn, external: external))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitRecoveryTask != nil { return .terminateLater }
        guard model.external.prepareExternalRecoveryOnQuit() else { return .terminateNow }
        quitRecoveryTask = Task {
            await model.external.waitForExternalRecoveryOnQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutDown()
    }

    @objc private func screensChanged() {
        let oldMenuDisplay = model.menuDisplay?.uuid
        model.refreshDisplays()
        if statusPopover.isShown, oldMenuDisplay != model.menuDisplay?.uuid {
            Task { await model.readMenuBrightness() }
        }
        updateConfirmationPanel(for: trialConnection(builtIn: model.builtIn.state, external: model.external.state))
    }

    @objc private func toggleMenuControls() {
        if statusPopover.isShown {
            statusPopover.close()
            return
        }
        guard let button = statusItem?.button, let content = statusPopover.contentViewController else { return }
        model.refreshDisplays()
        NSApp.activate()
        // Give AppKit the content size before it positions the popover against the menu bar.
        statusPopover.contentSize = content.view.fittingSize
        statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        Task { await model.readMenuBrightness() }
    }

    private func toggleConnection(_ target: DisplayConnection.Target) {
        statusPopover.close()
        let connection = target == .builtIn ? model.builtIn : model.external
        switch connection.state {
        case .connected:
            if target == .builtIn {
                model.disconnectBuiltIn()
            } else {
                model.disconnectExternal()
            }
        case .disconnected, .trial:
            connection.reconnect()
        default:
            break
        }
    }

    private func trialConnection(
        builtIn: DisplayConnection.State, external: DisplayConnection.State
    ) -> DisplayConnection? {
        if builtIn == .trial { return model.builtIn }
        if external == .trial { return model.external }
        return nil
    }

    private func updateConfirmationPanel(for connection: DisplayConnection?) {
        if connection !== confirmationConnection {
            confirmationPanel?.orderOut(nil)
            confirmationPanel = nil
            confirmationConnection = nil
        }

        guard confirmationPanel == nil, let connection, let screen = connection.confirmationScreen else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.title = connection.target == .builtIn ? "仅使用外接显示器" : "断开 \(connection.name)"
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: DisplayConnectionConfirmation(connection: connection))
        let visibleFrame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        ))
        confirmationPanel = panel
        confirmationConnection = connection
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === confirmationPanel else { return true }
        confirmationConnection?.reconnect()
        return false
    }

    private func showControls() {
        statusPopover.close()
        model.refreshDisplays()
        if controlWindow == nil {
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 560, height: 440),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MacDisplay"
            window.contentViewController = NSHostingController(rootView: Controls(
                model: model, external: model.external,
                toggleConnection: { [weak self] in self?.toggleConnection($0) }
            ))
            window.isReleasedWhenClosed = false
            window.center()
            controlWindow = window
        }
        NSApp.activate()
        controlWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct DisplayConnectionConfirmation: View {
    let connection: DisplayConnection

    var body: some View {
        let disconnectingBuiltIn = connection.target == .builtIn
        VStack(alignment: .leading, spacing: 16) {
            Text(disconnectingBuiltIn ? "外接显示器显示正常吗？" : "MacBook 内建屏显示正常吗？")
                .font(.headline)
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let remaining = connection.confirmationSecondsRemaining(at: context.date)
                Text("未确认将在 \(remaining) 秒后重新连接\(connection.name)。")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                Spacer()
                Button("恢复\(connection.name)") { connection.reconnect() }
                    .keyboardShortcut(.cancelAction)
                Button(disconnectingBuiltIn ? "保留仅外屏" : "保持断开") { connection.keepDisconnected() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

@main
struct MacDisplay {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first?.hasPrefix("--") == true {
            do {
                try runCommand(arguments)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(EXIT_FAILURE)
            }
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }

    @MainActor private static func runCommand(_ arguments: [String]) throws {
        if arguments == ["--built-in-status"] {
            let display = DisplayConnection(target: .builtIn)
            display.refresh()
            display.diagnostics.forEach { print($0) }
            return
        }
        if arguments.first == "--list-displays" {
            let displays = try Display.active()
            for display in displays {
                print("\(display.id)\t\(display.name)\t\(display.details)")
            }
            if displays.isEmpty { print("当前没有可用的显示器。") }
            return
        }
        if let command = arguments.first, command == "--list-modes" || command == "--read-ddc" {
            guard arguments.count == 2, let id = Display.ID(arguments[1]),
                  let display = try Display.active().first(where: { $0.id == id }) else {
                throw DisplayFailure("请提供有效的显示器 ID（通过 --list-displays 查看）。")
            }
            if command == "--list-modes" {
                for mode in display.modes {
                    print(DisplayMode(mode).label)
                }
            } else {
                guard !display.isBuiltIn, let uuid = display.uuid else {
                    throw DisplayFailure("请选择一台可识别的外接显示器。")
                }
                let readings = try DDC.readSync(uuid: uuid)
                for control in DDC.Control.allCases {
                    if let value = readings[control] {
                        print("\(control.rawValue)\t\(value.current)\t\(value.maximum)")
                    }
                }
            }
            return
        }
        throw DisplayFailure("用法：--list-displays、--list-modes <显示器 ID>、--read-ddc <显示器 ID>、--built-in-status。")
    }
}
