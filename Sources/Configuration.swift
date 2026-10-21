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
    var switchDelayMs = 2000

    init(id: String, name: String, displays: [Assignment], shortcut: Int, switchDelayMs: Int = 2000) {
        self.id = id; self.name = name; self.displays = displays; self.shortcut = shortcut; self.switchDelayMs = switchDelayMs
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        displays = try c.decode([Assignment].self, forKey: .displays)
        shortcut = try c.decode(Int.self, forKey: .shortcut)
        switchDelayMs = try c.decodeIfPresent(Int.self, forKey: .switchDelayMs) ?? 2000
    }
}
struct Configuration: Codable, Equatable {
    var version: Int
    var monitors: [MonitorSetting]
    var groups: [SwitchGroup]
    var shortcutsEnabled: Bool
    var menuBrightnessLinked = false
    var brightnessStep = 5
    var hotkeys: [KeyBinding] = []
    static let initial = Configuration(version: 3,
        monitors: [.init(serial: "J80FDH3", name: "QX"), .init(serial: "330BJ04", name: "QE")],
        groups: [
            .init(id: "mac1", name: "Mac 1", displays: [.init(serial: "J80FDH3", input: 27), .init(serial: "330BJ04", input: 27)], shortcut: 1),
            .init(id: "mac2", name: "Mac 2", displays: [.init(serial: "J80FDH3", input: 27), .init(serial: "330BJ04", input: 17)], shortcut: 2),
            .init(id: "windows", name: "Windows", displays: [.init(serial: "J80FDH3", input: 15), .init(serial: "330BJ04", input: 15)], shortcut: 3)
        ], shortcutsEnabled: true)
    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw ConfigError(message: message) } }
        try require(version == 3, "配置版本不支持。")
        try require(!monitors.isEmpty && monitors.count <= 4, "显示器数量须为 1–4 台。")
        let serials = Set(monitors.map(\.serial))
        try require(serials.count == monitors.count && monitors.allSatisfy { !$0.serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.isEmpty }, "显示器名称和序列号不能为空或重复。")
        try require(!groups.isEmpty && groups.count <= 9 && Set(groups.map(\.id)).count == groups.count, "组别须为 1–9 个，标识不能重复。")
        var keys = Set<Int>()
        for g in groups {
            try require((0...10000).contains(g.switchDelayMs), "切换间隔须为 0–10000 毫秒。")
            try require(!g.id.isEmpty && !g.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "组名不能为空。")
            try require((0...9).contains(g.shortcut), "快捷键须为 0–9，0 表示关闭。")
            if g.shortcut != 0 { try require(keys.insert(g.shortcut).inserted, "组别快捷键不能重复。") }
            try require(!g.displays.isEmpty && Set(g.displays.map(\.serial)).count == g.displays.count, "组内显示器不能为空或重复。")
            for a in g.displays { try require(serials.contains(a.serial) && [15,17,27].contains(a.input), "显示器或输入源无效。") }
        }
        try require((1...20).contains(brightnessStep), "亮度步长须为 1–20%。")
        let actions = Set(shortcutActions.map(\.id))
        try require(Set(hotkeys.map(\.action)).count == hotkeys.count, "同一操作不能重复配置快捷键。")
        for h in hotkeys {
            try require(actions.contains(h.action), "快捷键操作不存在。")
            try h.validate()
        }
        for mac in [true, false] {
            let bindings = effectiveHotkeys(mac: mac)
            try require(Set(bindings.map { "\($0.modifiers):\($0.key)" }).count == bindings.count, "快捷键重复，请修改后保存。")
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
        guard [1, 2, 3].contains(oldVersion) else { throw ConfigError(message: "配置版本不支持。") }
        version = 3
        monitors = try c.decode([MonitorSetting].self, forKey: .monitors)
        groups = try c.decode([SwitchGroup].self, forKey: .groups)
        shortcutsEnabled = try c.decode(Bool.self, forKey: .shortcutsEnabled)
        menuBrightnessLinked = try c.decodeIfPresent(Bool.self, forKey: .menuBrightnessLinked) ?? false
        brightnessStep = try c.decodeIfPresent(Int.self, forKey: .brightnessStep) ?? 5
        hotkeys = try c.decodeIfPresent([KeyBinding].self, forKey: .hotkeys) ?? []
    }
}
func brightnessPercent(current: Int, maximum: Int) throws -> Int {
    guard maximum > 0, maximum <= 65535, current >= 0, current <= maximum else {
        throw ConfigError(message: "显示器未返回有效亮度。请检查 DDC/CI、连接和 HDR 设置。")
    }
    return Int((Double(current) * 100 / Double(maximum)).rounded())
}
func softwareOpacity(percent: Int) throws -> Double {
    guard (10...100).contains(percent) else { throw ConfigError(message: "软件亮度须为 10–100%。") }
    return Double(100 - percent) / 100
}

struct KeyBinding: Codable, Equatable {
    var action: String
    var key: String
    var modifiers: Int // Control 1, Alt/Option 2, Shift 4, Command/Win 8.
    static let keys = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").map(String.init) + ["UP", "DOWN", "LEFT", "RIGHT", "SPACE", "MINUS", "EQUAL", "COMMA", "PERIOD"] + (1...12).map { "F\($0)" }
    func validate() throws {
        guard key.isEmpty ? modifiers == 0 : Self.keys.contains(key) && (1...15).contains(modifiers) && modifiers & 11 != 0 else {
            throw ConfigError(message: "快捷键须包含 Control、Option/Alt 或 Command/Win，且使用支持的按键。")
        }
    }
}
struct ShortcutAction: Identifiable { var id: String; var name: String }
struct BrightnessAction {
    var id: String; var name: String; var serials: [String]; var direction: Int
}
extension Configuration {
    var brightnessActions: [BrightnessAction] {
        let targets = [("all", "所有显示器", monitors.map(\.serial))] + monitors.map { ("monitor:" + $0.serial, $0.name, [$0.serial]) }
        return targets.flatMap { id, name, serials in
            [BrightnessAction(id: "brightness:up:" + id, name: name + " · 调亮", serials: serials, direction: 1),
             BrightnessAction(id: "brightness:down:" + id, name: name + " · 调暗", serials: serials, direction: -1)]
        }
    }
    var shortcutActions: [ShortcutAction] {
        groups.map { .init(id: "group:" + $0.id, name: "切换到 " + $0.name) } + brightnessActions.map { .init(id: $0.id, name: $0.name) } + [.init(id: "brightness:restore", name: "恢复所有软件调暗（100%）")]
    }
    func effectiveHotkeys(mac: Bool) -> [KeyBinding] {
        let legacy = groups.filter { g in g.shortcut != 0 && !hotkeys.contains { $0.action == "group:" + g.id } }.map {
            KeyBinding(action: "group:" + $0.id, key: String($0.shortcut), modifiers: mac ? 11 : 7)
        }
        return legacy + hotkeys.filter { !$0.key.isEmpty }
    }
}
func adjustedBrightness(current: Int, delta: Int, software: Bool) -> Int {
    min(100, max(software ? 10 : 0, current + delta))
}
func brightnessUsesSoftware(mode: String, hdr: Bool?) -> Bool {
    mode == "hardware" ? false : mode == "software" ? true : hdr ?? true
}
