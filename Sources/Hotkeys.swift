import AppKit
import SwiftUI
import Carbon

@MainActor final class Hotkeys {
    static let codes: [String: UInt32] = ["A":0,"S":1,"D":2,"F":3,"H":4,"G":5,"Z":6,"X":7,"C":8,"V":9,"B":11,"Q":12,"W":13,"E":14,"R":15,"Y":16,"T":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"EQUAL":24,"9":25,"7":26,"MINUS":27,"8":28,"0":29,"O":31,"U":32,"I":34,"P":35,"L":37,"J":38,"K":40,"COMMA":43,"N":45,"M":46,"PERIOD":47,"SPACE":49,"UP":126,"DOWN":125,"LEFT":123,"RIGHT":124,"F1":122,"F2":120,"F3":99,"F4":118,"F5":96,"F6":97,"F7":98,"F8":100,"F9":101,"F10":109,"F11":103,"F12":111]
    var refs: [EventHotKeyRef] = []
    var handler: EventHandlerRef?
    var actions: [Int: String] = [:]
    var action: ((String) -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            let instance = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            let number = Int(key.id)
            Task { @MainActor in if let id = instance.actions[number] { instance.action?(id) } }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func unregister() { refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll(); actions.removeAll() }
    func register(_ config: Configuration) -> String {
        // Validate before unregistering so an invalid edit does not replace working bindings.
        do { try config.validate() } catch { return error.localizedDescription }
        unregister()
        guard config.shortcutsEnabled else { return "全局快捷键已关闭" }
        var failed: [String] = []
        for (index,b) in config.effectiveHotkeys(mac: true).enumerated() {
            guard let code = Self.codes[b.key] else { continue }
            let bits = b.modifiers
            let modifiers = UInt32((bits & 1 != 0 ? controlKey : 0) | (bits & 2 != 0 ? optionKey : 0) | (bits & 4 != 0 ? shiftKey : 0) | (bits & 8 != 0 ? cmdKey : 0))
            var ref: EventHotKeyRef?
            let id = index + 1
            if RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: 0x44535747, id: UInt32(id)), GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref); actions[id] = b.action
            } else { failed.append(config.shortcutActions.first { $0.id == b.action }?.name ?? b.action) }
        }
        return failed.isEmpty ? "全局快捷键已注册（切换到其他应用也有效）" : "快捷键被占用或系统拒绝：" + failed.joined(separator: "、")
    }
    static func label(_ b: KeyBinding) -> String {
        guard !b.key.isEmpty else { return "未设置" }
        let symbols = [(1,"⌃"),(2,"⌥"),(4,"⇧"),(8,"⌘")].filter { b.modifiers & $0.0 != 0 }.map(\.1).joined()
        return symbols + (["UP":"↑","DOWN":"↓","LEFT":"←","RIGHT":"→","SPACE":"空格","MINUS":"−","EQUAL":"=","COMMA":",","PERIOD":"."][b.key] ?? b.key)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: SwitchModel
    let action: String
    func makeNSView(context: Context) -> RecordButton { let b = RecordButton(); updateNSView(b, context: context); return b }
    func updateNSView(_ view: RecordButton, context: Context) {
        view.model = model; view.operation = action
        if model.recordingAction != action { view.title = Hotkeys.label(model.binding(for: action)) }
    }
    static func dismantleNSView(_ view: RecordButton, coordinator: ()) {
        if view.model?.recordingAction == view.operation { view.model?.finishRecording(nil) }
    }
    final class RecordButton: NSButton {
        weak var model: SwitchModel?
        var operation = ""
        override var acceptsFirstResponder: Bool { true }
        init() { super.init(frame: .zero); bezelStyle = .rounded; target = self; action = #selector(record); setAccessibilityLabel("录制全局快捷键") }
        required init?(coder: NSCoder) { fatalError() }
        @objc func record() { window?.makeFirstResponder(self); model?.beginRecording(operation); title = "请按组合键（Esc 取消）" }
        override func keyDown(with event: NSEvent) {
            guard model?.recordingAction == operation else { super.keyDown(with: event); return }
            if event.keyCode == 53 { model?.finishRecording(nil); return }
            guard let key = Hotkeys.codes.first(where: { $0.value == event.keyCode })?.key else { title = "暂不支持此按键"; return }
            let f = event.modifierFlags
            let bits = (f.contains(.control) ? 1 : 0) | (f.contains(.option) ? 2 : 0) | (f.contains(.shift) ? 4 : 0) | (f.contains(.command) ? 8 : 0)
            let binding = KeyBinding(action: operation, key: key, modifiers: bits)
            do { try binding.validate(); model?.finishRecording(binding) }
            catch { title = "请同时按 Control / Option / Command" }
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if model?.recordingAction == operation { keyDown(with: event); return true }
            return super.performKeyEquivalent(with: event)
        }
        override func resignFirstResponder() -> Bool {
            if model?.recordingAction == operation { model?.finishRecording(nil) }
            return super.resignFirstResponder()
        }
    }
}
struct ShortcutSettings: View {
    @ObservedObject var model: SwitchModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("状态栏亮度").font(.headline)
                Picker("滑块显示方式", selection: $model.config.menuBrightnessLinked) {
                    Text("分开调节 · 每屏一条").tag(false)
                    Text("一起调节 · 仅一条").tag(true)
                }.pickerStyle(.segmented)
                Text("联动滑块显示第一台屏幕的值，应用时将所有屏幕设为相同比例。改变显示方式不会自动修改亮度。").font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("启用全局快捷键", isOn: $model.config.shortcutsEnabled)
                Stepper("每次调亮 / 调暗：\(model.config.brightnessStep)%", value: $model.config.brightnessStep, in: 1...20)
                Text("亮度快捷键跟随当前调光方式。点击按键框后按下组合键，Esc 取消；清除可禁用单项。保存后在所有应用中生效。").font(.callout).foregroundStyle(.secondary)
                ForEach(model.config.shortcutActions) { item in
                    HStack {
                        Text(item.name).frame(maxWidth: .infinity, alignment: .leading)
                        ShortcutRecorder(model: model, action: item.id).frame(width: 230, height: 28)
                        Button("清除") { model.clearBinding(item.id) }
                    }
                }
                Text(model.shortcutStatus).font(.callout).textSelection(.enabled)
                HStack { Button("保存配置") { model.save() }; Text(model.saveStatus).font(.callout) }
            }.padding(20)
        }
    }
}
