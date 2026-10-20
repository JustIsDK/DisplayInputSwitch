import Foundation

func rejected(_ body: (inout Configuration) -> Void) {
    var c = Configuration.initial; body(&c)
    do { try c.validate(); fatalError("Invalid configuration accepted") } catch {}
}
let c = Configuration.initial
try c.validate()
let data = try JSONEncoder().encode(c)
let decoded = try JSONDecoder().decode(Configuration.self, from: data)
assert(decoded == c)
rejected { $0.groups[1].shortcut = 1 }
rejected { $0.groups[0].displays[0].input = 16 }
rejected { $0.monitors[1].serial = $0.monitors[0].serial }
rejected { $0.usbProfiles[0].mac = 0xff00 }
rejected { $0.groups[0].displays[0].serial = "missing" }
do { _ = try usbOperation(config: c, input: 27, owner: "mac"); fatalError("Uncalibrated USB accepted") } catch {}
var calibrated = c
calibrated.usbProfiles = [.init(input: 27, mac: 0x1240, windows: 0x1280)]
let op = try usbOperation(config: calibrated, input: 27, owner: "mac")
assert(op.usbMask == 0xc0 && op.usbBits == 0x40)
assert((0x2280 & ~op.usbMask! | op.usbBits!) == 0x2240) // Preserve unrelated input associations.
let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(c).write(to: URL(fileURLWithPath: "Shared/default.json"))
print("Core checks passed: config roundtrip, rejected configurations, USB gating and masked association")
