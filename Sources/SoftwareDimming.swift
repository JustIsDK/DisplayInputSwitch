import AppKit

// Adapted from MonitorControl DisplayManager.swift, MIT License, Copyright © 2017.
// Source: 7cfe64500d19cbbcbf82121a91c826f658a403bd; see vendor/MonitorControl/LICENSE.
// A click-through shade leaves HDR and other apps' gamma tables untouched.
// MonitorControl places this shade at CGShieldingWindowLevel(), rather than
// the ordinary screen-saver level, so system overlays such as IME candidates
// are covered as well.
@MainActor final class SoftwareDimming {
    private var shades: [String: NSPanel] = [:]
    private(set) var levels: [String: Int] = [:]

    private func screens() -> [String: NSScreen] {
        var result: [String: NSScreen] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { continue }
            result[CFUUIDCreateString(nil, uuid) as String] = screen
        }
        return result
    }
    func available(_ id: String) -> Bool { screens()[id] != nil }
    func apply(_ ids: [String], percent: Int) throws {
        let opacity = try softwareOpacity(percent: percent)
        guard !ids.isEmpty, Set(ids).count == ids.count else {
            throw ConfigError(message: "调暗计划为空或重复。")
        }
        let current = screens()
        guard ids.allSatisfy({ current[$0] != nil }) else {
            throw ConfigError(message: "显示器当前不可见；本组未调暗。")
        }
        for id in ids {
            if percent == 100 {
                shades.removeValue(forKey: id)?.close()
                levels.removeValue(forKey: id)
                continue
            }
            let panel: NSPanel
            if let existing = shades[id] { panel = existing }
            else {
                panel = NSPanel(contentRect: current[id]!.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                panel.setAccessibilityElement(false)
                panel.contentView?.wantsLayer = true
                panel.contentView?.layer?.backgroundColor = NSColor.black.cgColor
                shades[id] = panel
            }
            panel.setFrame(current[id]!.frame, display: true)
            panel.contentView?.alphaValue = opacity
            panel.orderFrontRegardless()
            levels[id] = percent
        }
    }
    func reconcile() {
        let current = screens()
        for id in Array(shades.keys) {
            if let screen = current[id] { shades[id]?.setFrame(screen.frame, display: true) }
            else { shades.removeValue(forKey: id)?.close(); levels.removeValue(forKey: id) }
        }
    }
    func reset() {
        shades.values.forEach { $0.close() }
        shades.removeAll(); levels.removeAll()
    }
}
