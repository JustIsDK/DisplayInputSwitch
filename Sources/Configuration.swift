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
    var usb: String
    var shortcut: Int
}
struct USBProfile: Codable, Equatable {
    var input: Int
    var mac: Int?
    var windows: Int?
    var mask: Int? {
        guard let mac, let windows, mac >= 0, windows >= 0, mac < 0xff00, windows < 0xff00, mac != windows else { return nil }
        return mac ^ windows
    }
}
struct Configuration: Codable, Equatable {
    var version: Int
    var monitors: [MonitorSetting]
    var usbSerial: String
    var groups: [SwitchGroup]
    var shortcutsEnabled: Bool
    var usbProfiles: [USBProfile]
    static let initial = Configuration(version: 1,
        monitors: [.init(serial: "J80FDH3", name: "QX"), .init(serial: "330BJ04", name: "QE")],
        usbSerial: "J80FDH3", groups: [
            .init(id: "mac1", name: "Mac 1", displays: [.init(serial: "J80FDH3", input: 27), .init(serial: "330BJ04", input: 27)], usb: "mac", shortcut: 1),
            .init(id: "mac2", name: "Mac 2", displays: [.init(serial: "J80FDH3", input: 27), .init(serial: "330BJ04", input: 17)], usb: "mac", shortcut: 2),
            .init(id: "windows", name: "Windows", displays: [.init(serial: "J80FDH3", input: 15), .init(serial: "330BJ04", input: 15)], usb: "windows", shortcut: 3)
        ], shortcutsEnabled: true, usbProfiles: [15,17,27].map { .init(input: $0) })
    func validate() throws {
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw ConfigError(message: message) } }
        try require(version == 1, "配置版本不支持。")
        try require(!monitors.isEmpty && monitors.count <= 4, "显示器数量须为 1–4 台。")
        let serials = Set(monitors.map(\.serial))
        try require(serials.count == monitors.count && monitors.allSatisfy { !$0.serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.name.isEmpty }, "显示器名称和序列号不能为空或重复。")
        try require(serials.contains(usbSerial), "USB 显示器必须在显示器列表中。")
        try require(!groups.isEmpty && groups.count <= 9 && Set(groups.map(\.id)).count == groups.count, "组别须为 1–9 个，标识不能重复。")
        var keys = Set<Int>()
        for g in groups {
            try require(!g.id.isEmpty && !g.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "组名不能为空。")
            try require(["keep", "mac", "windows"].contains(g.usb), "USB 归属无效。")
            try require((0...9).contains(g.shortcut), "快捷键须为 0–9，0 表示关闭。")
            if g.shortcut != 0 { try require(keys.insert(g.shortcut).inserted, "组别快捷键不能重复。") }
            try require(!g.displays.isEmpty && Set(g.displays.map(\.serial)).count == g.displays.count, "组内显示器不能为空或重复。")
            for a in g.displays { try require(serials.contains(a.serial) && [15,17,27].contains(a.input), "显示器或输入源无效。") }
        }
        try require(Set(usbProfiles.map(\.input)).count == usbProfiles.count && usbProfiles.allSatisfy { [15,17,27].contains($0.input) && [$0.mac,$0.windows].allSatisfy { $0 == nil || (0..<0xff00).contains($0!) } }, "USB 校准数据无效；不能使用动作码或未支持的返回值。")
    }
}
struct ConfigError: LocalizedError { let message: String; var errorDescription: String? { message } }
struct Operation: Encodable {
    var serial: String
    var input: Int?
    var usbMask: Int?
    var usbBits: Int?
    var usbInput: Int?
}
func usbOperation(config: Configuration, input: Int, owner: String) throws -> Operation {
    guard ["mac","windows"].contains(owner), let p = config.usbProfiles.first(where: { $0.input == input }), let mask = p.mask,
          let value = owner == "mac" ? p.mac : p.windows else { throw ConfigError(message: "USB 未校准或此显示器未开放可用的 USB 关联寄存器。") }
    return Operation(serial: config.usbSerial, usbMask: mask, usbBits: value & mask, usbInput: input)
}
func sourceName(_ value: Int) -> String { [15:"DP",17:"HDMI",27:"USB-C 90W"][value] ?? "未知 \(value)" }
func usbName(_ owner: String) -> String { ["keep":"保持现状","mac":"Mac · USB-C 90W","windows":"Windows · USB-C 数据上行"][owner] ?? owner }
