import AppKit
import ColorSync
import Foundation

enum DellProfileMode: String, CaseIterable, Identifiable {
    case hdrV4 = "HDR V4"
    case nativeV2 = "Native V2"
    var id: String { rawValue }
    func filename(for model: DellMonitorModel) -> String {
        "Dell_\(model.rawValue)_\(self == .hdrV4 ? "HDR_v4_MHC2" : "Native_v2").icm"
    }
    static func detect(_ url: URL?) -> Self? {
        guard let name = url?.lastPathComponent.lowercased() else { return nil }
        if name.contains("hdr_v4") { return .hdrV4 }
        if name.contains("native_v2") { return .nativeV2 }
        return nil
    }
}

enum DellMonitorModel: String, CaseIterable, Identifiable {
    case qx = "U2723QX", qe = "U2723QE"
    var id: String { rawValue }
}

struct ColorDisplayState: Identifiable, Equatable {
    let model: DellMonitorModel
    let uuid: String
    let profileURL: URL?
    let availableModes: [DellProfileMode]
    let hdr: HDRState
    var id: DellMonitorModel { model }
    var mode: DellProfileMode? { DellProfileMode.detect(profileURL) }
    var profileLabel: String {
        guard let profileURL else { return "无法读取当前描述文件" }
        return "\(mode?.rawValue ?? "其他") · \(profileURL.lastPathComponent)"
    }
}

@MainActor enum ColorProfileManager {
    static func inspect() throws -> [ColorDisplayState] {
        try DellMonitorModel.allCases.compactMap { model in
            guard let screen = try screen(for: model) else { return nil }
            let id = try displayID(screen)
            return ColorDisplayState(model: model, uuid: try uuid(id), profileURL: currentProfileURL(id),
                                     availableModes: DellProfileMode.allCases.filter { targetURL(model: model, mode: $0) != nil },
                                     hdr: HDRController.inspect(id))
        }
    }

    static func targetURL(model: DellMonitorModel, mode: DellProfileMode, roots: [URL]? = nil) -> URL? {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let directories = roots ?? [
            home.appendingPathComponent("Applications/DDPM/Profiles/\(model.rawValue)"),
            URL(fileURLWithPath: "/Applications/DDPM/Profiles/\(model.rawValue)"),
            home.appendingPathComponent("Library/ColorSync/Profiles"),
            URL(fileURLWithPath: "/Library/ColorSync/Profiles")
        ]
        return directories.map { $0.appendingPathComponent(mode.filename(for: model)) }.first { fm.isReadableFile(atPath: $0.path) }
    }

    struct Change {
        let model: DellMonitorModel
        let uuid: String
        let before: URL?
        let target: URL
    }

    // Preflight every screen and file before the first write; a hardware disconnect can still cause partial completion.
    static func prepare(_ targets: [ColorDisplayState], mode: DellProfileMode, roots: [URL]? = nil) throws -> [Change] {
        guard !targets.isEmpty, Set(targets.map(\.id)).count == targets.count else {
            throw ConfigError(message: "颜色描述文件操作的目标为空或重复。")
        }
        return try targets.map { state in
            let id = try displayID(forUUID: state.uuid)
            guard let target = targetURL(model: state.model, mode: mode, roots: roots),
                  ColorSyncProfileCreateWithURL(target as CFURL, nil)?.takeRetainedValue() != nil else {
                throw ConfigError(message: "未找到有效的 \(state.model.rawValue) \(mode.rawValue) 文件；本次未修改。请安装 Dell DDPM 的颜色描述文件。")
            }
            return Change(model: state.model, uuid: state.uuid, before: currentProfileURL(id), target: target)
        }
    }

    static func apply(_ change: Change) async throws {
        _ = try displayID(forUUID: change.uuid)
        guard let deviceUUID = CFUUIDCreateFromString(nil, change.uuid as CFString) else {
            throw ConfigError(message: "显示器标识无效。")
        }
        let settings = [kColorSyncDeviceDefaultProfileID!.takeUnretainedValue() as String: change.target as CFURL] as CFDictionary
        guard ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass!.takeUnretainedValue(), deviceUUID, settings) else {
            throw ConfigError(message: "系统未接受颜色描述文件变更。")
        }
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(200))
            let id = try displayID(forUUID: change.uuid)
            if currentProfileURL(id)?.standardizedFileURL == change.target.standardizedFileURL { return }
        }
        throw ConfigError(message: "描述文件已提交，但回读未匹配；请重新检查。")
    }

    static func displayID(forUUID expected: String) throws -> CGDirectDisplayID {
        for screen in NSScreen.screens {
            let id = try displayID(screen)
            if (try? uuid(id)) == expected { return id }
        }
        throw ConfigError(message: "目标显示器已断开或标识改变，请重新检查。")
    }

    static func displayID(model: DellMonitorModel, serialNumber: UInt32) throws -> CGDirectDisplayID {
        guard serialNumber != 0, let screen = try screen(for: model) else {
            throw ConfigError(message: "未找到唯一的目标显示器，请重新检查。")
        }
        let id = try displayID(screen)
        guard CGDisplaySerialNumber(id) == serialNumber else {
            throw ConfigError(message: "显示器硬件序列号不匹配，未确认 HDR 状态。")
        }
        _ = try uuid(id)
        return id
    }

    private static func screen(for model: DellMonitorModel) throws -> NSScreen? {
        let matches = NSScreen.screens.filter { $0.localizedName.localizedCaseInsensitiveContains(model.rawValue) }
        guard matches.count <= 1 else { throw ConfigError(message: "\(model.rawValue) 匹配到多台显示器，未操作。") }
        return matches.first
    }
    private static func displayID(_ screen: NSScreen) throws -> CGDirectDisplayID {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ConfigError(message: "无法读取 \(screen.localizedName) 的显示器标识。")
        }
        return number.uint32Value
    }
    private static func uuid(_ id: CGDirectDisplayID) throws -> String {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
            throw ConfigError(message: "无法读取显示器 UUID。")
        }
        return CFUUIDCreateString(nil, value) as String
    }
    private static func currentProfileURL(_ id: CGDirectDisplayID) -> URL? {
        guard let profile = ColorSyncProfileCreateWithDisplayID(id)?.takeRetainedValue() else { return nil }
        return ColorSyncProfileGetURL(profile, nil)?.takeUnretainedValue() as URL?
    }
}
