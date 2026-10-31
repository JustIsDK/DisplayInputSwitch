import AppKit

@main struct NativeBrightnessHUDChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let hud = BrightnessHUD()
        defer { hud.hide() }
        let targets = NSScreen.screens.compactMap { screen -> (id: String, name: String, percent: Int)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            return (CFUUIDCreateString(nil, uuid) as String, screen.localizedName, 65)
        }
        precondition(!targets.isEmpty, "Requires a connected display")
        func systemWindows() -> [[String: Any]] {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            return windows.filter { ($0[kCGWindowOwnerName as String] as? String) == "OSDUIHelper" && ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0.01 }
        }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        hud.show(targets)
        try await Task.sleep(for: .milliseconds(450))
        precondition(systemWindows().count == targets.count, "System must render an OSD for each target")
        precondition(hud.visibleCount == 0, "Custom HUD must not appear alongside the system OSD")
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, "Must not activate the app")
        hud.show([(targets[0].id, targets[0].name, 35)])
        try await Task.sleep(for: .milliseconds(900)) // Allow the system's fade animation to complete.
        precondition(systemWindows().count == 1, "Changing targets must dismiss the previous display's OSD")
        try await Task.sleep(for: .seconds(2))
        precondition(systemWindows().isEmpty, "System OSD must dismiss automatically")
        hud.show(targets)
        try await Task.sleep(for: .milliseconds(300))
        hud.hide()
        try await Task.sleep(for: .milliseconds(900))
        precondition(systemWindows().isEmpty, "Hide must dismiss the system OSD")
        print("PASS: native multi-display OSD, target update, no activation, auto-dismiss and hide; no brightness settings changed")
    }
}
