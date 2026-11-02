import AppKit
import Foundation

@main struct Checks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let qxHDR = directory.appendingPathComponent("Dell_U2723QX_HDR_v4_MHC2.icm")
        let qeNative = directory.appendingPathComponent("Dell_U2723QE_Native_v2.icm")
        try Data([0]).write(to: qxHDR); try Data([0]).write(to: qeNative)
        assert(ColorProfileManager.targetURL(model: .qx, mode: .hdrV4, roots: [directory]) == qxHDR)
        assert(ColorProfileManager.targetURL(model: .qe, mode: .hdrV4, roots: [directory]) == nil, "Never use the other model's profile")
        assert(ColorProfileManager.targetURL(model: .qx, mode: .nativeV2, roots: [directory]) == nil)
        assert(ColorProfileManager.targetURL(model: .qe, mode: .nativeV2, roots: [directory]) == qeNative)
        assert(DellProfileMode.detect(nil) == nil)
        assert(DellProfileMode.detect(URL(fileURLWithPath: "/tmp/unrelated.icc")) == nil)
        assert(DellProfileMode.detect(qxHDR) == .hdrV4 && DellProfileMode.detect(qeNative) == .nativeV2)
        do { _ = try ColorProfileManager.prepare([], mode: .hdrV4); assertionFailure("Empty plan accepted") } catch {}
        let unknown = HDRState(supported: nil, enabled: nil, canSet: false)
        assert(unknown.label == "无法读取 HDR 状态")
        let fake = ColorDisplayState(model: .qx, uuid: "absent", profileURL: nil, availableModes: [], hdr: unknown)
        do { _ = try ColorProfileManager.prepare([fake, fake], mode: .hdrV4); assertionFailure("Duplicate accepted") } catch {}
        do { _ = try ColorProfileManager.displayID(forUUID: fake.uuid); assertionFailure("Stale display accepted") } catch {}
        let displays = try ColorProfileManager.inspect()
        for display in displays {
            print("\(display.model.rawValue): \(display.profileLabel); \(display.hdr.label); canSet=\(display.hdr.canSet)")
        }
        guard CommandLine.arguments.contains("--hardware") else {
            print("Profile lookup, unknown mode, invalid targets and HDR state checks passed (no settings written)")
            return
        }
        guard displays.count == 2, displays.allSatisfy({ $0.profileURL != nil }) else {
            throw ConfigError(message: "Hardware check needs both Dell displays and readable original profiles")
        }
        let snapshot = displays.map { ["model": $0.model.rawValue, "uuid": $0.uuid, "path": $0.profileURL!.path, "hdr": $0.hdr.label] }
        try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: "build/profile-smoke-snapshot.json"), options: .atomic)
        var failure: Error?
        do {
            // A valid first target and invalid second target must reject the whole plan.
            try fm.removeItem(at: qxHDR)
            try fm.copyItem(at: ColorProfileManager.targetURL(model: .qx, mode: .hdrV4)!, to: qxHDR)
            do { _ = try ColorProfileManager.prepare(displays, mode: .hdrV4, roots: [directory]); assertionFailure("Invalid ICC batch accepted") } catch {}
            let verified = try ColorProfileManager.inspect()
            guard verified.map(\.profileURL) == displays.map(\.profileURL) else {
                throw ConfigError(message: "Preflight changed profiles")
            }
            for mode in DellProfileMode.allCases {
                let plan = try ColorProfileManager.prepare(displays, mode: mode)
                for change in plan { try await ColorProfileManager.apply(change) }
                let verified = try ColorProfileManager.inspect()
                guard verified.allSatisfy({ $0.mode == mode }) else { throw ConfigError(message: "Batch profile readback mismatch") }
                print("Both monitors verified: \(mode.rawValue)")
            }
            let beforeSingle = try ColorProfileManager.inspect()
            let singlePlan = try ColorProfileManager.prepare([beforeSingle.first { $0.model == .qx }!], mode: .hdrV4)
            try await ColorProfileManager.apply(singlePlan[0])
            let afterSingle = try ColorProfileManager.inspect()
            guard afterSingle.first(where: { $0.model == .qx })?.mode == .hdrV4,
                  afterSingle.first(where: { $0.model == .qe })?.profileURL == beforeSingle.first(where: { $0.model == .qe })?.profileURL else {
                throw ConfigError(message: "Single-screen operation changed the other screen")
            }
            print("Single-screen HDR V4 verified; other screen unchanged")
            for display in displays {
                if display.hdr.canSet, let original = display.hdr.enabled {
                    do {
                        try await HDRController.set(!original, uuid: display.uuid)
                    } catch {
                        try await HDRController.set(original, uuid: display.uuid)
                        throw error
                    }
                    try await HDRController.set(original, uuid: display.uuid)
                    print("\(display.model.rawValue): HDR toggled and restored")
                } else {
                    do { try await HDRController.set(true, uuid: display.uuid); assertionFailure("Unsupported HDR write accepted") }
                    catch { print("\(display.model.rawValue): unsupported HDR rejected: \(error.localizedDescription)") }
                }
            }
        } catch { failure = error }
        // Always restore exact original files, including an existing cross-model assignment.
        for display in displays {
            do { try await ColorProfileManager.apply(.init(model: display.model, uuid: display.uuid, before: nil, target: display.profileURL!)) }
            catch { print("RESTORE FAILED \(display.model.rawValue): \(error)"); failure = error }
        }
        let restored = try ColorProfileManager.inspect()
        guard restored.map(\.profileURL) == displays.map(\.profileURL) else { throw ConfigError(message: "Original profile restore mismatch") }
        print("Original profile paths restored and verified")
        if let failure { throw failure }
    }
}
