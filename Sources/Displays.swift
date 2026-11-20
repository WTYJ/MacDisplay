import AppKit
import CoreGraphics

struct Display: Identifiable {
    let id: CGDirectDisplayID
    let uuid: String?
    let name: String
    let isBuiltIn: Bool

    static func active() throws -> [Display] {
        var count: UInt32 = 0
        try check(CGGetActiveDisplayList(0, nil, &count), "读取显示器数量")
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        try check(CGGetActiveDisplayList(count, &ids, &count), "读取显示器")
        return ids.prefix(Int(count)).map { id in
            return Display(
                id: id,
                uuid: identifier(for: id),
                name: name(for: id) ?? "显示器 \(id)",
                isBuiltIn: CGDisplayIsBuiltin(id) != 0
            )
        }
    }

    static func identifier(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    static func menuExternal(in displays: [Display]) -> Display? {
        displays.first { display in
            guard !display.isBuiltIn, let uuid = display.uuid else { return false }
            return displays.filter { $0.uuid == uuid }.count == 1
        }
    }

    static func name(for id: CGDirectDisplayID) -> String? {
        screen(for: id)?.localizedName
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    var currentMode: CGDisplayMode? { CGDisplayCopyDisplayMode(id) }

    var modes: [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let allModes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        var seen = Set<DisplayMode>()
        return allModes.filter {
            $0.isUsableForDesktopGUI() && seen.insert(DisplayMode($0)).inserted
        }.sorted { lhs, rhs in
            (lhs.width, lhs.height, lhs.pixelWidth, lhs.pixelHeight, lhs.refreshRate)
                < (rhs.width, rhs.height, rhs.pixelWidth, rhs.pixelHeight, rhs.refreshRate)
        }
    }

    func setMode(_ mode: CGDisplayMode) throws {
        try check(CGDisplaySetDisplayMode(id, mode, nil), "切换 \(name) 显示模式")
    }

    var details: String {
        guard let mode = currentMode else {
            return isBuiltIn ? "内建显示器" : "外接显示器"
        }
        return DisplayMode(mode).label
    }
}

struct DisplayFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) {
        self.message = message
    }
}

private func check(_ result: CGError, _ action: String) throws {
    guard result == .success else {
        throw DisplayFailure("\(action)失败（Core Graphics \(result.rawValue)）。")
    }
}

struct DisplayMode: Hashable {
    struct Resolution: Hashable {
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int

        var label: String {
            if pixelWidth > width || pixelHeight > height {
                return "\(width) × \(height) HiDPI（\(pixelWidth) × \(pixelHeight)）"
            }
            return "\(width) × \(height)"
        }
    }

    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    init(_ mode: CGDisplayMode) {
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
    }

    var label: String {
        let rate = refreshRate > 0 ? " · \(refreshLabel)" : ""
        let hidpi = pixelWidth > width ? " · HiDPI" : ""
        return "\(width) × \(height)\(rate)\(hidpi)"
    }

    var refreshLabel: String {
        refreshRate > 0 ? "\(refreshRate.formatted()) Hz" : "系统管理"
    }

    var resolution: Resolution {
        Resolution(width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}
