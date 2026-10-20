import AppKit
import SwiftUI
import Carbon
import UniformTypeIdentifiers
import ServiceManagement

struct Display: Decodable, Identifiable { let id: String; let name: String; let serial: String }
struct Outcome: Decodable { let serial: String; let ok: Bool; let input: Int?; let videoSent: Bool?; let usbSent: Bool?; let error: String? }
struct Reply: Decodable {
    let ok: Bool
    let displays: [Display]?
    let input: Int?
    let rawInput: Int?
    let usbValue: Int?
    let usbInventory: Int?
    let results: [Outcome]?
    let error: String?
}
func runHelper(_ arguments: [String]) async throws -> Reply {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), pipe = Pipe()
            guard let url = Bundle.main.url(forResource: "input-ddc", withExtension: nil) else {
                continuation.resume(throwing: ConfigError(message: "缺少 input-ddc，请重新构建。")); return
            }
            process.executableURL = url; process.arguments = arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timeout)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); timeout.cancel()
                guard process.terminationReason == .exit else { throw ConfigError(message: "DDC 请求超时；可能已部分执行，请检测后重试。") }
                let r = try JSONDecoder().decode(Reply.self, from: data)
                guard process.terminationStatus == 0, r.ok else { throw ConfigError(message: r.error ?? "DDC 请求失败。") }
                continuation.resume(returning: r)
            } catch { continuation.resume(throwing: error) }
        }
    }
}

@MainActor final class Hotkeys {
    var refs: [EventHotKeyRef] = []
    var handler: EventHandlerRef?
    var action: ((Int) -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            let instance = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            let number = Int(key.id)
            Task { @MainActor in instance.action?(number) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ config: Configuration) -> String {
        refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll()
        guard config.shortcutsEnabled else { return "全局快捷键已关闭" }
        let codes: [Int: UInt32] = [1:18,2:19,3:20,4:21,5:23,6:22,7:26,8:28,9:25]
        var failed: [String] = []
        for g in config.groups where g.shortcut != 0 {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(codes[g.shortcut]!, UInt32(controlKey | optionKey | cmdKey), EventHotKeyID(signature: 0x44535747, id: UInt32(g.shortcut)), GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { refs.append(ref) } else { failed.append(g.name) }
        }
        return failed.isEmpty ? "快捷键：⌃⌥⌘ + 组别数字" : "快捷键注册失败：\(failed.joined(separator: "、"))；请检查其他软件占用。"
    }
}

@MainActor final class SwitchModel: ObservableObject {
    @Published var config = Configuration.initial
    @Published var displays: [Display] = []
    @Published var status = "正在检测显示器…"
    @Published var readings: [String: Int] = [:]
    @Published var busy = false
    @Published var log = ""
    @Published var shortcutStatus = ""
    @Published var saveStatus = ""
    @Published var launchAtLogin = false
    @Published var loginStatus = ""
    @Published var loginNeedsApproval = false
    let configURL: URL
    let logURL: URL
    private let hotkeys = Hotkeys()
    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configURL = home.appendingPathComponent("Library/Application Support/DisplayInputSwitch/config.json")
        logURL = home.appendingPathComponent("Library/Logs/DisplayInputSwitch/switch.log")
        do {
            for u in [configURL,logURL] { try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true) }
            if FileManager.default.fileExists(atPath: configURL.path) {
                let loaded = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL))
                try loaded.validate(); config = loaded
            }
            if !FileManager.default.fileExists(atPath: logURL.path) { try Data().write(to: logURL) }
        } catch { saveStatus = "读取配置失败，已显示默认值；原文件保留：\(error.localizedDescription)" }
        hotkeys.action = { [weak self] key in
            guard let self, let group = self.config.groups.first(where: { $0.shortcut == key }) else { return }
            Task { await self.apply(group) }
        }
        shortcutStatus = hotkeys.register(config)
        refreshLoginStatus()
        record("启动显示器切换 2.2")
        Task { await refresh() }
    }
    func refreshLoginStatus() {
        let state = SMAppService.mainApp.status
        launchAtLogin = state == .enabled || state == .requiresApproval
        loginNeedsApproval = state == .requiresApproval
        switch state {
        case .enabled: loginStatus = "已开启，登录后自动在菜单栏运行。"
        case .requiresApproval: loginStatus = "等待系统允许，请在系统设置的登录项中启用。"
        case .notRegistered: loginStatus = "已关闭。"
        case .notFound: loginStatus = "尚未注册开机启动。"
        @unknown default: loginStatus = "无法读取系统登录项状态。"
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLoginStatus()
            record("开机启动：\(loginStatus)")
        } catch {
            refreshLoginStatus()
            loginStatus = "更改失败：\(error.localizedDescription)"
            record("开机启动：\(loginStatus)")
        }
    }
    func record(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        log += line
        if log.count > 60000 { log = String(log.suffix(40000)) }
        do {
            let f = try FileHandle(forWritingTo: logURL); defer { try? f.close() }
            try f.seekToEnd(); try f.write(contentsOf: Data(line.utf8))
        } catch { saveStatus = "日志写入失败：\(error.localizedDescription)" }
    }
    func save() {
        do {
            try config.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(config).write(to: configURL, options: .atomic)
            shortcutStatus = hotkeys.register(config); saveStatus = "配置已保存"; record(saveStatus)
        } catch { saveStatus = error.localizedDescription }
    }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        status = "正在检测…"
        do {
            displays = try await runHelper(["list"]).displays ?? []
            readings.removeAll()
            for m in config.monitors where displays.contains(where: { $0.serial == m.serial }) {
                if let r = try? await runHelper(["get",m.serial]), let value = r.input { readings[m.serial] = value }
            }
            status = config.monitors.map { m in
                "\(m.name)：\(readings[m.serial].map(sourceName) ?? (displays.contains(where: { $0.serial == m.serial }) ? "读取失败" : "当前不可见"))"
            }.joined(separator: "；")
            record(status)
        } catch { status = error.localizedDescription; record(status) }
    }
    func execute(_ operations: [Operation], title: String, warning: String = "") async throws {
        let json = String(data: try JSONEncoder().encode(operations), encoding: .utf8)!
        let reply = try await runHelper(["batch",json])
        guard let results = reply.results, results.count == operations.count else { throw ConfigError(message: "切换结果不完整；请重新检测。") }
        var lines = [title]
        for r in results {
            let name = config.monitors.first(where: { $0.serial == r.serial })?.name ?? r.serial
            if let input = r.input { readings[r.serial] = input } else { readings.removeValue(forKey: r.serial) }
            if let error = r.error { lines.append("\(name)：\(error)"); continue }
            if let target = operations.first(where: { $0.serial == r.serial })?.input {
                lines.append("\(name)：" + (r.input == target ? "DDC 确认 \(sourceName(target))" : r.input.map { "返回 \(sourceName($0))，目标 \(sourceName(target))" } ?? "已发送 \(sourceName(target))，回读不可用"))
            }
            if r.usbSent == true { lines.append("USB 关联请求已发送，外设归属尚需实际确认") }
        }
        if !warning.isEmpty { lines.append(warning) }
        status = lines.joined(separator: "\n"); record(status)
    }
    func apply(_ group: SwitchGroup) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        status = "正在切到 \(group.name)…"
        do {
            try config.validate()
            var ops = group.displays.map { Operation(serial: $0.serial, input: $0.input) }
            var warning = ""
            if group.usb != "keep" {
                let input: Int
                if let assigned = group.displays.first(where: { $0.serial == config.usbSerial }) { input = assigned.input }
                else {
                    guard let current = try await runHelper(["get",config.usbSerial]).input else { throw ConfigError(message: "无法读取 USB 显示器输入源。") }
                    input = current
                }
                do {
                    let usb = try usbOperation(config: config, input: input, owner: group.usb)
                    if let i = ops.firstIndex(where: { $0.serial == config.usbSerial }) {
                        ops[i].usbMask = usb.usbMask; ops[i].usbBits = usb.usbBits; ops[i].usbInput = usb.usbInput
                    } else { ops.append(usb) }
                } catch { warning = "USB 未执行：\(error.localizedDescription) 目标：\(usbName(group.usb))" }
            }
            try await execute(ops, title: group.name, warning: warning)
        } catch { status = error.localizedDescription; record(status) }
    }
    func switchUSB(_ owner: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        status = "正在切换 USB…"
        do {
            try config.validate()
            guard let input = try await runHelper(["get",config.usbSerial]).input else { throw ConfigError(message: "无法读取当前输入源。") }
            let op = try usbOperation(config: config, input: input, owner: owner)
            try await execute([op], title: "USB → \(usbName(owner))")
        } catch { status = "USB 未执行：\(error.localizedDescription)"; record(status) }
    }
    func captureUSB(_ owner: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let r = try await runHelper(["usb-read",config.usbSerial])
            guard let input = r.input, let value = r.usbValue, value >= 0, value < 0xff00 else {
                throw ConfigError(message: "此固件未返回可用的 USB 关联映射（E7=\(r.usbValue.map(String.init) ?? "无响应")）。暂不能启用独立 USB 控制；没有写入显示器。")
            }
            if !config.usbProfiles.contains(where: { $0.input == input }) { config.usbProfiles.append(.init(input: input)) }
            let i = config.usbProfiles.firstIndex(where: { $0.input == input })!
            if owner == "mac" { config.usbProfiles[i].mac = value } else { config.usbProfiles[i].windows = value }
            status = "已读取 \(sourceName(input)) 下的 \(usbName(owner)) 关联值：\(value)。请保存配置。"
            record(status)
        } catch { status = error.localizedDescription; record(status) }
    }
    func importConfig() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let c = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)); try c.validate()
            config = c; save()
        } catch { saveStatus = "导入失败：\(error.localizedDescription)" }
    }
    func exportConfig() {
        let p = NSSavePanel(); p.allowedContentTypes = [.json]; p.nameFieldStringValue = "display-groups.json"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try config.validate(); let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted,.sortedKeys]
            try e.encode(config).write(to: url, options: .atomic); saveStatus = "配置已导出"
        } catch { saveStatus = error.localizedDescription }
    }
}

struct USBButtons: View {
    @ObservedObject var model: SwitchModel
    var body: some View {
        HStack {
            Button("USB → Mac") { Task { await model.switchUSB("mac") } }
            Button("USB → Windows") { Task { await model.switchUSB("windows") } }
        }.disabled(model.busy)
    }
}
struct SwitchView: View {
    @ObservedObject var model: SwitchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("显示器切换").font(.title2.bold()); Spacer(); Button("检测 / 读取") { Task { await model.refresh() } }.disabled(model.busy) }
            TabView {
                Form {
                    Section {
                        Toggle("开机启动", isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }))
                        Text("登录后自动在菜单栏运行。更改立即生效，仅用于本机。")
                            .foregroundStyle(.secondary)
                        Text(model.loginStatus).textSelection(.enabled)
                        if model.loginNeedsApproval {
                            Button("打开系统登录项设置…") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                }.formStyle(.grouped).tabItem { Label("通用", systemImage: "gearshape") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach($model.config.groups) { $group in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        TextField("组名", text: $group.name)
                                        Picker("快捷键数字", selection: $group.shortcut) {
                                            Text("关闭").tag(0)
                                            ForEach(1...9, id: \.self) { Text(String($0)).tag($0) }
                                        }.frame(width: 180)
                                        Button("切换") { Task { await model.apply(group) } }
                                        Button("删除") { model.config.groups.removeAll { $0.id == group.id } }.disabled(model.config.groups.count == 1)
                                    }
                                    ForEach($group.displays, id: \.serial) { $a in
                                        Picker(model.config.monitors.first(where: { $0.serial == a.serial })?.name ?? a.serial, selection: $a.input) {
                                            ForEach([27,15,17], id: \.self) { Text(sourceName($0)).tag($0) }
                                        }
                                    }
                                    Picker("QX USB 归属", selection: $group.usb) {
                                        ForEach(["keep","mac","windows"], id: \.self) { Text(usbName($0)).tag($0) }
                                    }
                                }.padding(6)
                            }
                        }
                        Button("添加组别") {
                            model.config.groups.append(.init(id: UUID().uuidString, name: "新组别", displays: model.config.monitors.map { .init(serial: $0.serial, input: 27) }, usb: "keep", shortcut: 0))
                        }.disabled(model.config.groups.count >= 9)
                        Toggle("启用全局快捷键（Control + Option + Command + 数字）", isOn: $model.config.shortcutsEnabled)
                        Text(model.shortcutStatus).font(.callout).foregroundStyle(.secondary)
                        HStack { Button("保存配置") { model.save() }; Button("导入 JSON…") { model.importConfig() }; Button("导出 JSON…") { model.exportConfig() } }
                        Text(model.saveStatus).textSelection(.enabled)
                    }.padding()
                }.tabItem { Label("组别", systemImage: "square.stack.3d.up") }
                VStack(alignment: .leading, spacing: 12) {
                    Text("按显示器序列号识别，两端可共用同一份 JSON 配置。")
                    ForEach(model.config.monitors.indices, id: \.self) { i in
                        HStack {
                            TextField("名称", text: $model.config.monitors[i].name).frame(width: 80)
                            Text(model.config.monitors[i].serial).textSelection(.enabled)
                            Spacer()
                            Text(model.readings[model.config.monitors[i].serial].map(sourceName) ?? "不可见 / 未读取")
                        }
                    }
                    Divider()
                    Text("已检测到") .font(.headline)
                    ForEach(model.displays) { d in Text("\(d.name) · \(d.serial.isEmpty ? "无序列号" : d.serial)").textSelection(.enabled) }
                    Text("更换显示器或自定义序列号：导出 JSON，修改 monitors、groups 中的 serial 以及 usbSerial，再导入。")
                        .foregroundStyle(.secondary)
                    Spacer()
                }.padding().tabItem { Label("显示器", systemImage: "display.2") }
                VStack(alignment: .leading, spacing: 14) {
                    Text("QX USB 外设").font(.headline)
                    Text("Mac：90W 全功能 USB-C 上行。Windows：独立 USB-C 数据上行（主机端 USB-A）。")
                    USBButtons(model: model)
                    Divider()
                    Text("USB 控制校准").font(.headline)
                    Text("独立 USB 控制需要显示器提供可读写的 USB 关联映射。对同一视频输入，分别用显示器菜单将 USB 分配给 Mac 和 Windows，再读取对应状态。两个值不同才可启用；工具不发送猜测的 USB 指令。")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("读取 USB 属于 Mac 的状态") { Task { await model.captureUSB("mac") } }
                        Button("读取 USB 属于 Windows 的状态") { Task { await model.captureUSB("windows") } }
                    }
                    ForEach(model.config.usbProfiles, id: \.input) { p in
                        Text("\(sourceName(p.input))：\(p.mask == nil ? "未完成校准" : "已记录关联差异，待实测")")
                    }
                    Button("保存配置") { model.save() }
                    Text("USB 不支持或未校准时，组别仍切换视频，并明确报告 USB 未执行。USB 归属不能通过输入源回读确认。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }.padding().disabled(model.busy).tabItem { Label("USB", systemImage: "cable.connector") }
                VStack(alignment: .leading) {
                    Text("DDC 回读确认输入源；画面和 USB 外设是否正常需实际观察。")
                    ScrollView { Text(model.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("打开日志文件") { NSWorkspace.shared.activateFileViewerSelecting([model.logURL]) }
                }.padding().tabItem { Label("日志", systemImage: "doc.text") }
            }.disabled(model.busy)
            HStack(alignment: .top) { if model.busy { ProgressView().controlSize(.small) }; Text(model.status).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .padding(10).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 6))
        }.padding(20).frame(width: 760, height: 650)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshLoginStatus()
            }
    }
}
struct MenuPanel: View {
    @ObservedObject var model: SwitchModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("显示器切换").font(.headline)
            ForEach(model.config.groups) { g in
                Button { Task { await model.apply(g) } } label: {
                    HStack { Text(g.name); Spacer(); if model.config.shortcutsEnabled && g.shortcut != 0 { Text("⌃⌥⌘\(g.shortcut)").foregroundStyle(.secondary) } }.frame(maxWidth: .infinity)
                }.disabled(model.busy)
            }
            Divider(); USBButtons(model: model)
            HStack(alignment: .top) { if model.busy { ProgressView().controlSize(.small) }; Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true) }
            Divider()
            HStack {
                Button("设置与日志…") { NSApp.activate(ignoringOtherApps: true); openSettings() }
                Button("检测") { Task { await model.refresh() } }.disabled(model.busy)
                Spacer(); Button("退出") { NSApp.terminate(nil) }
            }
        }.padding(18).frame(width: 380)
    }
}
@main struct DisplayInputSwitchApp: App {
    @StateObject private var model = SwitchModel()
    var body: some Scene {
        MenuBarExtra("显示器切换", systemImage: "display") { MenuPanel(model: model) }.menuBarExtraStyle(.window)
        Settings { SwitchView(model: model) }
    }
}
