import AppKit
import Foundation

@main struct Checks {
    struct Reply: Decodable {
        let ok: Bool; let error: String?; let hdrSent: Bool?; let hdrStatusFlags: Int?
        let displays: [Connected]?
    }
    struct Connected: Decodable { let id: String; let name: String; let serial: String }
    static func helper(_ arguments: [String]) throws -> Reply {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "build/显示器切换.app/Contents/Resources/input-ddc")
        process.arguments = arguments; process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard process.terminationStatus == 0, reply.ok else { throw ConfigError(message: reply.error ?? "DDC helper failed") }
        return reply
    }
    @MainActor static func state(_ model: DellMonitorModel) throws -> ColorDisplayState {
        guard let target = try ColorProfileManager.inspect().first(where: { $0.model == model }) else {
            throw ConfigError(message: "Missing target")
        }
        return target
    }
    @MainActor static func set(_ enabled: Bool, model: DellMonitorModel, tag: String) async throws {
        let target = try state(model)
        print("SET \(model.rawValue) -> \(enabled); supported=\(String(describing: target.hdr.supported))")
        var requests = 0
        try await DellHDRController.set(enabled, model: model, uuid: target.uuid) {
            requests += 1
            guard try helper(["hdr-enable", tag]).hdrSent == true else { throw ConfigError(message: "No HDR send confirmation") }
        }
        assert(requests == (enabled && !target.hdr.canSet ? 1 : 0), "Unexpected hardware write")
        var confirmed = !enabled
        for _ in 0..<(enabled ? 10 : 0) {
            if let value = try? helper(["hdr-get", tag]).hdrStatusFlags {
                if value & 0x40 != 0 { confirmed = true; break }
                print("Hardware \(model.rawValue) F2=\(value), expected HDR bit")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard confirmed else { throw ConfigError(message: "Monitor Smart HDR readback mismatch") }
    }
    @MainActor static func main() {
        // NSScreen needs AppKit's event loop to invalidate cached display IDs after EDID reconnects.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("HDR check failed: \(error.localizedDescription)"); exit(1) }
        }
        app.run()
    }
    @MainActor static func run() async throws {
        setbuf(stdout, nil)
        var wrote = false
        do {
            try await DellHDRController.set(true, model: .qx, uuid: "absent") { wrote = true }
            assertionFailure("Invalid target accepted")
        } catch {}
        assert(!wrote)
        print("Stale target rejected before HDR write; helper validates Dell HDR packet in --self-test")
        guard CommandLine.arguments.contains("--hardware") else { return }
        do { try await hardware() }
        catch { print("Hardware check failed: \(error.localizedDescription)"); exit(1) }
    }
    @MainActor static func hardware() async throws {
        let originals = try ColorProfileManager.inspect()
        guard originals.count == 2, originals.allSatisfy({ $0.profileURL != nil && $0.hdr.enabled != nil }) else {
            throw ConfigError(message: "Both monitors and readable originals required")
        }
        let connected = try helper(["list"]).displays ?? []
        var tags: [DellMonitorModel: String] = [:]
        for original in originals {
            let matches = connected.filter { $0.id == original.uuid && $0.name.contains(original.model.rawValue) }
            guard matches.count == 1 else { throw ConfigError(message: "Ambiguous hardware identity") }
            tags[original.model] = matches[0].serial
        }
        let snapshot = originals.map { ["model": $0.model.rawValue, "uuid": $0.uuid, "profile": $0.profileURL!.path,
                                       "hdr": String($0.hdr.enabled!), "supported": String($0.hdr.supported ?? false)] }
        try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted,.sortedKeys])
            .write(to: URL(fileURLWithPath: "build/dell-hdr-smoke-snapshot.json"), options: .atomic)
        var failure: Error?
        do {
            for original in originals {
                let tag = tags[original.model]!
                let other = originals.first { $0.model != original.model }!
                for otherEnabled in [true, false] {
                    // Our own test fixture establishes actual Smart HDR Off; Dell DDPM is never executed.
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "build/dell-hdr-prepare-off")
                    process.arguments = [tag]; try process.run(); process.waitUntilExit()
                    // A reconnect can invalidate the write transport even after the monitor applied the request.
                    print("Prepare Smart HDR Off transport exit=\(process.terminationStatus)")
                    var ready = false
                    var stable = 0
                    for _ in 0..<80 {
                        try await Task.sleep(for: .milliseconds(250))
                        if let value = try? state(original.model), value.hdr.supported == false {
                            stable += 1
                            if stable >= 8 { ready = true; break }
                        } else { stable = 0 }
                    }
                    guard ready else { throw ConfigError(message: "Smart HDR Off precondition not reached") }
                    try await Task.sleep(for: .seconds(2))
                    try await set(otherEnabled, model: other.model, tag: tags[other.model]!)
                    print("\(original.model.rawValue): enabling from Smart HDR Off; other HDR=\(otherEnabled)")
                    try await set(true, model: original.model, tag: tag)
                    guard try state(other.model).hdr.enabled == otherEnabled else { throw ConfigError(message: "Other monitor changed during cold enable") }
                    try await set(false, model: original.model, tag: tag)
                    guard try state(original.model).hdr.supported == true,
                          try state(other.model).hdr.enabled == otherEnabled else { throw ConfigError(message: "Disable affected Smart HDR capability or other screen") }
                    try await set(true, model: original.model, tag: tag)
                    guard try state(other.model).hdr.enabled == otherEnabled else { throw ConfigError(message: "Other monitor changed during warm enable") }
                    print("\(original.model.rawValue): cold enable, OS disable and warm enable verified via macOS + monitor F2 when HDR enabled")
                }
            }
        } catch { print("TEST FAILED: \(error.localizedDescription)"); failure = error }
        for original in originals {
            do {
                try await set(original.hdr.enabled!, model: original.model, tag: tags[original.model]!)
                let current = try state(original.model)
                if current.profileURL != original.profileURL {
                    try await ColorProfileManager.apply(.init(model: original.model, uuid: current.uuid, before: current.profileURL, target: original.profileURL!))
                }
            } catch { print("RESTORE FAILED \(original.model.rawValue): \(error.localizedDescription)"); failure = error }
        }
        let restored = try ColorProfileManager.inspect()
        guard originals.allSatisfy({ original in restored.contains { $0.model == original.model && $0.hdr.enabled == original.hdr.enabled && $0.profileURL == original.profileURL } }) else {
            throw ConfigError(message: "Original HDR/profile restore mismatch")
        }
        print("Original HDR states and exact profile paths restored; no Dell program or SDK used")
        if let failure { throw failure }
    }
}
