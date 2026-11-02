import AppKit
import SwiftUI

struct DisplayColorSettings: View {
    @ObservedObject var model: SwitchModel
    @State private var linkedMode = DellProfileMode.hdrV4
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("颜色与 HDR", systemImage: "paintpalette").font(.headline)
                Spacer()
                Button("重新检查") { model.refreshColorProfiles() }
                Button("系统显示器设置…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            GroupBox("同步颜色描述文件") {
                HStack {
                    Picker("描述文件", selection: $linkedMode) {
                        ForEach(DellProfileMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("同步到两台显示器") {
                        Task { await model.applyColorProfile(linkedMode, to: DellMonitorModel.allCases) }
                    }.disabled(model.colorDisplays.count != 2 || !model.colorDisplays.allSatisfy { $0.availableModes.contains(linkedMode) })
                }.padding(6)
            }
            ForEach(model.colorDisplays) { display in
                DisplayColorRow(model: model, display: display)
            }
            Text(model.colorProfileStatus).font(.callout).textSelection(.enabled)
            Text("描述文件与 HDR 开关分别生效。同步会按 QX / QE 型号选择对应文件。更改前会恢复目标屏幕的软件调暗，原文件路径记录在日志中；操作期间画面可能短暂闪黑。")
                .font(.caption).foregroundStyle(.secondary)
            Text("QX 曾通过切换 HDR V4 避开 DP → USB-C 黑屏；Native V2 仍可选。如再次出现该现象，可切回 HDR V4。文件来自已安装的 Dell DDPM。")
                .font(.caption).foregroundStyle(.secondary)
        }.disabled(model.colorProfileBusy)
    }
}

private struct DisplayColorRow: View {
    @ObservedObject var model: SwitchModel
    let display: ColorDisplayState
    @State private var selected = DellProfileMode.hdrV4
    var body: some View {
        GroupBox(display.model.rawValue) {
            VStack(alignment: .leading, spacing: 10) {
                Text("当前：" + display.profileLabel).font(.callout).textSelection(.enabled)
                    .help(display.profileURL?.path ?? "未读取")
                HStack {
                    Picker("颜色描述文件", selection: $selected) {
                        ForEach(DellProfileMode.allCases) { mode in
                            Text(mode.rawValue + (display.availableModes.contains(mode) ? "" : "（缺少文件）")).tag(mode)
                        }
                    }
                    Button("应用到此屏") { Task { await model.applyColorProfile(selected, to: [display.model]) } }
                        .disabled(!display.availableModes.contains(selected))
                }
                HStack {
                    Toggle("高动态范围（HDR）", isOn: Binding(
                        get: { display.hdr.enabled ?? false },
                        set: { enabled in Task { await model.setHDR(enabled, for: display) } }))
                        .toggleStyle(.switch).disabled(!model.canSetHDR(for: display))
                    Spacer()
                    Text(display.hdr.supported == false && model.dellHDRServiceTag(for: display) != nil ? "HDR 已关闭 · 可直接开启" : display.hdr.label)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.dellHDRServiceTag(for: display) != nil {
                    Text("通过已安装的 Dell DDPM 控制此屏，无需先到显示器菜单开启 Smart HDR。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !display.hdr.canSet {
                    Text(display.hdr.supported == false ? "在显示器菜单启用 Smart HDR 后，点击重新检查；也可到 macOS 显示器设置确认。" : "当前系统未提供可用的 HDR 控制接口，请到 macOS 显示器设置调整。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }.onAppear { selected = display.mode ?? .hdrV4 }
            .onChange(of: display.profileURL) { _, _ in selected = display.mode ?? .hdrV4 }
    }
}
