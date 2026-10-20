import AppKit
import SwiftUI

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
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
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
            NSAnimationContext.runAnimationGroup { context in context.duration = 0; entry.panel.animator().alphaValue = 1 }
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
        dismissal?.cancel(); dismissal = nil
        entries.values.forEach { $0.panel.close() }; entries.removeAll()
    }
}
