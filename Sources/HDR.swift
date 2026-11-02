import CoreGraphics
import Darwin

struct HDRState: Equatable {
    let supported: Bool?
    let enabled: Bool?
    let canSet: Bool
    var label: String {
        if supported == false { return "当前连接未提供 HDR（请检查显示器 Smart HDR 设置）" }
        guard let enabled else { return "无法读取 HDR 状态" }
        return enabled ? "HDR 已开启" : "HDR 已关闭"
    }
}

enum HDRController {
    private typealias Query = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Setter = @convention(c) (CGDirectDisplayID, Bool, Int32, Int32) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let supported: Query? = symbol("SLSDisplaySupportsHDRMode", as: Query.self)
    private static let enabled: Query? = symbol("SLSDisplayIsHDRModeEnabled", as: Query.self)
    private static let setter: Setter? = symbol("SLSDisplaySetHDRModeEnabled", as: Setter.self)
    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
    static func inspect(_ id: CGDirectDisplayID) -> HDRState {
        let supports = supported?(id)
        return HDRState(supported: supports, enabled: supports == false ? false : enabled?(id),
                        canSet: supports == true && enabled != nil && setter != nil)
    }
    @MainActor static func set(_ requested: Bool, uuid: String) async throws {
        let id = try ColorProfileManager.displayID(forUUID: uuid)
        let state = inspect(id)
        guard state.canSet, let setter else { throw ConfigError(message: state.label + "；暂时无法切换。") }
        if state.enabled == requested { return }
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success, let configuration else { throw ConfigError(message: "无法开始 HDR 配置（\(begin.rawValue)）。") }
        // Private SkyLight ABI, also documented by joevt/AllRez AppleMisc.h; remaining parameters are zero.
        let result = setter(id, requested, 0, 0)
        guard result == 0 else {
            CGCancelDisplayConfiguration(configuration)
            throw ConfigError(message: "系统拒绝 HDR 变更（\(result)）。")
        }
        let complete = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard complete == .success else { throw ConfigError(message: "HDR 提交失败（\(complete.rawValue)），请重新检查实际状态。") }
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(250))
            if let currentID = try? ColorProfileManager.displayID(forUUID: uuid), inspect(currentID).enabled == requested { return }
        }
        throw ConfigError(message: "HDR 请求已提交，但未确认目标状态，请重新检查。")
    }
}
