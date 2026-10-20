import AppKit
import SwiftUI
import Carbon
import UniformTypeIdentifiers
import ServiceManagement

struct Display: Decodable, Identifiable { let id: String; let name: String; let serial: String; let hdr: Bool? }
struct Outcome: Decodable { let serial: String; let ok: Bool; let input: Int?; let videoSent: Bool?; let brightness: Int?; let maxBrightness: Int?; let error: String? }
struct Reply: Decodable {
    let ok: Bool
    let displays: [Display]?
    let input: Int?
    let rawInput: Int?
    let brightness: Int?
    let maxBrightness: Int?
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

@MainActor final class SwitchModel: ObservableObject {
    @Published var config = Configuration.initial
    @Published var displays: [Display] = []
    @Published var status = "正在检测显示器…"
    @Published var readings: [String: Int] = [:]
    @Published var levels: [String: Int] = [:]
    @Published var brightnessMode = UserDefaults.standard.string(forKey: "brightnessMode") ?? "auto"
    var softwareDimming: Bool { brightnessMode != "hardware" }
    private var registeredConfig = Configuration.initial
    private let dimming = SoftwareDimming()
    private let brightnessHUD = BrightnessHUD()
    private let brightnessKeys = BrightnessKeys()
    @Published var brightnessKeysEnabled = UserDefaults.standard.bool(forKey: "brightnessKeysEnabled")
    @Published var brightnessKeysStatus = ""
    @Published var adjustingBrightness = false
    var blocksInteraction: Bool { busy && !adjustingBrightness }
    private var pendingBrightness: (serials: [String], percent: Int?, delta: Int?)?
    private var brightnessGeneration = 0
    private var observers: [NSObjectProtocol] = []
    @Published var levelErrors: [String: String] = [:]
    @Published var busy = false
    @Published var log = ""
    @Published var shortcutStatus = ""
    @Published var saveStatus = ""
    @Published var recordingAction: String?
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
        hotkeys.action = { [weak self] action in
            Task { await self?.performShortcut(action) }
        }
        brightnessKeys.acceptsEvent = { [weak self] in
            guard let self else { return false }
            let targets = self.brightnessKeyTargets()
            return self.recordingAction == nil && !self.blocksInteraction && !targets.isEmpty && targets.allSatisfy { self.levels[$0] != nil }
        }
        brightnessKeys.action = { [weak self] direction in
            guard let self else { return }
            let targets = self.brightnessKeyTargets()
            Task { await self.setBrightness(targets, delta: direction * self.config.brightnessStep) }
        }
        refreshBrightnessKeys()
        registeredConfig = config
        shortcutStatus = hotkeys.register(config)
        refreshLoginStatus()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.dimming.reconcile()
                self?.brightnessHUD.hide()
                await self?.refreshBrightness()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dimming.reset(); self?.brightnessHUD.hide(); self?.brightnessKeys.stop() }
        })
        record("启动显示器切换 2.6")
        Task { await refresh() }
    }
    func brightnessKeyTargets() -> [String] {
        if config.menuBrightnessLinked { return config.monitors.map(\.serial) }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let display = displays.first(where: { $0.id == CFUUIDCreateString(nil, uuid) as String }),
              config.monitors.contains(where: { $0.serial == display.serial }) else { return [] }
        return [display.serial]
    }
    func refreshBrightnessKeys() {
        guard brightnessKeysEnabled else { brightnessKeys.stop(); brightnessKeysStatus = "已关闭，保留键盘亮度键的系统行为。"; return }
        brightnessKeysStatus = brightnessKeys.start() ? "已接入顶部亮度键；联动时调全部屏幕，分开时调鼠标所在屏幕。" : brightnessKeys.trusted ? "系统未能接入亮度键；请继续使用自定义全局快捷键。" : "需要在系统设置 → 隐私与安全性 → 辅助功能中允许“显示器切换”。授权后返回本工具。"
    }
    func setBrightnessKeysEnabled(_ enabled: Bool) {
        brightnessKeysEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "brightnessKeysEnabled")
        if enabled { brightnessKeys.requestPermission() }
        refreshBrightnessKeys()
    }
    func openBrightnessKeyPermissions() {
        brightnessKeys.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    private func showBrightnessHUD(_ serials: [String]) {
        brightnessHUD.show(serials.compactMap { serial in
            guard let percent = levels[serial], levelErrors[serial] == nil,
                  let display = displays.first(where: { $0.serial == serial }) else { return nil }
            return (id: display.id, name: config.monitors.first { $0.serial == serial }?.name ?? display.name, percent: percent)
        })
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
    func beginRecording(_ action: String) { recordingAction = action; hotkeys.unregister() }
    func finishRecording(_ binding: KeyBinding?) {
        if let binding {
            config.hotkeys.removeAll { $0.action == binding.action }
            config.hotkeys.append(binding)
        }
        recordingAction = nil
        shortcutStatus = hotkeys.register(registeredConfig)
    }
    func binding(for action: String) -> KeyBinding {
        config.effectiveHotkeys(mac: true).first { $0.action == action } ?? KeyBinding(action: action, key: "", modifiers: 0)
    }
    func clearBinding(_ action: String) { finishRecording(KeyBinding(action: action, key: "", modifiers: 0)) }
    func performShortcut(_ action: String) async {
        guard recordingAction == nil else { return }
        if action == "brightness:restore" { resetSoftwareDimming(); return }
        if let group = config.groups.first(where: { "group:" + $0.id == action }) { await apply(group); return }
        guard let adjustment = config.brightnessActions.first(where: { $0.id == action }) else { return }
        await setBrightness(adjustment.serials, delta: adjustment.direction * config.brightnessStep)
    }
    func save() {
        do {
            try config.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(config).write(to: configURL, options: .atomic)
            registeredConfig = config; shortcutStatus = hotkeys.register(config); saveStatus = "配置已保存"; record(saveStatus)
        } catch { saveStatus = error.localizedDescription }
    }
    func usesSoftware(_ serial: String) -> Bool {
        brightnessUsesSoftware(mode: brightnessMode, hdr: displays.first { $0.serial == serial }?.hdr)
    }
    func minimumBrightness(_ serials: [String]) -> Int { serials.contains(where: usesSoftware) ? 10 : 0 }
    func routeName(_ serial: String) -> String {
        guard brightnessMode == "auto" else { return usesSoftware(serial) ? "软件调暗" : "硬件调光" }
        let hdr = displays.first { $0.serial == serial }?.hdr
        return hdr == true ? "HDR 已开启 · 软件调暗" : hdr == false ? "HDR 已关闭 · 硬件调光" : "HDR 未知 · 软件调暗"
    }
    func loadBrightness() async {
        var nextLevels: [String: Int] = [:], nextErrors: [String: String] = [:]
        dimming.reconcile()
        for m in config.monitors {
            let matches = displays.filter { $0.serial == m.serial }
            guard matches.count == 1, dimming.available(matches[0].id) else { nextErrors[m.serial] = "显示器不可见或匹配不唯一"; continue }
            if usesSoftware(m.serial) { nextLevels[m.serial] = dimming.levels[matches[0].id] ?? 100 }
            else {
                try? dimming.apply([matches[0].id], percent: 100)
                do {
                    let r = try await runHelper(["brightness-get",m.serial])
                    guard let current = r.brightness, let maximum = r.maxBrightness else { throw ConfigError(message: "亮度响应不完整。") }
                    nextLevels[m.serial] = try brightnessPercent(current: current, maximum: maximum)
                } catch { nextErrors[m.serial] = error.localizedDescription }
            }
        }
        levels = nextLevels; levelErrors = nextErrors
    }
    func refreshBrightness() async {
        guard !busy else { return }; adjustingBrightness = true; busy = true
        defer { finishBrightness() }
        do { displays = try await runHelper(["list"]).displays ?? []; await loadBrightness() }
        catch { levels.removeAll(); status = error.localizedDescription; record(status) }
    }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        status = "正在检测…"; readings.removeAll()
        do {
            displays = try await runHelper(["list"]).displays ?? []
            for m in config.monitors where displays.contains(where: { $0.serial == m.serial }) {
                if let r = try? await runHelper(["get",m.serial]), let value = r.input { readings[m.serial] = value }
            }
            await loadBrightness()
            status = config.monitors.map { m in "\(m.name)：\(readings[m.serial].map(sourceName) ?? "不可见 / 读取失败")" }.joined(separator: "；")
            record(status)
        } catch { status = error.localizedDescription; record(status) }
    }
    func selectBrightnessMode(_ mode: String) {
        guard !busy, ["auto","software","hardware"].contains(mode), brightnessMode != mode else { return }
        brightnessGeneration += 1; pendingBrightness = nil; brightnessHUD.hide()
        dimming.reset(); brightnessMode = mode
        UserDefaults.standard.set(mode, forKey: "brightnessMode")
        levels.removeAll(); levelErrors.removeAll()
        Task { await refreshBrightness() }
    }
    func resetSoftwareDimming() {
        brightnessGeneration += 1; pendingBrightness = nil
        dimming.reset()
        for m in config.monitors where usesSoftware(m.serial) && levels[m.serial] != nil { levels[m.serial] = 100 }
        status = "已恢复原画面（取消本工具的软件调暗）"; record(status)
        showBrightnessHUD(config.monitors.map(\.serial).filter(usesSoftware))
    }
    func execute(_ operations: [Operation], title: String) async throws {
        let json = String(data: try JSONEncoder().encode(operations), encoding: .utf8)!
        let reply = try await runHelper(["batch",json])
        guard let results = reply.results, results.count == operations.count else { throw ConfigError(message: "切换结果不完整；请重新检测。") }
        var lines = [title]
        for r in results {
            let name = config.monitors.first(where: { $0.serial == r.serial })?.name ?? r.serial
            if operations.first(where: { $0.serial == r.serial })?.input != nil {
                if let input = r.input { readings[r.serial] = input } else { readings.removeValue(forKey: r.serial) }
            }
            if operations.first(where: { $0.serial == r.serial })?.brightness != nil {
                if let current = r.brightness, let maximum = r.maxBrightness,
                   let percent = try? brightnessPercent(current: current, maximum: maximum) {
                    levels[r.serial] = percent
                    if r.error == nil { lines.append("\(name)：DDC 确认亮度 \(percent)%") }
                } else { levels.removeValue(forKey: r.serial) }
                levelErrors[r.serial] = r.error
            }
            if let error = r.error { lines.append("\(name)：\(error)"); continue }
            if let target = operations.first(where: { $0.serial == r.serial })?.input {
                lines.append("\(name)：" + (r.input == target ? "DDC 确认 \(sourceName(target))" : r.input.map { "返回 \(sourceName($0))，目标 \(sourceName(target))" } ?? "已发送 \(sourceName(target))，回读不可用"))
            }
        }
        status = lines.joined(separator: "\n"); record(status)
    }
    func apply(_ group: SwitchGroup) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        status = "正在切到 \(group.name)…"
        do {
            try config.validate()
            let ops = group.displays.map { Operation(serial: $0.serial, input: $0.input) }
            try await execute(ops, title: group.name)
        } catch { status = error.localizedDescription; record(status) }
    }
    private func finishBrightness() {
        busy = false; adjustingBrightness = false
        if let pending = pendingBrightness {
            pendingBrightness = nil
            let generation = brightnessGeneration
            Task {
                guard generation == brightnessGeneration else { return }
                await setBrightness(pending.serials, percent: pending.percent, delta: pending.delta)
            }
        }
    }
    func setBrightness(_ serials: [String], percent requested: Int? = nil, delta: Int? = nil) async {
        guard !busy else {
            if adjustingBrightness {
                let accumulated = delta.flatMap { change in pendingBrightness.flatMap { $0.serials == serials ? $0.delta.map { $0 + change } : nil } }
                pendingBrightness = (serials, requested, accumulated ?? delta)
            }
            return
        }
        adjustingBrightness = true; busy = true; defer { finishBrightness() }
        let generation = brightnessGeneration
        do {
            guard (requested != nil) != (delta != nil), !serials.isEmpty,
                  Set(serials).count == serials.count,
                  serials.allSatisfy({ s in config.monitors.contains { $0.serial == s } }) else {
                throw ConfigError(message: "亮度或目标显示器无效。")
            }
            displays = try await runHelper(["list"]).displays ?? []
            let percent: Int
            if let delta {
                await loadBrightness()
                guard serials.allSatisfy({ levels[$0] != nil }), let first = serials.first, let current = levels[first] else { throw ConfigError(message: "目标显示器亮度不可用；快捷键未执行。") }
                percent = adjustedBrightness(current: current, delta: delta, software: minimumBrightness(serials) == 10)
            } else { percent = requested! }
            guard (0...100).contains(percent) else { throw ConfigError(message: "亮度须为 0–100%。") }
            guard generation == brightnessGeneration else { return }
            let soft = serials.filter(usesSoftware), hard = serials.filter { !usesSoftware($0) }
            let ids = try serials.map { serial -> String in
                let matches = displays.filter { $0.serial == serial }
                guard matches.count == 1, dimming.available(matches[0].id) else { throw ConfigError(message: "显示器不可见或匹配不唯一；本组未调节。") }
                return matches[0].id
            }
            if !soft.isEmpty { _ = try softwareOpacity(percent: percent) }
            // Reset stale shades when HDR was turned off, before applying hardware brightness.
            for (serial,id) in zip(serials,ids) where hard.contains(serial) { try dimming.apply([id], percent: 100) }
            if !hard.isEmpty { try await execute(hard.map { Operation(serial: $0, brightness: percent) }, title: "硬件亮度 \(percent)%") }
            guard generation == brightnessGeneration else { return }
            if !soft.isEmpty {
                let softIDs = zip(serials,ids).filter { soft.contains($0.0) }.map { $0.1 }
                try dimming.apply(softIDs, percent: percent)
                for serial in soft { levels[serial] = percent; levelErrors.removeValue(forKey: serial) }
                status = (hard.isEmpty ? "" : status + "\n") + "软件亮度 \(percent)%（不更改 HDR）"; record(status)
            }
            showBrightnessHUD(serials)
        } catch { status = error.localizedDescription; record(status) }
    }
    func importConfig() {
        guard !busy else { return }
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let c = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)); try c.validate()
            brightnessGeneration += 1; pendingBrightness = nil; brightnessHUD.hide()
            dimming.reset(); config = c; save(); Task { await refresh() }
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

struct BrightnessControl: View {
    @ObservedObject var model: SwitchModel
    let serials: [String]
    let name: String
    @State private var value = 100.0
    @State private var editing = false
    private var available: Bool { !serials.isEmpty && serials.allSatisfy { model.levels[$0] != nil } }
    private func sync() { value = Double(serials.first.flatMap { model.levels[$0] } ?? (model.softwareDimming ? 100 : 0)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    if serials.count == 1, let serial = serials.first { Text(model.routeName(serial)).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text(available ? "\(Int(value))%" : "不可用").monospacedDigit().foregroundStyle(.secondary)
                Button("应用") { Task { await model.setBrightness(serials, percent: Int(value)) } }
                    .disabled(model.blocksInteraction || !available)
            }
            Slider(value: $value, in: Double(model.minimumBrightness(serials))...100, step: 1, onEditingChanged: { active in
                editing = active
                if !active { Task { await model.setBrightness(serials, percent: Int(value)) } }
            }).accessibilityLabel("\(name)亮度")
                .disabled(model.blocksInteraction || !available)
            if serials.count == 1, let serial = serials.first, let error = model.levelErrors[serial] {
                Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { sync() }
        .onChange(of: model.brightnessMode) { _, _ in sync() }
        .onChange(of: model.levels) { _, _ in if !editing { sync() } }
    }
}
struct BrightnessPage: View {
    @ObservedObject var model: SwitchModel
    let software: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.brightnessMode == "auto" ? "自动选择每台屏幕的调光方式" : software ? "保留 HDR，调暗当前画面" : "显示器硬件亮度").font(.headline)
                Text(model.brightnessMode == "auto" ? "每屏分别检测 HDR：开启时软件调暗，关闭时硬件调光；未知时使用软件调暗。快捷键跟随每屏方式。软件 100% 表示原画面，硬件 100% 表示最大背光。" : software ? "100% 为原画面，最低 10%。通过透明遮罩调暗，不更改 HDR、背光或其他软件的伽马设置。启动时不自动调暗，退出后恢复。" : "适用于关闭 HDR 的显示器。HDR 下即使 DDC 数值变化，画面也可能不变。拖动松手后应用，也可点击“应用”。")
                    .foregroundStyle(.secondary)
                if software {
                    Button("恢复所有屏幕到 100%") { model.resetSoftwareDimming() }
                }
                ForEach(model.config.monitors) { m in
                    BrightnessControl(model: model, serials: [m.serial], name: m.name)
                }
                if model.config.monitors.count > 1 {
                    Divider()
                    BrightnessControl(model: model, serials: model.config.monitors.map(\.serial), name: "所有显示器联动")
                    Text("联动滑块显示第一台屏幕的数值，应用时将所有屏幕设置为相同比例。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text(software ? "软件调暗基于 MonitorControl 的开源遮罩方案。同类工具的调暗效果会叠加。独占全屏、受保护视频或系统安全界面可能不受遮罩影响。" : "启动和检测只读取，不自动修改亮度。切回软件调暗不会还原手动修改的显示器背光。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
    }
}
struct SwitchView: View {
    @ObservedObject var model: SwitchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("显示器切换").font(.title2.bold()); Spacer(); Button("检测 / 读取") { Task { await model.refresh() } }.disabled(model.blocksInteraction) }
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
                                        Button("删除") { model.config.groups.removeAll { $0.id == group.id }; model.config.hotkeys.removeAll { $0.action == "group:" + group.id } }.disabled(model.config.groups.count == 1)
                                    }
                                    ForEach($group.displays, id: \.serial) { $a in
                                        Picker(model.config.monitors.first(where: { $0.serial == a.serial })?.name ?? a.serial, selection: $a.input) {
                                            ForEach([27,15,17], id: \.self) { Text(sourceName($0)).tag($0) }
                                        }
                                    }
                                }.padding(6)
                            }
                        }
                        Button("添加组别") {
                            model.config.groups.append(.init(id: UUID().uuidString, name: "新组别", displays: model.config.monitors.map { .init(serial: $0.serial, input: 27) }, shortcut: 0))
                        }.disabled(model.config.groups.count >= 9)
                        Toggle("启用全局快捷键", isOn: $model.config.shortcutsEnabled)
                        Text(model.shortcutStatus).font(.callout).foregroundStyle(.secondary)
                        HStack { Button("保存配置") { model.save() }; Button("导入 JSON…") { model.importConfig() }; Button("导出 JSON…") { model.exportConfig() } }
                        Text(model.saveStatus).textSelection(.enabled)
                    }.padding()
                }.tabItem { Label("组别", systemImage: "square.stack.3d.up") }
                VStack(spacing: 0) {
                    Picker("调光方式", selection: Binding(get: { model.brightnessMode }, set: { model.selectBrightnessMode($0) })) {
                        Text("自动 · 检测 HDR").tag("auto")
                        Text("软件调暗 · HDR").tag("software")
                        Text("硬件调光 · SDR").tag("hardware")
                    }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.top, 16)
                    BrightnessPage(model: model, software: model.softwareDimming)
                }.tabItem { Label("亮度", systemImage: "sun.max") }
                ShortcutSettings(model: model).tabItem { Label("状态栏", systemImage: "slider.horizontal.3") }
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
                    Text("更换显示器或自定义序列号：导出 JSON，修改 monitors、groups 中的 serial，再导入。")
                        .foregroundStyle(.secondary)
                    Spacer()
                }.padding().tabItem { Label("显示器", systemImage: "display.2") }
                VStack(alignment: .leading) {
                    Text("DDC 回读确认输入源；画面是否正常需实际观察。")
                    ScrollView { Text(model.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button("打开日志文件") { NSWorkspace.shared.activateFileViewerSelecting([model.logURL]) }
                }.padding().tabItem { Label("日志", systemImage: "doc.text") }
            }.disabled(model.blocksInteraction)
            HStack(alignment: .top) {
                ProgressView().controlSize(.small).opacity(model.blocksInteraction ? 1 : 0).frame(width: 16)
                Text(model.status).textSelection(.enabled).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 52, alignment: .topLeading)
                .padding(10).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 6))
        }.padding(20).frame(width: 760, height: 650)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshLoginStatus()
                model.refreshBrightnessKeys()
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
                    HStack { Text(g.name); Spacer(); if model.config.shortcutsEnabled { Text(Hotkeys.label(model.binding(for: "group:" + g.id))).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity)
                }.disabled(model.blocksInteraction)
            }
            Divider()
            Text(model.brightnessMode == "auto" ? "自动亮度 · 按每屏 HDR 状态" : model.softwareDimming ? "软件亮度 · HDR" : "硬件亮度 · SDR").font(.caption).foregroundStyle(.secondary)
            if model.config.menuBrightnessLinked {
                BrightnessControl(model: model, serials: model.config.monitors.map(\.serial), name: "所有显示器联动")
            } else {
                ForEach(model.config.monitors) { m in
                    BrightnessControl(model: model, serials: [m.serial], name: m.name)
                }
            }
            if model.softwareDimming {
                Button("恢复原画面（100%）") { model.resetSoftwareDimming() }
            }
            Divider()
            HStack(alignment: .top) {
                ProgressView().controlSize(.small).opacity(model.blocksInteraction ? 1 : 0).frame(width: 16)
                Text(model.status).font(.callout).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 52, alignment: .topLeading)
            Divider()
            HStack {
                Button("设置与日志…") { NSApp.activate(ignoringOtherApps: true); openSettings() }
                Button("检测") { Task { await model.refresh() } }.disabled(model.blocksInteraction)
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
