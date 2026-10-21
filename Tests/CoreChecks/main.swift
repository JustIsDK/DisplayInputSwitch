import Foundation

func mustReject(_ body: () throws -> Void) {
    do { try body() } catch { return }
    fatalError("Invalid value accepted")
}
func rejected(_ body: (inout Configuration) -> Void) {
    var c = Configuration.initial; body(&c)
    mustReject { try c.validate() }
}
let c = Configuration.initial
try c.validate()
let data = try JSONEncoder().encode(c)
let decoded = try JSONDecoder().decode(Configuration.self, from: data)
assert(decoded == c)
assert(c.groups.allSatisfy { $0.switchDelayMs == 2000 })
var delayed = c
delayed.groups[0].switchDelayMs = 0; delayed.groups[1].switchDelayMs = 10000
let delayedCopy = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(delayed))
assert(delayedCopy == delayed)
rejected { $0.groups[0].switchDelayMs = -1 }
rejected { $0.groups[0].switchDelayMs = 10001 }
rejected { $0.groups[1].shortcut = 1 }
rejected { $0.groups[0].displays[0].input = 16 }
rejected { $0.monitors[1].serial = $0.monitors[0].serial }
rejected { $0.groups[0].displays[0].serial = "missing" }
rejected { $0.version = 4 }
var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/v1-usb-config.json"))) as! [String: Any]
var groups = legacy["groups"] as! [[String: Any]]
groups[0]["name"] = "自定义 Mac"; groups[0]["shortcut"] = 8; legacy["groups"] = groups
let migrated = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: legacy))
try migrated.validate()
assert(migrated.version == 3 && migrated.groups[0].name == "自定义 Mac" && migrated.groups[0].shortcut == 8)
assert(migrated.groups.allSatisfy { $0.switchDelayMs == 2000 })
assert(migrated.groups[1].displays == c.groups[1].displays && migrated.monitors == c.monitors)
let exported = String(data: try JSONEncoder().encode(migrated), encoding: .utf8)!
assert(!exported.contains("usb"))
legacy["version"] = 4
mustReject { _ = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: legacy)) }
for (current, maximum, expected) in [(0,100,0),(100,100,100),(128,255,50),(1,8,13),(65535,65535,100)] {
    let actual = try brightnessPercent(current: current, maximum: maximum)
    assert(actual == expected)
}
for (current, maximum) in [(-1,100),(101,100),(0,0),(0,65536)] {
    mustReject { _ = try brightnessPercent(current: current, maximum: maximum) }
}
let operation = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Operation(serial: "test", brightness: 35))) as! [String: Any]
assert(operation["input"] == nil && operation["brightness"] as? Int == 35)
let single = try JSONSerialization.jsonObject(with: JSONEncoder().encode([Operation(serial: "J80FDH3", input: 15)])) as! [[String: Any]]
assert(single.count == 1 && single[0]["serial"] as? String == "J80FDH3" && single[0]["input"] as? Int == 15 && single[0]["brightness"] == nil)
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let full = try softwareOpacity(percent: 100), minimum = try softwareOpacity(percent: 10)
assert(full == 0 && minimum == 0.9)
for value in [-1, 0, 9, 101] { mustReject { _ = try softwareOpacity(percent: value) } }
try encoder.encode(c).write(to: URL(fileURLWithPath: "Shared/default.json"))
print("Core checks passed: config validation, legacy migration, brightness normalization and operation encoding")

let v2 = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/v2-config.json")))
assert(v2.version == 3 && !v2.menuBrightnessLinked && v2.brightnessStep == 5 && v2.hotkeys.isEmpty)
assert(v2.effectiveHotkeys(mac: true).map(\.key) == ["1","2","3"])
var custom = c
custom.menuBrightnessLinked = true; custom.brightnessStep = 7
custom.hotkeys = [.init(action: "brightness:down:all",key: "DOWN",modifiers: 11),.init(action: "group:mac1",key: "",modifiers: 0)]
try custom.validate()
let customCopy = try JSONDecoder().decode(Configuration.self,from: JSONEncoder().encode(custom))
assert(customCopy == custom && !customCopy.effectiveHotkeys(mac: true).contains { $0.action == "group:mac1" })
rejected { $0.brightnessStep = 0 }; rejected { $0.brightnessStep = 21 }
rejected { $0.hotkeys = [.init(action: "missing",key: "A",modifiers: 1)] }
rejected { $0.hotkeys = [.init(action: "brightness:down:all",key: "DOWN",modifiers: 4)] }
rejected { $0.hotkeys = [.init(action: "brightness:down:all",key: "UNSUPPORTED",modifiers: 1)] }
rejected { $0.hotkeys = [.init(action: "brightness:down:all",key: "1",modifiers: 11)] }
rejected { $0.hotkeys = [.init(action: "brightness:down:all",key: "1",modifiers: 7)] }
rejected { $0.hotkeys = [.init(action: "brightness:down:all",key: "DOWN",modifiers: 1),.init(action: "brightness:up:all",key: "DOWN",modifiers: 1)] }
assert(adjustedBrightness(current: 98,delta: 5,software: true) == 100)
assert(adjustedBrightness(current: 12,delta: -5,software: true) == 10)
assert(adjustedBrightness(current: 2,delta: -5,software: false) == 0)
assert(brightnessUsesSoftware(mode: "auto",hdr: true) && !brightnessUsesSoftware(mode: "auto",hdr: false) && brightnessUsesSoftware(mode: "auto",hdr: nil))
assert(brightnessUsesSoftware(mode: "software",hdr: false) && !brightnessUsesSoftware(mode: "hardware",hdr: true))
print("Status layout, hotkey migration/conflicts, step limits and HDR routing checks passed")
