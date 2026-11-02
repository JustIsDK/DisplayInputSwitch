import AppKit
import Foundation

@main struct Checks {
    static func response(_ fields: [String: String] = [:], array: Bool = false) throws -> Data {
        var reply = ["Model": "U2723QE", "ServiceTag": "330BJ04", "Command": "GET",
                     "TargetFeature": "HDR", "Value": "OFF", "Result": "PASS", "Message": "N/A"]
        reply.merge(fields) { _, new in new }
        return try JSONSerialization.data(withJSONObject: array ? [reply] : reply)
    }
    static func decode(_ data: Data) throws -> Bool {
        try DellHDRCLI.decode(data, model: .qe, serviceTag: "330BJ04", command: "GET")
    }
    static func rejects(_ action: () throws -> Void) {
        do { try action(); assertionFailure("Invalid CLI input accepted") } catch {}
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let get = try DellHDRCLI.arguments(enabled: nil, serviceTag: "330BJ04")
        assert(get == ["/get", "-display=HDR", "-ServiceTag=330BJ04"])
        for enabled in [true, false] {
            let set = try DellHDRCLI.arguments(enabled: enabled, serviceTag: "330BJ04")
            assert(set ==
                   ["/set", "-display=HDR", "-ServiceTag=330BJ04", enabled ? "-value=On" : "-value=Off"])
        }
        for tag in ["", "330BJ0", "330BJ044", "../test", "330 BJ4", "330BJ0\n"] {
            rejects { _ = try DellHDRCLI.arguments(enabled: true, serviceTag: tag) }
        }
        let off = try decode(response()), on = try decode(response(["Value": "ON"], array: true))
        assert(!off && on)
        for fields in [["Result": "FAIL", "Message": "Cannot find the matching DUT"], ["Value": "N/A"],
                       ["Model": "U2723QX"], ["ServiceTag": "J80FDH3"], ["Command": "SET"], ["TargetFeature": "Brightness"]] {
            rejects { _ = try decode(response(fields)) }
        }
        for data in [Data("[]".utf8), Data("garbage".utf8), Data("{}".utf8)] {
            rejects { _ = try decode(data) }
        }
        let one = try JSONSerialization.jsonObject(with: response())
        rejects { _ = try decode(JSONSerialization.data(withJSONObject: [one, one])) }
        print("Dell HDR command targeting and response validation checks passed")
        guard CommandLine.arguments.contains("--hardware") else { return }
        do { try await hardware() }
        catch { print("Hardware check failed: \(error.localizedDescription)"); exit(1) }
    }

    @MainActor static func hardware() async throws {
        struct Connected: Decodable { let id: String; let name: String; let serial: String }
        struct List: Decodable { let ok: Bool; let displays: [Connected] }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "build/显示器切换.app/Contents/Resources/input-ddc")
        process.arguments = ["list"]; process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let connected = try JSONDecoder().decode(List.self, from: data)
        let displays = try ColorProfileManager.inspect()
        guard process.terminationStatus == 0, connected.ok, displays.count == 2,
              displays.allSatisfy({ $0.profileURL != nil && $0.hdr.enabled != nil }) else {
            throw ConfigError(message: "Both monitors and readable originals required")
        }
        var tags: [DellMonitorModel: String] = [:]
        var serialNumbers: [DellMonitorModel: UInt32] = [:]
        for display in displays {
            let matches = connected.displays.filter { $0.id == display.uuid && $0.name.contains(display.model.rawValue) }
            guard matches.count == 1, let tag = matches.first?.serial,
                  connected.displays.filter({ $0.serial == tag }).count == 1 else {
                throw ConfigError(message: "Display identity is ambiguous")
            }
            let official = try await DellHDRCLI.read(model: display.model, serviceTag: tag)
            guard official == display.hdr.enabled else { throw ConfigError(message: "Original HDR readbacks disagree") }
            tags[display.model] = tag
            serialNumbers[display.model] = CGDisplaySerialNumber(try ColorProfileManager.displayID(forUUID: display.uuid))
        }
        let snapshot = displays.map { ["model": $0.model.rawValue, "uuid": $0.uuid,
                                      "profile": $0.profileURL!.path, "hdr": String($0.hdr.enabled!)] }
        try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "build/dell-hdr-smoke-snapshot.json"), options: .atomic)
        var failure: Error?
        do {
            for target in displays {
                print("Testing \(target.model.rawValue) HDR \(!target.hdr.enabled!)")
                try await DellHDRCLI.set(!target.hdr.enabled!, model: target.model, serviceTag: tags[target.model]!, uuid: target.uuid)
                for other in displays where other.model != target.model {
                    let official = try await DellHDRCLI.read(model: other.model, serviceTag: tags[other.model]!)
                    let id = try ColorProfileManager.displayID(model: other.model, serialNumber: serialNumbers[other.model]!)
                    guard official == other.hdr.enabled, HDRController.inspect(id).enabled == other.hdr.enabled else {
                        throw ConfigError(message: "HDR operation changed the other screen")
                    }
                }
                let current = try ColorProfileManager.inspect().first { $0.model == target.model }!
                print("Restoring \(target.model.rawValue), UUID \(target.uuid) → \(current.uuid)")
                try await DellHDRCLI.set(target.hdr.enabled!, model: target.model, serviceTag: tags[target.model]!, uuid: current.uuid)
                print("\(target.model.rawValue): official + macOS HDR readbacks verified both ways; other monitor unchanged")
            }
        } catch { failure = error }
        // Even a failed SET may have reached the monitor: restore and verify every original state.
        for display in displays {
            do {
                _ = try ColorProfileManager.displayID(model: display.model, serialNumber: serialNumbers[display.model]!)
                let current = try ColorProfileManager.inspect().first { $0.model == display.model }!
                try await DellHDRCLI.set(display.hdr.enabled!, model: display.model, serviceTag: tags[display.model]!, uuid: current.uuid)
                let now = try ColorProfileManager.inspect().first { $0.model == display.model }
                if now?.profileURL != display.profileURL {
                    try await ColorProfileManager.apply(.init(model: display.model, uuid: now!.uuid, before: now?.profileURL, target: display.profileURL!))
                }
            } catch { print("RESTORE FAILED \(display.model.rawValue): \(error)"); failure = error }
        }
        let restored = try ColorProfileManager.inspect()
        guard displays.allSatisfy({ original in restored.contains { $0.model == original.model && $0.profileURL == original.profileURL && $0.hdr.enabled == original.hdr.enabled } }) else {
            throw ConfigError(message: "Original HDR/profile restore mismatch")
        }
        print("Original HDR states and exact profile paths restored and verified")
        if let failure { throw failure }
    }
}
