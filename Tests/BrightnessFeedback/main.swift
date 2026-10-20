import AppKit

@main struct BrightnessFeedbackChecks {
    @MainActor static func main() async throws {
        let down = (3 << 16) | 0x0a00, up = (2 << 16) | 0x0b00
        assert(brightnessKeyDirection(subtype: 8, data: down) == -1 && brightnessKeyPressed(data: down))
        assert(brightnessKeyDirection(subtype: 8, data: up) == 1 && !brightnessKeyPressed(data: up))
        assert(brightnessKeyPressed(data: down | 1)) // Held-key repeats use the low bit.
        assert(brightnessKeyDirection(subtype: 7, data: down) == nil)
        assert(brightnessKeyDirection(subtype: 8, data: (0 << 16) | 0x0a00) == nil) // Volume is untouched.
        assert(brightnessKeyDirection(subtype: 8, data: 3 << 16) == nil)

        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let keys = BrightnessKeys()
        var directions: [Int] = []
        keys.acceptsEvent = { true }; keys.action = { directions.append($0) }
        let started = keys.start()
        if started {
            for data in [down, up] {
                let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1)!
                event.cgEvent!.post(tap: .cgSessionEventTap)
            }
            try await Task.sleep(for: .milliseconds(150))
            assert(directions == [-1], "Tap must deliver only key presses, once each")
            print("PASS: active brightness event tap with synthetic press/release")
        } else {
            print("Brightness event tap unavailable for this test process; no permission prompt was requested")
        }
        keys.stop(); assert(!keys.running)

        let hud = BrightnessHUD()
        defer { hud.hide() }
        let targets = NSScreen.screens.compactMap { screen -> (id: String, name: String, percent: Int)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            return (CFUUIDCreateString(nil, uuid) as String, "亮度测试", 65)
        }
        guard !targets.isEmpty else { throw ConfigError(message: "HUD test requires a desktop screen") }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        hud.show(targets)
        assert(hud.visibleCount == targets.count)
        let panels = NSApp.windows.filter { $0.title == "亮度提示" }
        assert(panels.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey && !$0.canBecomeMain })
        assert(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        try await Task.sleep(for: .milliseconds(800))
        hud.show([(targets[0].id, "连续调节", 70)])
        assert(hud.visibleCount == 1)
        assert(NSApp.windows.filter { $0.title == "亮度提示" && $0.isVisible }.first === panels.first { $0.screen == NSScreen.screens.first })
        try await Task.sleep(for: .milliseconds(650))
        assert(hud.visibleCount == 1, "An old dismissal must not hide new feedback")
        try await Task.sleep(for: .seconds(1))
        assert(hud.visibleCount == 0, "HUD must dismiss itself")
        hud.show(targets)
        try await Task.sleep(for: .milliseconds(1250))
        hud.show([(targets[0].id, "淡出期间再次调节", 80)])
        try await Task.sleep(for: .milliseconds(300))
        assert(hud.visibleCount == 1 && NSApp.windows.filter { $0.title == "亮度提示" && $0.isVisible }.allSatisfy { $0.alphaValue > 0.99 }, "Updating during a fade must restore the HUD")
        print("PASS: brightness key decoding, click-through HUD, no activation, reuse, target change and auto-dismiss")
    }
}
