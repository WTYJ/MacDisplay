import AppKit

@MainActor
final class Dimming {
    private var shades: [String: NSWindow] = [:]
    private var levels: [String: Double] = [:]

    func level(for uuid: String) -> Double {
        levels[uuid, default: 1]
    }

    func setLevel(_ level: Double, for uuid: String, displays: [Display], sync: Bool) {
        for display in displays where CGDisplayIsInMirrorSet(display.id) == 0 {
            guard let identifier = display.uuid, sync || identifier == uuid else { continue }
            levels[identifier] = level
        }
        refresh(displays)
    }

    func refresh(_ displays: [Display]) {
        var active = Set<String>()
        for display in displays {
            guard let uuid = display.uuid, let screen = Display.screen(for: display.id),
                  level(for: uuid) < 1, CGDisplayIsInMirrorSet(display.id) == 0 else { continue }
            active.insert(uuid)
            let shade = shades[uuid] ?? Self.makeShade(screen.frame)
            shades[uuid] = shade
            if shade.frame != screen.frame { shade.setFrame(screen.frame, display: true) }
            shade.alphaValue = 1 - level(for: uuid)
            if !shade.isVisible { shade.orderFrontRegardless() }
        }
        for uuid in Array(shades.keys) where !active.contains(uuid) {
            shades.removeValue(forKey: uuid)?.orderOut(nil)
        }
    }

    private static func makeShade(_ frame: CGRect) -> NSWindow {
        let shade = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        shade.isReleasedWhenClosed = false
        shade.backgroundColor = .black
        shade.hasShadow = false
        shade.ignoresMouseEvents = true
        shade.level = .statusBar
        shade.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return shade
    }
}
