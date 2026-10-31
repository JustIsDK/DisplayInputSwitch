import AppKit
import ColorSync
import Foundation

struct ColorProfileReport: Equatable {
    let qxPath: URL?
    let qePath: URL?
    let targetPath: URL?
    let qxNeedsRepair: Bool

    var targetAvailable: Bool { targetPath != nil }

    var summary: String {
        let qx = Self.label(qxPath)
        let qe = Self.label(qePath)
        let target = targetPath.map { $0.lastPathComponent } ?? "未找到 QX HDR V4 文件"
        let state = qxNeedsRepair ? "QX 不是目标配置，可一键修正" : "QX 已是目标配置"
        return "QX：\(qx)\nQE：\(qe)\n目标：\(target)\n\(state)"
    }

    static func label(_ url: URL?) -> String {
        guard let url else { return "未读取" }
        let name = url.deletingPathExtension().lastPathComponent
        if name.contains("HDR_v4") { return "HDR V4（\(url.lastPathComponent)）" }
        if name.contains("Native_v2") { return "Native V2（\(url.lastPathComponent)）" }
        if name.contains("DCIP3") { return "DCI-P3（\(url.lastPathComponent)）" }
        if name.contains("sRGB") { return "sRGB（\(url.lastPathComponent)）" }
        return url.lastPathComponent
    }
}

enum ColorProfileManager {
    private static let qxToken = "U2723QX"
    private static let qeToken = "U2723QE"
    private static let targetFile = "Dell_U2723QX_HDR_v4_MHC2.icm"

    static func inspect() throws -> ColorProfileReport {
        let qx = try screen(named: qxToken)
        let qxPath = try currentProfileURL(for: qx)
        let qePath: URL?
        if let qe = try optionalScreen(named: qeToken) { qePath = try currentProfileURL(for: qe) } else { qePath = nil }
        let target = targetURL()
        return ColorProfileReport(qxPath: qxPath, qePath: qePath, targetPath: target,
                                 qxNeedsRepair: target.map { qxPath?.standardizedFileURL != $0.standardizedFileURL } ?? true)
    }

    @discardableResult
    static func repairQX() throws -> ColorProfileReport {
        let qx = try screen(named: qxToken)
        guard let target = targetURL() else {
            throw ConfigError(message: "未找到 QX HDR V4 描述文件。请先安装 Dell Display Manager / DDPM 的显示器颜色配置文件。")
        }
        guard ColorSyncProfileCreateWithURL(target as CFURL, nil)?.takeRetainedValue() != nil,
              let uuid = displayUUID(for: qx) else {
            throw ConfigError(message: "QX 颜色描述文件或显示器标识无效，未修改。")
        }
        let settings = [kColorSyncDeviceDefaultProfileID!.takeUnretainedValue() as String: target as CFURL] as CFDictionary
        guard ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass!.takeUnretainedValue(), uuid, settings) else {
            throw ConfigError(message: "系统未接受 QX 颜色描述文件变更。")
        }
        return try inspect()
    }

    private static func screen(named token: String) throws -> NSScreen {
        let screens = NSScreen.screens.filter { $0.localizedName.localizedCaseInsensitiveContains(token) }
        guard screens.count <= 1 else {
            throw ConfigError(message: "未找到唯一的 \(token) 显示器（当前匹配 \(screens.count) 台）。")
        }
        guard let screen = screens.first else {
            if token == qxToken { throw ConfigError(message: "未找到 QX 显示器。") }
            throw ConfigError(message: "未找到 \(token) 显示器。")
        }
        return screen
    }

    private static func optionalScreen(named token: String) throws -> NSScreen? {
        let screens = NSScreen.screens.filter { $0.localizedName.localizedCaseInsensitiveContains(token) }
        guard screens.count <= 1 else {
            throw ConfigError(message: "\(token) 显示器匹配不唯一（当前匹配 \(screens.count) 台）。")
        }
        return screens.first
    }

    private static func displayID(for screen: NSScreen) throws -> CGDirectDisplayID {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw ConfigError(message: "无法读取 \(screen.localizedName) 的显示器标识。")
        }
        return number.uint32Value
    }

    private static func displayUUID(for screen: NSScreen) -> CFUUID? {
        guard let id = try? displayID(for: screen) else { return nil }
        return CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
    }

    private static func currentProfileURL(for screen: NSScreen) throws -> URL? {
        let id = try displayID(for: screen)
        guard let profile = ColorSyncProfileCreateWithDisplayID(id)?.takeRetainedValue() else { return nil }
        return ColorSyncProfileGetURL(profile, nil)?.takeUnretainedValue() as URL?
    }

    private static func targetURL() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Applications/DDPM/Profiles/U2723QX/\(targetFile)"),
            URL(fileURLWithPath: "/Applications/DDPM/Profiles/U2723QX/\(targetFile)"),
            home.appendingPathComponent("Library/ColorSync/Profiles/\(targetFile)"),
            URL(fileURLWithPath: "/Library/ColorSync/Profiles/\(targetFile)")
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}
