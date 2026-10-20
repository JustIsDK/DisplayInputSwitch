// Optional macOS visual smoke test; creates white sample windows and restores shades on exit.
import AppKit

@MainActor func verify() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let dimming = SoftwareDimming()
    var samples: [(id: String, window: NSWindow, region: String)] = []
    defer { dimming.reset(); samples.forEach { $0.window.close() } }
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDisplayIsBuiltin(number.uint32Value) == 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { continue }
        let id = CFUUIDCreateString(nil, uuid) as String
        let display = CGDisplayBounds(number.uint32Value)
        let frame = NSRect(x: screen.frame.minX + 80, y: screen.frame.maxY - 180, width: 100, height: 100)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.backgroundColor = .white
        window.level = .floating; window.orderFrontRegardless()
        samples.append((id, window, "\(Int(display.minX + 105)),\(Int(display.minY + 105)),50,50"))
    }
    guard !samples.isEmpty else { throw ConfigError(message: "No external displays") }
    func sample(_ region: String) throws -> Double {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: path) }
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-R", region, path.path]; try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0, let bitmap = NSBitmapImageRep(data: try Data(contentsOf: path)),
              let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
            throw ConfigError(message: "Screenshot sample unavailable")
        }
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }
    let before = try samples.map { try sample($0.region) }
    try dimming.apply([samples[0].id], percent: 50)
    assert(dimming.levels[samples[0].id] == 50)
    do { try dimming.apply([samples[0].id, "__missing__"], percent: 20); fatalError("Missing target accepted") } catch { }
    assert(dimming.levels[samples[0].id] == 50)
    try dimming.apply(samples.map(\.id), percent: 60)
    for (i, s) in samples.enumerated() {
        let after = try sample(s.region)
        assert(after < before[i] * 0.9, "Shade did not visibly darken sampled pixels")
        print("Display \(i + 1) pixel brightness: \(before[i]) → \(after)")
    }
    dimming.reconcile()
    try dimming.apply(samples.map(\.id), percent: 100)
    assert(dimming.levels.isEmpty)
    for (i, s) in samples.enumerated() {
        let restored = try sample(s.region)
        assert(abs(restored - before[i]) < 0.03)
    }
    print("PASS: visible software dimming, all-target preflight, linked dimming, 100% restoration")
}
try MainActor.assumeIsolated { try verify() }
