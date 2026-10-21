import AppKit

// Adapted from MonitorControl DisplayManager.swift, MIT License, Copyright © 2017.
// Source: 7cfe64500d19cbbcbf82121a91c826f658a403bd; see vendor/MonitorControl/LICENSE.
@MainActor final class SoftwareDimming {
    private struct GammaState {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
        let sampleCount: UInt32
    }
    private var shades: [String: NSWindow] = [:]
    private var gamma: [String: GammaState] = [:]
    private lazy var gammaActivityEnforcer: NSWindow = {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [], backing: .buffered, defer: false)
        window.title = "DisplayInputSwitch Gamma Activity Enforcer"
        window.backgroundColor = .black
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.stationary, .canJoinAllSpaces]
        window.orderFrontRegardless()
        return window
    }()
    private(set) var levels: [String: Int] = [:]
    private(set) var gammaDisplays: Set<String> = []

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
    private func baseGamma(for id: String, displayID: CGDirectDisplayID) -> GammaState? {
        if let state = gamma[id] { return state }
        var red = [CGGammaValue](repeating: 0, count: 256)
        var green = red, blue = red, count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, UInt32(red.count), &red, &green, &blue, &count) == .success,
              count > 0 else { return nil }
        let state = GammaState(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))), blue: Array(blue.prefix(Int(count))), sampleCount: count)
        gamma[id] = state
        return state
    }
    private func setGamma(_ state: GammaState, displayID: CGDirectDisplayID, percent: Int) -> Bool {
        // MonitorControl keeps a small floor so the display never loses its transfer curve.
        let factor = CGGammaValue(0.15 + 0.85 * Double(percent) / 100)
        var red = state.red.map { $0 * factor }
        var green = state.green.map { $0 * factor }
        var blue = state.blue.map { $0 * factor }
        return red.withUnsafeMutableBufferPointer { r in
            green.withUnsafeMutableBufferPointer { g in
                blue.withUnsafeMutableBufferPointer { b in
                    CGSetDisplayTransferByTable(displayID, state.sampleCount, r.baseAddress, g.baseAddress, b.baseAddress) == .success
                }
            }
        }
    }
    private func moveGammaActivityEnforcer(displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { return }
        gammaActivityEnforcer.setFrameOrigin(screen.frame.origin)
        gammaActivityEnforcer.orderFrontRegardless()
    }
    private func enforceGammaActivity() {
        gammaActivityEnforcer.alphaValue = gammaActivityEnforcer.alphaValue == 0.01 ? 0.02 : 0.01
    }
    private func restoreGamma(_ id: String, displayID: CGDirectDisplayID) {
        guard let state = gamma[id] else { return }
        _ = setGamma(state, displayID: displayID, percent: 100)
        gamma.removeValue(forKey: id)
        gammaDisplays.remove(id)
    }
    func apply(_ ids: [String], percent: Int, gammaIDs: Set<String> = []) throws {
        let opacity = try softwareOpacity(percent: percent)
        guard !ids.isEmpty, Set(ids).count == ids.count else {
            throw ConfigError(message: "调暗计划为空或重复。")
        }
        let current = screens()
        guard ids.allSatisfy({ current[$0] != nil }) else {
            throw ConfigError(message: "显示器当前不可见；本组未调暗。")
        }
        for id in ids {
            let displayID = current[id]!.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
            if percent == 100 {
                restoreGamma(id, displayID: displayID.uint32Value)
                shades.removeValue(forKey: id)?.close()
                levels.removeValue(forKey: id)
                continue
            }
            if gammaIDs.contains(id), let state = baseGamma(for: id, displayID: displayID.uint32Value) {
                moveGammaActivityEnforcer(displayID: displayID.uint32Value)
                if setGamma(state, displayID: displayID.uint32Value, percent: percent) {
                enforceGammaActivity()
                shades.removeValue(forKey: id)?.close()
                gammaDisplays.insert(id)
                levels[id] = percent
                continue
                }
            }
            restoreGamma(id, displayID: displayID.uint32Value)
            let panel: NSWindow
            if let existing = shades[id] { panel = existing }
            else {
                panel = NSWindow(contentRect: current[id]!.frame, styleMask: [], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
                panel.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
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
            if let screen = current[id] {
                shades[id]?.setFrame(screen.frame, display: true)
                shades[id]?.orderFrontRegardless()
            }
            else { shades.removeValue(forKey: id)?.close(); levels.removeValue(forKey: id) }
        }
    }
    func reset() {
        let current = screens()
        for id in gamma.keys where current[id] != nil {
            let number = current[id]!.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
            restoreGamma(id, displayID: number.uint32Value)
        }
        shades.values.forEach { $0.close() }
        shades.removeAll(); gamma.removeAll(); gammaDisplays.removeAll(); levels.removeAll()
    }
}
