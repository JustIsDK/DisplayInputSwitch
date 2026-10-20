import Foundation

struct MonitorSetting: Codable, Identifiable, Equatable {
    var serial: String
    var name: String
    var id: String { serial }
}
struct Assignment: Codable, Equatable { var serial: String; var input: Int }
struct SwitchGroup: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var displays: [Assignment]
    var shortcut: Int
}
struct Configuration: Codable, Equatable {
    var version: Int
    var monitors: [MonitorSetting]
    var groups: [SwitchGroup]
    var shortcutsEnabled: Bool
    static let initial = Configuration(version: 2,
        monitors: [.init(serial: "J80FDH3", name: "QX"), .init(serial: "330BJ04", name: "QE")],
        groups: [
            .init(id: "mac1", name: "Mac 1", displays: [.init(serial: "J80FDH3", input: 27), .init(serial: "330BJ04", input: 27)], shortcut: 1),
            .init(id: "mac2", name: "Mac 2", displays: [.init(serial: "J80FDH3", input: 27), .init(serial: "330BJ04", input: 17)], shortcut: 2),
            .init(id: "windows", name: "Windows", displays: [.init(serial: "J80FDH3", input: 15), .init(serial: "330BJ04", input: 15)], shortcut: 3)
        ], shortcutsEnabled: true)
    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw ConfigError(message: message) } }
        try require(version == 2, "配置版本不支持。")
        try require(!monitors.isEmpty && monitors.count <= 4, "显示器数量须为 1–4 台。")
        let serials = Set(monitors.map(\.serial))
        try require(serials.count == monitors.count && monitors.allSatisfy { !$0.serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.isEmpty }, "显示器名称和序列号不能为空或重复。")
        try require(!groups.isEmpty && groups.count <= 9 && Set(groups.map(\.id)).count == groups.count, "组别须为 1–9 个，标识不能重复。")
        var keys = Set<Int>()
        for g in groups {
            try require(!g.id.isEmpty && !g.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "组名不能为空。")
            try require((0...9).contains(g.shortcut), "快捷键须为 0–9，0 表示关闭。")
            if g.shortcut != 0 { try require(keys.insert(g.shortcut).inserted, "组别快捷键不能重复。") }
            try require(!g.displays.isEmpty && Set(g.displays.map(\.serial)).count == g.displays.count, "组内显示器不能为空或重复。")
            for a in g.displays { try require(serials.contains(a.serial) && [15,17,27].contains(a.input), "显示器或输入源无效。") }
        }
    }
}
struct ConfigError: LocalizedError { let message: String; var errorDescription: String? { message } }
struct Operation: Encodable {
    var serial: String
    var input: Int?
    var brightness: Int?
}
func sourceName(_ value: Int) -> String { [15:"DP",17:"HDMI",27:"USB-C 90W"][value] ?? "未知 \(value)" }

// Accept the old configuration while discarding removed USB fields on the next save.
extension Configuration {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let oldVersion = try c.decode(Int.self, forKey: .version)
        guard [1, 2].contains(oldVersion) else { throw ConfigError(message: "配置版本不支持。") }
        version = 2
        monitors = try c.decode([MonitorSetting].self, forKey: .monitors)
        groups = try c.decode([SwitchGroup].self, forKey: .groups)
        shortcutsEnabled = try c.decode(Bool.self, forKey: .shortcutsEnabled)
    }
}
func brightnessPercent(current: Int, maximum: Int) throws -> Int {
    guard maximum > 0, maximum <= 65535, current >= 0, current <= maximum else {
        throw ConfigError(message: "显示器未返回有效亮度。请检查 DDC/CI、连接和 HDR 设置。")
    }
    return Int((Double(current) * 100 / Double(maximum)).rounded())
}
