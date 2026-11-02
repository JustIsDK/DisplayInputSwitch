import Foundation
import Darwin
import CoreGraphics

// Use the installed Dell CLI: its HDR command also enables Smart HDR on the monitor.
enum DellHDRCLI {
    static let executable = URL(fileURLWithPath: "/Applications/DDPM/DDPM.app/Contents/MacOS/DDPM")
    static var available: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

    struct Reply: Decodable {
        let model: String
        let serviceTag: String
        let command: String
        let targetFeature: String
        let value: String
        let result: String
        let message: String
        enum CodingKeys: String, CodingKey {
            case model = "Model", serviceTag = "ServiceTag", command = "Command"
            case targetFeature = "TargetFeature", value = "Value", result = "Result", message = "Message"
        }
    }

    static func arguments(enabled: Bool?, serviceTag: String) throws -> [String] {
        guard serviceTag.range(of: #"\A[A-Za-z0-9]{7}\z"#, options: .regularExpression) != nil else {
            throw ConfigError(message: "Dell 显示器服务编号无效，未发送 HDR 请求。")
        }
        var result = [enabled == nil ? "/get" : "/set", "-display=HDR", "-ServiceTag=\(serviceTag)"]
        if let enabled { result.append("-value=\(enabled ? "On" : "Off")") }
        return result
    }

    static func decode(_ data: Data, model: DellMonitorModel, serviceTag: String, command: String) throws -> Bool {
        let decoder = JSONDecoder()
        let replies: [Reply]
        if let array = try? decoder.decode([Reply].self, from: data) { replies = array }
        else if let object = try? decoder.decode(Reply.self, from: data) { replies = [object] }
        else { throw ConfigError(message: "无法解析 Dell DDPM 的 HDR 响应，请检查 DDPM 版本。") }
        guard replies.count == 1, let reply = replies.first else {
            throw ConfigError(message: "Dell DDPM 未唯一匹配目标显示器，未确认 HDR 状态。")
        }
        // Dell can exit with code zero even when Result is FAIL.
        guard reply.result.uppercased() == "PASS" else {
            throw ConfigError(message: "Dell DDPM（\(model.rawValue) \(command)）：\(reply.message)")
        }
        guard reply.model == model.rawValue, reply.serviceTag == serviceTag,
              reply.command.uppercased() == command, reply.targetFeature.uppercased() == "HDR" else {
            throw ConfigError(message: "Dell DDPM 响应的显示器或操作不匹配，未确认 HDR 状态。")
        }
        switch reply.value.uppercased() {
        case "ON": return true
        case "OFF": return false
        default: throw ConfigError(message: "Dell DDPM 返回未知的 HDR 状态，未确认变更。")
        }
    }

    static func read(model: DellMonitorModel, serviceTag: String) async throws -> Bool {
        var retries = 0
        while true {
            let data = try await run(arguments(enabled: nil, serviceTag: serviceTag))
            do { return try decode(data, model: model, serviceTag: serviceTag, command: "GET") }
            catch {
                // DDPM briefly loses both targets while Smart HDR rebuilds its device list. Retry reads only.
                guard retries < 9 else { throw error }
                retries += 1
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    @MainActor static func set(_ enabled: Bool, model: DellMonitorModel, serviceTag: String, uuid: String) async throws {
        let id = try ColorProfileManager.displayID(forUUID: uuid)
        let serialNumber = CGDisplaySerialNumber(id)
        _ = try ColorProfileManager.displayID(model: model, serialNumber: serialNumber)
        let before = try await read(model: model, serviceTag: serviceTag)
        if before != enabled {
            let response = try await run(arguments(enabled: enabled, serviceTag: serviceTag))
            let submitted = try decode(response, model: model, serviceTag: serviceTag, command: "SET")
            guard submitted == enabled else {
                throw ConfigError(message: "Dell DDPM 请求已执行，但 HDR 回读未达到目标，请重新检查。")
            }
        }
        // Smart HDR can change EDID and macOS UUID; the hardware serial survives reconnects.
        try await HDRController.confirm(enabled) {
            try ColorProfileManager.displayID(model: model, serialNumber: serialNumber)
        }
        let actual = try await read(model: model, serviceTag: serviceTag)
        guard actual == enabled else {
            throw ConfigError(message: "Dell DDPM 请求已执行，但 HDR 回读未达到目标，请重新检查。")
        }
    }

    private static func run(_ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), pipe = Pipe()
                process.executableURL = executable; process.arguments = arguments
                process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let timeout = DispatchWorkItem {
                        if process.isRunning {
                            process.terminate()
                            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            }
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit(); timeout.cancel()
                    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                        throw ConfigError(message: "Dell DDPM 请求失败或超时，可能已部分执行，请重新检查 HDR 状态。")
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
