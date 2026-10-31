import AppKit
import SwiftUI

@objc private protocol SystemOSDProtocol {
    @objc(showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:)
    func showImage(_ image: Int64, onDisplayID: UInt32, priority: UInt32, msecUntilFade: UInt32,
                   filledChiclets: UInt32, totalChiclets: UInt32, locked: Bool)
    @objc(fadeClassicImageOnDisplay:)
    func fadeClassicImage(onDisplay: UInt32)
}

// shortcut: Apple's private OSD service may change; use our own HUD if the connection fails.
@MainActor private final class SystemBrightnessOSD {
    private var connection: NSXPCConnection?
    private var displayIDs: Set<UInt32> = []
    private var failure: (@MainActor () -> Void)?
    func show(_ values: [(displayID: UInt32, percent: Int)], onFailure: @escaping @MainActor () -> Void) {
        guard FileManager.default.fileExists(atPath: "/System/Library/CoreServices/OSDUIHelper.app") else { onFailure(); return }
        failure = onFailure
        let connection: NSXPCConnection
        if let existing = self.connection { connection = existing }
        else {
            connection = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
            connection.remoteObjectInterface = NSXPCInterface(with: SystemOSDProtocol.self)
            self.connection = connection
            connection.resume()
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] _ in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                let fallback = self.failure; self.failure = nil
                self.connection?.invalidate(); self.connection = nil
                fallback?()
            }
        }
        guard let helper = proxy as? SystemOSDProtocol else { onFailure(); return }
        let targets = Set(values.map(\.displayID))
        for id in displayIDs.subtracting(targets) { helper.fadeClassicImage(onDisplay: id) }
        displayIDs = targets
        for value in values {
            helper.showImage(1, onDisplayID: value.displayID, priority: 0x1F4, msecUntilFade: 1200,
                             filledChiclets: UInt32(value.percent), totalChiclets: 100, locked: false)
        }
    }
    func hide() {
        failure = nil
        if let helper = connection?.remoteObjectProxy as? SystemOSDProtocol {
            for id in displayIDs { helper.fadeClassicImage(onDisplay: id) }
        }
        displayIDs.removeAll()
    }
}

private struct BrightnessHUDContent: View {
    let name: String
    let percent: Int
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sun.max.fill").font(.system(size: 52, weight: .regular))
                .accessibilityHidden(true)
            Text("\(name) · \(percent)%").font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white).frame(width: geometry.size.width * Double(percent) / 100)
                }
            }.frame(height: 7)
        }.foregroundStyle(.white).padding(22).frame(width: 180, height: 170)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(name)亮度 \(percent)%")
    }
}

@MainActor final class BrightnessHUD {
    private let systemOSD = SystemBrightnessOSD()
    private let useSystem: Bool
    private var generation = 0
    init(useSystem: Bool = true) { self.useSystem = useSystem }
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private struct Entry {
        let panel: NSPanel
        let content: NSHostingView<BrightnessHUDContent>
    }
    private var entries: [String: Entry] = [:]
    private var dismissal: Task<Void, Never>?
    var visibleCount: Int { entries.values.filter { $0.panel.isVisible }.count }

    func show(_ values: [(id: String, name: String, percent: Int)]) {
        generation += 1
        let request = generation
        guard useSystem else { showCustom(values); return }
        let targets = NSScreen.screens.compactMap { screen -> (displayID: UInt32, percent: Int)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let value = values.first(where: { $0.id == CFUUIDCreateString(nil, uuid) as String }),
                  (0...100).contains(value.percent) else { return nil }
            return (number.uint32Value, value.percent)
        }
        dismissal?.cancel()
        entries.values.forEach { $0.panel.close() }; entries.removeAll()
        systemOSD.show(targets) { [weak self] in
            guard let self, self.generation == request else { return }
            self.showCustom(values)
        }
    }
    private func showCustom(_ values: [(id: String, name: String, percent: Int)]) {
        dismissal?.cancel()
        let targets = Set(values.map(\.id))
        for id in entries.keys.filter({ !targets.contains($0) }) { entries.removeValue(forKey: id)?.panel.close() }
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
                  let value = values.first(where: { $0.id == CFUUIDCreateString(nil, uuid) as String }),
                  (0...100).contains(value.percent) else { continue }
            let content = BrightnessHUDContent(name: value.name, percent: value.percent)
            let entry: Entry
            if let existing = entries[value.id] { entry = existing; entry.content.rootView = content }
            else {
                let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
                panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
                // Keep feedback above our software shade without activating the app.
                panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                panel.title = "亮度提示"
                let material = NSVisualEffectView()
                material.material = .hudWindow; material.blendingMode = .behindWindow; material.state = .active
                material.appearance = NSAppearance(named: .darkAqua)
                material.wantsLayer = true; material.layer?.cornerRadius = 22; material.layer?.masksToBounds = true
                let host = NSHostingView(rootView: content)
                host.autoresizingMask = [.width, .height]; material.addSubview(host)
                panel.contentView = material
                entry = Entry(panel: panel, content: host); entries[value.id] = entry
            }
            let frame = screen.visibleFrame
            entry.panel.setFrame(NSRect(x: frame.midX - 90, y: frame.minY + frame.height * 0.18, width: 180, height: 170), display: true)
            entry.content.frame = entry.panel.contentView!.bounds
            // Cancel any fade already in flight before reusing the panel.
            entry.panel.alphaValue = 1
            entry.panel.orderFrontRegardless()
        }
        dismissal = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.2))
                guard let self else { return }
                let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = duration
                    for entry in self.entries.values { entry.panel.animator().alphaValue = 0 }
                }
                try Task.checkCancellation()
                self.hide()
            } catch { /* A new adjustment extends the existing HUD's lifetime. */ }
        }
    }
    func hide() {
        generation += 1; systemOSD.hide()
        dismissal?.cancel(); dismissal = nil
        entries.values.forEach { $0.panel.close() }; entries.removeAll()
    }
}
