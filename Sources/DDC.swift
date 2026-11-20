import Foundation

enum DDC {
    enum Control: String, CaseIterable, Identifiable, Sendable {
        case luminance, contrast, volume, red, green, blue

        var id: Self { self }
        var label: String {
            switch self {
            case .luminance: "硬件亮度"
            case .contrast: "对比度"
            case .volume: "显示器音量"
            case .red: "红色增益"
            case .green: "绿色增益"
            case .blue: "蓝色增益"
            }
        }
    }

    struct Value: Sendable {
        var current: Int
        let maximum: Int

        var percentLabel: String {
            (Double(current) / Double(maximum)).formatted(.percent.precision(.fractionLength(0)))
        }
    }

    static var helper: URL? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return nil }
        let url = bundle.appendingPathComponent("Contents/Helpers/m1ddc")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func read(uuid: String) async throws -> [Control: Value] {
        try await Task.detached(priority: .userInitiated) {
            try readSync(uuid: uuid)
        }.value
    }

    static func readSync(uuid: String) throws -> [Control: Value] {
        guard let helper else { throw DisplayFailure("此构建未包含 DDC/CI 后端。") }
        var readings: [Control: Value] = [:]
        for control in Control.allCases {
            readings[control] = try? readValue(helper, uuid, control)
        }
        guard !readings.isEmpty else {
            throw DisplayFailure("显示器未返回可读的 DDC/CI 控制值。请检查显示器菜单中的 DDC/CI 选项以及连接线。")
        }
        return readings
    }

    static func readBrightness(uuid: String) async throws -> Value {
        try await Task.detached(priority: .userInitiated) {
            guard let helper else { throw DisplayFailure("此构建未包含 DDC/CI 后端。") }
            do {
                return try readValue(helper, uuid, .luminance)
            } catch {
                return try readValue(helper, uuid, .luminance)
            }
        }.value
    }

    static func write(uuid: String, control: Control, value: Int) async throws -> Int {
        try await Task.detached(priority: .userInitiated) {
            guard let helper else { throw DisplayFailure("此构建未包含 DDC/CI 后端。") }
            _ = try run(helper, ["display", "uuid=\(uuid)", "set", control.rawValue, String(value)])
            do {
                return try number(helper, uuid, "get", control)
            } catch {
                throw DisplayFailure("已发出写入命令，但无法核对显示器当前值。请重新读取。")
            }
        }.value
    }

    static func edid(uuid: String) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let helper else { throw DisplayFailure("此构建未包含 EDID 读取后端。") }
            let hex = Array(try run(helper, ["display", "uuid=\(uuid)", "edid"]))
            let header = Array("00ffffffffffff00")
            guard hex.count >= 256, hex.count.isMultiple(of: 256), hex.starts(with: header) else {
                throw DisplayFailure("系统返回的 EDID 结构无效。")
            }
            var data = Data()
            for index in stride(from: 0, to: hex.count, by: 2) {
                guard let byte = UInt8(String(hex[index...index + 1]), radix: 16) else {
                    throw DisplayFailure("系统返回的 EDID 包含无效数据。")
                }
                data.append(byte)
            }
            guard data.count == (Int(data[126]) + 1) * 128 else {
                throw DisplayFailure("系统提供的 EDID 缺少扩展块。")
            }
            return data
        }.value
    }

    private static func number(_ helper: URL, _ uuid: String, _ verb: String, _ control: Control) throws -> Int {
        let output = try run(helper, ["display", "uuid=\(uuid)", verb, control.rawValue])
        guard let value = Int(output) else {
            throw DisplayFailure("显示器没有返回有效的\(control.label)。")
        }
        return value
    }

    private static func readValue(_ helper: URL, _ uuid: String, _ control: Control) throws -> Value {
        let output = try run(helper, ["display", "uuid=\(uuid)", "get-value", control.rawValue])
        let fields = output.split(separator: " ")
        guard fields.count == 2, let current = Int(fields[0]), let maximum = Int(fields[1]),
              maximum > 0, (0...maximum).contains(current) else {
            throw DisplayFailure("显示器没有返回有效的\(control.label)。")
        }
        return Value(current: current, maximum: maximum)
    }
    private static func run(_ helper: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = helper
        process.arguments = arguments
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw DisplayFailure("DDC/CI 命令失败。\(message)")
        }
        return message
    }
}
