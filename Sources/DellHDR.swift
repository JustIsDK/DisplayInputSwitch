import AppKit
import Foundation

// Smart HDR is enabled over our DDC helper; no Dell executable or SDK is loaded.
@MainActor enum DellHDRController {
    @MainActor private struct Screen {
        let model: DellMonitorModel
        let serialNumber: UInt32
        let enabled: Bool
        init(_ state: ColorDisplayState) throws {
            guard let enabled = state.hdr.enabled else { throw ConfigError(message: "无法读取原 HDR 状态，未修改。") }
            model = state.model; self.enabled = enabled
            let id = try ColorProfileManager.displayID(forUUID: state.uuid)
            serialNumber = CGDisplaySerialNumber(id)
            _ = try ColorProfileManager.displayID(model: model, serialNumber: serialNumber)
        }
        func displayID() throws -> CGDirectDisplayID {
            try ColorProfileManager.displayID(model: model, serialNumber: serialNumber)
        }
        func apply(_ enabled: Bool) async throws {
            let id = try displayID()
            guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
                throw ConfigError(message: "无法读取重连后的显示器标识。")
            }
            let uuid = CFUUIDCreateString(nil, value) as String
            try await HDRController.set(enabled, uuid: uuid)
        }
    }

    static func set(_ enabled: Bool, model: DellMonitorModel, uuid: String,
                    enableSmartHDR: () async throws -> Void) async throws {
        let states = try ColorProfileManager.inspect()
        guard let original = states.first(where: { $0.model == model && $0.uuid == uuid }) else {
            throw ConfigError(message: "目标显示器已改变，请重新检查。")
        }
        let target = try Screen(original)
        let others = try states.filter { $0.model != model }.map(Screen.init)
        var failure: Error?
        do {
            if enabled && !original.hdr.canSet {
                var sendFailure: Error?
                do { try await enableSmartHDR() } catch { sendFailure = error }
                // Enabling Smart HDR changes EDID/UUID. Wait for the same hardware to offer HDR modes.
                var ready = false
                for _ in 0..<80 {
                    try await Task.sleep(for: .milliseconds(250))
                    if let id = try? target.displayID(), HDRController.inspect(id).canSet { ready = true; break }
                }
                guard ready else { throw sendFailure ?? ConfigError(message: "Smart HDR 请求已发送，但重连后仍未检测到 HDR 能力，请重新检查。") }
            }
            // Keep Smart HDR available when disabling OS HDR; avoid an unnecessary EDID reconnect.
            try await target.apply(enabled)
        } catch { failure = error }
        // macOS can reset other screens to SDR during an EDID reconnect. Restore their prior OS HDR states.
        for other in others {
            do {
                let id = try other.displayID()
                if HDRController.inspect(id).enabled != other.enabled { try await other.apply(other.enabled) }
            } catch {
                throw ConfigError(message: "HDR 操作可能已部分完成；恢复另一屏 \(other.model.rawValue) 的 HDR 状态失败：\(error.localizedDescription)")
            }
        }
        if let failure { throw failure }
        try await HDRController.confirm(enabled) { try target.displayID() }
        for other in others {
            guard HDRController.inspect(try other.displayID()).enabled == other.enabled else {
                throw ConfigError(message: "系统重新配置改变了 \(other.model.rawValue) 的 HDR 状态，请重新检查。")
            }
        }
    }
}
