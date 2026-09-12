// CPU/file-only checks. No AppKit, UserDefaults, player, input injection, or GPU.
import Foundation

@main
struct TransientSessionChecks {
    @MainActor
    static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("HDRPlayer-transient-checks-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: root) }
        var count = 0
        func passed() { count += 1 }
        func environment(_ name: String) -> [String: String] {
            ["HDRPLAYER_TRANSIENT_SESSION": "1", "HDRPLAYER_CACHE_DIRECTORY": root.appendingPathComponent(name).path]
        }
        func rejected(_ environment: [String: String], arguments: [String] = []) -> Bool {
            do { _ = try PlayerSessionConfiguration.resolve(environment: environment, arguments: arguments); return false }
            catch { return true }
        }

        let ordinary = try PlayerSessionConfiguration.resolve(environment: ["HDRPLAYER_UI_SMOKE_REPORT": "ordinary-smoke", "HDRPLAYER_CACHE_DIRECTORY": "relative"], arguments: ["--report"])
        assert(!ordinary.isTransient && ordinary.cacheDirectory == nil)
        passed()
        let disabled = try PlayerSessionConfiguration.resolve(environment: ["HDRPLAYER_TRANSIENT_SESSION": "0", "HDRPLAYER_UI_SMOKE_REPORT": "smoke"], arguments: ["--headless"])
        assert(!disabled.isTransient && disabled.cacheDirectory == nil)
        for value in ["", "true", "yes", "2", " 1", "1 "] {
            var invalid = environment("invalid-flag")
            invalid["HDRPLAYER_TRANSIENT_SESSION"] = value
            assert(rejected(invalid))
        }
        assert(!files.fileExists(atPath: root.appendingPathComponent("invalid-flag").path))
        passed()
        assert(rejected(["HDRPLAYER_TRANSIENT_SESSION": "1"]))
        for path in ["", "relative", "/invalid\0suffix"] {
            assert(rejected(["HDRPLAYER_TRANSIENT_SESSION": "1", "HDRPLAYER_CACHE_DIRECTORY": path]))
        }
        passed()
        for key in ["HDRPLAYER_UI_SMOKE_REPORT", "HDRPLAYER_UI_SMOKE_KEEP_PREFERENCES", "HDRPLAYER_UI_SMOKE_KIND", "HDRPLAYER_UI_SMOKE_WINDOW_OBSERVATIONS", "HDRPLAYER_FLOATING_KEYBOARD_DIAGNOSTIC", "HDRPLAYER_FLOATING_SPACE_DIRECTORY", "HDRPLAYER_FLOATING_FULLSCREEN_DIAGNOSTIC", "HDRPLAYER_FLOATING_CAPTURE_DIRECTORY", "HDRPLAYER_ENABLE_PIP", "HDRPLAYER_PIP", "HDRPLAYER_PIP_MODE", "HDRPLAYER_SYSTEM_PIP_DIRECTORY"] {
            for value in ["", "0", "1"] {
                var env = environment("conflict")
                env[key] = value
                assert(rejected(env))
            }
        }
        assert(!files.fileExists(atPath: root.appendingPathComponent("conflict").path))
        passed()
        for flag in ["--headless", "--capture-dir", "--capture-every", "--headroom", "--report", "--frames", "--exit-after-playback"] {
            assert(rejected(environment("cli"), arguments: [flag]))
            assert(rejected(environment("cli"), arguments: [flag + "=value"]))
        }
        assert(!files.fileExists(atPath: root.appendingPathComponent("cli").path))
        passed()
        var allowed = environment("fresh")
        allowed["HDRPLAYER_FLOATING_VIDEO"] = "1"
        allowed["HDRPLAYER_LIFECYCLE_LOG"] = root.appendingPathComponent("lifecycle.jsonl").path
        let transient = try PlayerSessionConfiguration.resolve(environment: allowed, arguments: ["fixture.mkv"])
        assert(transient.isTransient && transient.cacheDirectory == root.appendingPathComponent("fresh", isDirectory: true))
        let attributes = try files.attributesOfItem(atPath: transient.cacheDirectory!.path)
        assert((attributes[.posixPermissions] as! NSNumber).intValue & 0o077 == 0)
        passed()
        let sentinel = root.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel, options: .withoutOverwriting)
        let symlink = root.appendingPathComponent("symlink")
        try files.createSymbolicLink(at: symlink, withDestinationURL: sentinel)
        let dangling = root.appendingPathComponent("dangling")
        try files.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("absent"))
        for name in ["fresh", "sentinel", "symlink", "dangling"] { assert(rejected(environment(name))) }
        let sentinelBytes = try Data(contentsOf: sentinel)
        let symlinkDestination = try files.destinationOfSymbolicLink(atPath: symlink.path)
        let danglingDestination = try files.destinationOfSymbolicLink(atPath: dangling.path)
        assert(sentinelBytes == Data("keep".utf8))
        assert(symlinkDestination == sentinel.path)
        assert(danglingDestination == root.appendingPathComponent("absent").path)
        passed()
        assert(rejected(environment("missing-parent/cache")))
        assert(!files.fileExists(atPath: root.appendingPathComponent("missing-parent").path))
        passed()

        let memory = PlayerSessionPreferences(transient: true) { fatalError("Transient mode accessed persistence") }
        assert(memory.values["muted"] as? Bool == true && memory.values["enabled"] as? Bool == false)
        assert(memory.values["width"] == nil && memory.values["position"] == nil)
        passed()
        memory.replace(["muted": false, "enabled": true, "volume": 37.0])
        assert(memory.values["muted"] as? Bool == false && memory.values["enabled"] as? Bool == true)
        assert(memory.values["volume"] as? Double == 37)
        passed()
        var factoryCalls = 0
        var writes: [[String: Any]] = []
        let saved: [String: Any] = ["muted": false, "enabled": true, "volume": 42.0, "width": 64]
        let persistent = PlayerSessionPreferences(transient: false) {
            factoryCalls += 1
            return (saved, { writes.append($0) })
        }
        assert(factoryCalls == 1 && NSDictionary(dictionary: persistent.values).isEqual(to: saved) && writes.isEmpty)
        let updated: [String: Any] = ["muted": true, "enabled": false, "volume": 17.0]
        persistent.replace(updated)
        assert(factoryCalls == 1 && writes.count == 1 && NSDictionary(dictionary: writes[0]).isEqual(to: updated))
        assert(NSDictionary(dictionary: persistent.values).isEqual(to: updated))
        passed()
        print("\(count) transient-session CPU/file checks passed; no saved preferences or physical input were accessed")
    }
}
