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
rejected { $0.groups[1].shortcut = 1 }
rejected { $0.groups[0].displays[0].input = 16 }
rejected { $0.monitors[1].serial = $0.monitors[0].serial }
rejected { $0.groups[0].displays[0].serial = "missing" }
rejected { $0.version = 3 }
var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "Tests/Fixtures/v1-usb-config.json"))) as! [String: Any]
var groups = legacy["groups"] as! [[String: Any]]
groups[0]["name"] = "自定义 Mac"; groups[0]["shortcut"] = 8; legacy["groups"] = groups
let migrated = try JSONDecoder().decode(Configuration.self, from: JSONSerialization.data(withJSONObject: legacy))
try migrated.validate()
assert(migrated.version == 2 && migrated.groups[0].name == "自定义 Mac" && migrated.groups[0].shortcut == 8)
assert(migrated.groups[1].displays == c.groups[1].displays && migrated.monitors == c.monitors)
let exported = String(data: try JSONEncoder().encode(migrated), encoding: .utf8)!
assert(!exported.contains("usb"))
legacy["version"] = 3
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
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(c).write(to: URL(fileURLWithPath: "Shared/default.json"))
print("Core checks passed: config validation, legacy migration, brightness normalization and operation encoding")
