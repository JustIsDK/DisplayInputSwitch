import AppKit
import ApplicationServices

// NX_SYSDEFINED / NX_SUBTYPE_AUX_CONTROL_BUTTONS, as defined by IOKit's event headers.
func brightnessKeyDirection(subtype: Int, data: Int) -> Int? {
    guard subtype == 8, [0x0a, 0x0b].contains((data >> 8) & 0xff) else { return nil }
    switch (data >> 16) & 0xffff {
    case 2: return 1
    case 3: return -1
    default: return nil
    }
}
func brightnessKeyPressed(data: Int) -> Bool { (data >> 8) & 0xff == 0x0a }

@MainActor final class BrightnessKeys {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var action: ((Int) -> Void)?
    var acceptsEvent: (() -> Bool)?
    var running: Bool { tap != nil }
    var trusted: Bool { AXIsProcessTrusted() }

    func start() -> Bool {
        if tap != nil { return true }
        guard trusted else { return false }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: CGEventMask(1 << 14), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let instance = Unmanaged<BrightnessKeys>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = instance.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard let key = NSEvent(cgEvent: event),
                      let direction = brightnessKeyDirection(subtype: Int(key.subtype.rawValue), data: key.data1),
                      key.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      instance.acceptsEvent?() == true else { return Unmanaged.passUnretained(event) }
                if brightnessKeyPressed(data: key.data1) { instance.action?(direction) }
                return nil // Consume both press and release to avoid a second system action.
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }
    func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
}
