import AppKit
import CMpv
import Foundation

private struct MPVFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runtime loading keeps the app shell independent of the provisional core and
/// loads exactly one shared FrameEngine/MLX instance through the patched libmpv.
private final class MPVLibrary: @unchecked Sendable {
    typealias Create = @convention(c) () -> OpaquePointer?
    typealias Initialize = @convention(c) (OpaquePointer?) -> Int32
    typealias SetString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    typealias Command = @convention(c) (OpaquePointer?, UnsafePointer<UnsafePointer<CChar>?>?) -> Int32
    typealias WaitEvent = @convention(c) (OpaquePointer?, Double) -> UnsafeMutablePointer<mpv_event>?
    typealias GetString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias Destroy = @convention(c) (OpaquePointer?) -> Void
    typealias ErrorString = @convention(c) (Int32) -> UnsafePointer<CChar>?
    typealias Log = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
    let create: Create
    let initialize: Initialize
    let setOption: SetString
    let command: Command
    let waitEvent: WaitEvent
    let getString: GetString
    let free: Free
    let destroy: Destroy
    let errorString: ErrorString
    let requestLog: Log
    let path: String

    init() throws {
        if let driver = Bundle.main.resourceURL?.appendingPathComponent("vulkan/icd.d/MoltenVK_icd.json"),
           FileManager.default.fileExists(atPath: driver.path) {
            setenv("VK_DRIVER_FILES", driver.path, 0)
        }
        let candidates = [ProcessInfo.processInfo.environment["METAL_DLSS_MPV_LIBRARY"],
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libmpv.2.dylib").path,
            Self.projectRoot()?.appendingPathComponent("artifacts/mpv-build/libmpv.2.dylib").path].compactMap { $0 }
        var library: UnsafeMutableRawPointer?
        var selected = ""
        var errors: [String] = []
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            if let loaded = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) { library = loaded; selected = candidate; break }
            if let error = dlerror() { errors.append(String(cString: error)) }
        }
        guard let library else { throw MPVFailure(message: "Patched mpv is unavailable. Run scripts/build-mpv-adapter.sh. " + errors.joined(separator: "; ")) }
        path = selected
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let value = dlsym(library, name) else { throw MPVFailure(message: "mpv symbol unavailable: \(name)") }
            return unsafeBitCast(value, to: type)
        }
        create = try symbol("mpv_create", as: Create.self)
        initialize = try symbol("mpv_initialize", as: Initialize.self)
        setOption = try symbol("mpv_set_option_string", as: SetString.self)
        command = try symbol("mpv_command", as: Command.self)
        waitEvent = try symbol("mpv_wait_event", as: WaitEvent.self)
        getString = try symbol("mpv_get_property_string", as: GetString.self)
        free = try symbol("mpv_free", as: Free.self)
        destroy = try symbol("mpv_terminate_destroy", as: Destroy.self)
        errorString = try symbol("mpv_error_string", as: ErrorString.self)
        requestLog = try symbol("mpv_request_log_messages", as: Log.self)
        // Keep the library loaded until process exit: AppKit/Vulkan may retain
        // deferred native callbacks after a particular player has been destroyed.
    }
    static func projectRoot() -> URL? {
        var candidates = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for _ in 0..<8 {
            for root in candidates where FileManager.default.fileExists(atPath: root.appendingPathComponent("vendor/mpv/include/mpv/client.h").path) { return root }
            candidates = candidates.map { $0.deletingLastPathComponent() }
        }
        return nil
    }
    func error(_ code: Int32) -> String { errorString(code).map { String(cString: $0) } ?? "mpv error \(code)" }
}

private final class MPVPlayerWorker: @unchecked Sendable {
    let hostPointer: Int64
    let filter: String
    let volume: Double
    let muted: Bool
    let subtitleBrightness: Double
    let subtitleScale: Double
    let subtitleDelay: Double
    let onState: @Sendable (Data) -> Void
    let onFinish: @Sendable () -> Void
    private let lock = NSLock()
    private struct QueuedCommand { let args: [String]; let preparedRequest: Data?; let configurationID: UInt64; let removeExistingFilter: Bool }
    private var commands: [QueuedCommand] = []
    let preparedRequestURL: URL
    private var stopping = false

    init(host: NSView, filter: String, preparedRequestURL: URL, volume: Double, muted: Bool, subtitleBrightness: Double, subtitleScale: Double, subtitleDelay: Double,
         onState: @escaping @Sendable (Data) -> Void, onFinish: @escaping @Sendable () -> Void) {
        hostPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(host).toOpaque()))
        self.preparedRequestURL = preparedRequestURL
        self.filter = filter; self.volume = volume; self.muted = muted; self.subtitleBrightness = subtitleBrightness
        self.subtitleScale = subtitleScale; self.subtitleDelay = subtitleDelay
        self.onState = onState; self.onFinish = onFinish
    }
    func enqueue(_ args: [String], preparedRequest: Data? = nil, configurationID: UInt64 = 0, removeExistingFilter: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard !stopping else { return }
        // Latest desired settings replace waiting settings while the core is
        // occupied. Relative frame/toggle actions retain their FIFO order.
        func key(_ command: [String]) -> String? {
            guard let first = command.first else { return nil }
            if ["seek", "loadfile"].contains(first) { return first }
            if first == "set", command.count > 1 { return "set:" + command[1] }
            if first == "vf", command.dropFirst().first == "set" { return "vf:set" }
            if first == "vf-command", command.count > 2 { return command.prefix(3).joined(separator: ":") }
            return nil
        }
        if let replacement = key(args) { commands.removeAll { key($0.args) == replacement } }
        if args.first == "loadfile" {
            commands.removeAll { ["seek", "frame-step", "frame-back-step"].contains($0.args.first ?? "") }
        }
        if commands.count == 64 { commands.removeFirst() }
        commands.append(QueuedCommand(args: args, preparedRequest: preparedRequest, configurationID: configurationID, removeExistingFilter: removeExistingFilter))
    }
    func stop() { lock.lock(); stopping = true; commands.removeAll(); lock.unlock() }
    private func pending() -> (QueuedCommand?, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (commands.isEmpty ? nil : commands.removeFirst(), stopping)
    }
    private func publish(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { onState(data) }
    }
    private func invoke(_ args: [String], library: MPVLibrary, handle: OpaquePointer) -> Int32 {
        let strings = args.map { strdup($0)! }
        defer { strings.forEach { Darwin.free($0) } }
        let pointers = strings.map { Optional(UnsafePointer<CChar>($0)) } + [nil]
        return pointers.withUnsafeBufferPointer { library.command(handle, $0.baseAddress) }
    }
    func run() {
        defer { try? FileManager.default.removeItem(at: preparedRequestURL); onFinish() }
        do {
            let library = try MPVLibrary()
            guard let handle = library.create() else { throw MPVFailure(message: "Cannot create mpv playback core") }
            defer { library.destroy(handle) }
            let options: [String: String] = ["config": "no", "vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "macvk",
                "wid": String(hostPointer), "hwdec": "videotoolbox", "idle": "yes", "keep-open": "yes",
                "target-colorspace-hint": "yes", "vf": filter, "input-default-bindings": "no", "input-vo-keyboard": "no",
                "osc": "no", "osd-level": "0", "blend-subtitles": "no", "volume": String(volume), "mute": muted ? "yes" : "no",
                "cache-pause": "yes", "msg-level": "all=warn", "sub-color": Self.subtitleColor(subtitleBrightness),
                "sub-scale": String(subtitleScale), "sub-delay": String(subtitleDelay)]
            for (key, value) in options {
                let code = library.setOption(handle, key, value)
                if code < 0 { throw MPVFailure(message: "\(key): \(library.error(code))") }
            }
            let initialized = library.initialize(handle)
            guard initialized >= 0 else { throw MPVFailure(message: library.error(initialized)) }
            _ = library.requestLog(handle, "warn")
            var failure: String?
            var appliedConfigurationID: UInt64 = 0
            var nextState = Date.distantPast
            var running = true
            func property(_ name: String) -> String? {
                guard let value = library.getString(handle, name) else { return nil }
                defer { library.free(UnsafeMutableRawPointer(value)) }
                return String(cString: value)
            }
            while running {
                let (work, stop) = pending()
                if stop { break }
                if let work {
                    let args = work.args
                    if work.removeExistingFilter, let filters = property("vf"), let json = filters.data(using: .utf8),
                       let entries = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]],
                       entries.contains(where: { $0["label"] as? String == "enhance" }) {
                        // vf set may construct its replacement before destroying
                        // the old context. Explicit removal first drains its job
                        // and releases the cache owner before capacity can change.
                        let removed = invoke(["vf", "remove", "@enhance"], library: library, handle: handle)
                        if removed < 0 { failure = "Cannot close previous preparation context: \(library.error(removed))"; continue }
                    }
                    if let request = work.preparedRequest {
                        do { try request.write(to: preparedRequestURL, options: .atomic) }
                        catch { failure = "Preparation configuration: \(error.localizedDescription)"; continue }
                    }
                    let result = invoke(args, library: library, handle: handle)
                    if result < 0 { failure = "\(args.first ?? "Command"): \(library.error(result))" }
                    else if args.first == "loadfile" || (args.first == "vf" && args.dropFirst().first == "set") { failure = nil }
                    if result >= 0, work.configurationID != 0 { appliedConfigurationID = work.configurationID }
                }
                if let event = library.waitEvent(handle, 0.04)?.pointee {
                    switch event.event_id {
                    case MPV_EVENT_SHUTDOWN: running = false
                    case MPV_EVENT_LOG_MESSAGE:
                        if let raw = event.data {
                            let message = raw.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                            if message.log_level.rawValue <= MPV_LOG_LEVEL_ERROR.rawValue {
                                failure = String(cString: message.text).trimmingCharacters(in: .whitespacesAndNewlines)
                                fputs("mpv[\(String(cString: message.prefix))]: \(failure!)\n", stderr)
                            }
                        }
                    case MPV_EVENT_END_FILE:
                        if let raw = event.data {
                            let end = raw.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                            if end.error < 0 { failure = library.error(end.error) }
                        }
                    default: break
                    }
                }
                if Date() >= nextState {
                    nextState = Date().addingTimeInterval(0.12)
                    func number(_ key: String, fallback: Double = 0) -> Double {
                        let value = property(key).flatMap(Double.init) ?? fallback
                        return value.isFinite ? value : fallback
                    }
                    func array(_ key: String) -> [[String: Any]] {
                        guard let text = property(key), let data = text.data(using: .utf8) else { return [] }
                        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
                    }
                    let tracks: [[String: Any]] = array("track-list").map { track in
                        ["id": track["id"] ?? 0, "type": track["type"] ?? "unknown", "title": track["title"] ?? track["codec"] ?? "Track",
                         "language": track["lang"] ?? (track["metadata"] as? [String: Any])?["language"] ?? "", "selected": track["selected"] ?? false, "external": track["external"] ?? false]
                            .merging(track.filter { $0.key.hasPrefix("dolby-vision-") }) { _, metadata in metadata }
                    }
                    let chapters: [[String: Any]] = array("chapter-list").enumerated().map { index, chapter in
                        ["index": index, "title": chapter["title"] ?? "Chapter \(index + 1)", "time": chapter["time"] ?? 0]
                    }
                    var state: [String: Any] = ["configurationID": appliedConfigurationID, "initialized": true, "title": property("media-title") ?? "HDR Player", "source": property("path") ?? "",
                        "paused": property("pause") == "yes", "position": number("time-pos"), "duration": number("duration"),
                        "playing": property("pause") == "no" && property("core-idle") == "no",
                        "volume": number("volume", fallback: volume), "muted": property("mute") == "yes", "loading": property("paused-for-cache") == "yes",
                        "tracks": tracks, "chapters": chapters, "chapter": Int(number("chapter", fallback: -1)),
                        "sourceFPS": number("container-fps"), "frameDrops": Int(number("frame-drop-count")),
                        "decoderDrops": Int(number("decoder-frame-drop-count")), "coreLibrary": library.path,
                        "subtitleDelay": number("sub-delay"), "subtitleScale": number("sub-scale", fallback: 1)]
                    if let text = property("enhancement-state"), let data = text.data(using: .utf8),
                       let enhancement = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        state["nativeEnhancement"] = enhancement
                    }
                    if let failure { state["error"] = failure }
                    publish(state)
                }
            }
        } catch { publish(["initialized": false, "loading": false, "error": error.localizedDescription]) }
    }
    static func subtitleColor(_ brightness: Double) -> String {
        let component = Int((max(0.1, min(1, brightness)) * 255).rounded())
        return String(format: "#%02X%02X%02XFF", component, component, component)
    }
}

@MainActor
final class MPVPlaybackController {
    let hostView: NSView
    var onState: (([String: Any]) -> Void)?
    var onStopped: (() -> Void)?
    private let defaults: UserDefaults
    private var worker: MPVPlayerWorker?
    private var source = ""
    private var modelURL: URL?
    private var enabled: Bool
    private var strength: Double
    private var colorStrength: Double
    private var width: Int
    private var height: Int
    private var mode: String
    private var subtitleBrightness: Double
    private var subtitleScale: Double
    private var subtitleDelay: Double
    private var preparationFailure: String?
    private var configurationID: UInt64 = 0
    private var capacityBytes: Int64
    private let cacheDirectory: URL
    private let preparedRequestURL = FileManager.default.temporaryDirectory.appendingPathComponent("HDRPlayer-prepared-\(UUID().uuidString).json")
    private var pauseIntent = PlayerPauseIntent()
    private(set) var state: [String: Any] = [:]

    init(hostView: NSView) {
        self.hostView = hostView
        if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_REPORT"] != nil {
            defaults = UserDefaults(suiteName: "HDRPlayer.Smoke")!
            if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KEEP_PREFERENCES"] != "1" { defaults.removePersistentDomain(forName: "HDRPlayer.Smoke") }
        } else { defaults = .standard }
        let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        if let override = ProcessInfo.processInfo.environment["HDRPLAYER_CACHE_DIRECTORY"] {
            cacheDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_REPORT"] != nil {
            cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("HDRPlayer-smoke-cache-\(UUID().uuidString)", isDirectory: true)
        } else { cacheDirectory = cacheBase.appendingPathComponent("HDRPlayer/Prepared", isDirectory: true) }
        let saved = defaults.dictionary(forKey: "HDRPlayer.preferences.v1") ?? [:]
        enabled = saved["enabled"] as? Bool ?? false
        strength = min(1, max(0, saved["strength"] as? Double ?? 1))
        colorStrength = min(1, max(0, saved["colorStrength"] as? Double ?? 1))
        width = min(512, max(16, saved["width"] as? Int ?? 32))
        height = min(288, max(16, saved["height"] as? Int ?? 24))
        capacityBytes = Int64(min(64, max(1, saved["cacheCapacityGiB"] as? Double ?? 8)) * 1_073_741_824)
        // Qualification belongs to this running model/source session.
        mode = "adaptive"
        subtitleBrightness = min(1, max(0.1, saved["subtitleBrightness"] as? Double ?? 1))
        subtitleScale = min(3, max(0.5, saved["subtitleScale"] as? Double ?? 1))
        subtitleDelay = saved["subtitleDelay"] as? Double ?? 0
        let candidates = [ProcessInfo.processInfo.environment["MLXDLSS_NEURAL_RENDERING_PACKAGE"].map { URL(fileURLWithPath: $0) },
            Bundle.main.resourceURL?.appendingPathComponent("Models/NeuralRendering.dlssmodel"),
            MPVLibrary.projectRoot()?.appendingPathComponent("models/neural-rendering/NeuralRendering.dlssmodel")].compactMap { $0 }
        modelURL = candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("weights.safetensors").path) }
        if modelURL == nil { enabled = false }
        state = ["version": 1, "title": "HDR Player", "source": "", "paused": true, "position": 0, "duration": 0,
            "volume": saved["volume"] as? Double ?? 100, "muted": saved["muted"] as? Bool ?? false,
            "fullscreen": false, "loading": false, "tracks": [], "chapters": [], "chapter": -1]
        updateProcessing()
    }
    func start() {
        guard worker == nil else { return }
        let worker = MPVPlayerWorker(host: hostView, filter: filter(), preparedRequestURL: preparedRequestURL, volume: state["volume"] as? Double ?? 100,
            muted: state["muted"] as? Bool ?? false, subtitleBrightness: subtitleBrightness, subtitleScale: subtitleScale, subtitleDelay: subtitleDelay,
            onState: { [weak self] data in DispatchQueue.main.async { self?.receive(data) } },
            onFinish: { [weak self] in DispatchQueue.main.async { self?.worker = nil; self?.onStopped?() } })
        self.worker = worker
        DispatchQueue.global(qos: .userInitiated).async { worker.run() }
    }
    func stop() { if let worker { worker.stop() } else { onStopped?() } }
    func load(_ url: URL) {
        if worker == nil { start() }
        if mode == "prepared" { mode = "adaptive"; reconfigure() }
        source = url.path
        preparationFailure = nil
        state.removeValue(forKey: "prepared")
        state.removeValue(forKey: "nativeEnhancement")
        state["tracks"] = []
        state["source"] = source; state["title"] = url.lastPathComponent; state["loading"] = true
        state.removeValue(forKey: "error")
        worker?.enqueue(["loadfile", url.path, "replace"])
        pauseIntent.request(false)
        worker?.enqueue(["set", "pause", "no"])
        publish()
    }
    func fullscreenChanged(_ value: Bool) { state["fullscreen"] = value; publish() }
    func lifecycleSnapshot() -> [String: Any] {
        var snapshot = state
        snapshot["requestedPause"] = pauseIntent.requested.map { $0 as Any } ?? NSNull()
        return snapshot
    }
    func sleep() {
        if pauseIntent.beginSleep(observed: state["paused"] as? Bool ?? true) { worker?.enqueue(["set", "pause", "yes"]) }
    }
    func wake() {
        if let paused = pauseIntent.endSleep() { worker?.enqueue(["set", "pause", paused ? "yes" : "no"]) }
    }
    func command(_ name: String, value: Any?) {
        func numeric() -> Double? { (value as? NSNumber)?.doubleValue }
        if dolbyVisionUnavailableReason != nil &&
           (["strength", "colorStrength", "quality", "mode"].contains(name) ||
            (name == "enhancement" && value as? Bool == true)) { publish(); return }
        switch name {
        case "play": pauseIntent.request(false); worker?.enqueue(["set", "pause", "no"])
        case "pause": pauseIntent.request(true); worker?.enqueue(["set", "pause", "yes"])
        case "togglePause":
            let paused = !pauseIntent.desired(observed: state["paused"] as? Bool ?? true)
            pauseIntent.request(paused); worker?.enqueue(["set", "pause", paused ? "yes" : "no"])
        case "seek":
            if let position = numeric(), position.isFinite { worker?.enqueue(["seek", String(max(0, position)), "absolute+exact"]) }
        case "frameStep": pauseIntent.request(true); worker?.enqueue([(numeric() ?? 1) < 0 ? "frame-back-step" : "frame-step"])
        case "volume":
            if let volume = numeric(), volume.isFinite { state["volume"] = min(100, max(0, volume)); worker?.enqueue(["set", "volume", String(min(100, max(0, volume)))]) }
        case "mute":
            if let mute = value as? Bool { state["muted"] = mute; worker?.enqueue(["set", "mute", mute ? "yes" : "no"]) }
        case "track":
            if let track = value as? [String: Any], let type = track["type"] as? String,
               let property = ["audio": "aid", "video": "vid", "sub": "sid"][type] {
                let id = (track["id"] as? NSNumber)?.stringValue ?? (track["id"] as? String)
                if let id, Int(id) != nil || ["no", "auto"].contains(id) {
                    if type == "video", id != "1", mode == "prepared" { mode = "adaptive"; reconfigure() }
                    worker?.enqueue(["set", property, id])
                }
            }
        case "chapter": if let index = numeric(), index.isFinite, index >= 0, index < Double(Int.max) { worker?.enqueue(["set", "chapter", String(Int(index))]) }
        case "enhancement":
            if let value = value as? Bool, modelURL != nil {
                enabled = value
                if source.isEmpty { reconfigure() }
                else { worker?.enqueue(["vf-command", "enhance", "bypass", enabled ? "no" : "yes"]) }
            }
        case "strength": if let value = numeric(), value.isFinite { strength = min(1, max(0, value)); reconfigure() }
        case "colorStrength": if let value = numeric(), value.isFinite { colorStrength = min(1, max(0, value)); reconfigure() }
        case "quality":
            if let size = value as? [String: NSNumber], let w = size["width"]?.intValue, let h = size["height"]?.intValue,
               (16...8192).contains(w), (16...8192).contains(h), w * h <= 512 * 288 { width = w; height = h; reconfigure() }
        case "mode":
            let modes = (state["processing"] as? [String: Any])?["availableModes"] as? [String] ?? []
            if let requested = value as? String, modes.contains(requested) {
                let previous = mode
                mode = requested
                if requested == "prepared" { enabled = true; reconfigure() }
                else if previous == "prepared" { reconfigure() }
                else { worker?.enqueue(["vf-command", "enhance", "policy", requested]) }
            }
        case "prepare":
            if mode == "prepared", let action = value as? String, ["start", "cancel"].contains(action) {
                worker?.enqueue(["vf-command", "enhance", "prepare", action])
            }
        case "cacheCapacityGiB":
            if let gib = numeric(), gib.isFinite, (1...64).contains(gib) {
                capacityBytes = Int64(gib * 1_073_741_824)
                if mode == "prepared" { reconfigure() }
            }
        case "compare":
            let native = state["nativeEnhancement"] as? [String: Any] ?? [:]
            if native["compare-ready"] as? Bool == true {
                let selection = value as? String ?? (native["comparison"] as? String == "original" ? "enhanced" : "original")
                if ["original", "enhanced"].contains(selection) { worker?.enqueue(["vf-command", "enhance", "compare", selection]) }
            }
        case "subtitleBrightness":
            if let value = numeric(), value.isFinite {
                subtitleBrightness = min(1, max(0.1, value))
                worker?.enqueue(["set", "sub-color", MPVPlayerWorker.subtitleColor(subtitleBrightness)])
            }
        case "subtitleDelay": if let value = numeric(), value.isFinite { subtitleDelay = min(3600, max(-3600, value)); worker?.enqueue(["set", "sub-delay", String(subtitleDelay)]) }
        case "subtitleScale": if let value = numeric(), value.isFinite { subtitleScale = min(3, max(0.5, value)); worker?.enqueue(["set", "sub-scale", String(subtitleScale)]) }
        default: break
        }
        persist(); publish()
    }
    private func filter() -> String {
        let model = modelURL.map { "model=%\($0.path.utf8.count)%\($0.path):" } ?? ""
        let prepared = mode == "prepared" ? "prepared-config=%\(preparedRequestURL.path.utf8.count)%\(preparedRequestURL.path):prepare=no:" : ""
        return "@enhance:metal-hdr=\(model)\(prepared)processing-width=\(width):processing-height=\(height):strength=\(strength):colour-strength=\(colorStrength):maximum-luminance-ratio=2:reference-white=203:policy=adaptive:bypass=\(enabled ? "no" : "yes")"
    }
    private func reconfigure() {
        if mode == "live" { mode = "adaptive" }
        if mode == "prepared" { preparationFailure = nil }
        state["message"] = mode == "prepared" ? "Updating Prepared cache configuration; the previous job is cancelled and completed segments remain reusable." : "Reconfiguring enhancement; temporal history resets."
        state["configurationPending"] = true
        configurationID &+= 1
        state["loading"] = true
        var request: Data?
        if mode == "prepared" {
            let json: [String: Any] = ["sourcePath": source, "cacheDirectory": cacheDirectory.path,
                "capacityBytes": capacityBytes, "segmentFrames": 60, "prerollFrames": 8]
            request = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            guard request != nil else { state["error"] = "Cannot encode preparation configuration"; return }
        }
        let removingPrepared = mode == "prepared" || (state["nativeEnhancement"] as? [String: Any])?["policy"] as? String == "prepared"
        worker?.enqueue(["vf", "set", filter()], preparedRequest: request, configurationID: configurationID,
            removeExistingFilter: removingPrepared)
    }
    private func receive(_ data: Data) {
        guard let incoming = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        state.merge(incoming) { _, new in new }
        if let paused = incoming["paused"] as? Bool { pauseIntent.observe(paused) }
        if incoming["configurationID"] as? UInt64 == configurationID || incoming["error"] != nil {
            state["configurationPending"] = false
        }
        if let native = incoming["nativeEnhancement"] as? [String: Any],
           mode == "live", native["policy"] as? String == "adaptive" { mode = "adaptive" }
        if mode == "prepared" {
            let native = incoming["nativeEnhancement"] as? [String: Any] ?? [:]
            let progress = native["prepared"] as? [String: Any] ?? [:]
            if progress["configurationState"] as? String == "failed" {
                preparationFailure = progress["error"] as? String ?? "This source cannot be prepared."
            } else if let error = incoming["error"] as? String { preparationFailure = error }
        }
        if incoming["error"] == nil { state.removeValue(forKey: "error") }
        publish()
    }
    private var dolbyVisionUnavailableReason: String? {
        let native = state["nativeEnhancement"] as? [String: Any] ?? [:]
        let selected = (state["tracks"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "video" && $0["selected"] as? Bool == true }
        guard native["source-dolby-vision"] as? Bool == true || selected?["dolby-vision-profile"] != nil else { return nil }
        switch native["native-color-path"] as? String {
        case "hdr10-base-layer": return "Playing the HDR10 base layer. Dolby Vision enhancement is unavailable."
        case "hlg-base-layer": return "Playing the HLG base layer. Dolby Vision enhancement is unavailable."
        case "unsupported-dolby-vision": return "This Dolby Vision profile has no supported playback path."
        default: return "Dolby Vision uses native playback. Neural enhancement is unavailable."
        }
    }
    private func updateProcessing() {
        let native = state["nativeEnhancement"] as? [String: Any] ?? [:]
        let progress = native["prepared"] as? [String: Any] ?? [:]
        let error = state["error"] as? String ?? (mode == "prepared" ? preparationFailure : nil) ?? progress["error"] as? String
        let unavailableReason = dolbyVisionUnavailableReason
        let enhancementAvailable = modelURL != nil && unavailableReason == nil
        let effectiveEnabled = enabled && enhancementAvailable
        let available = enhancementAvailable && (state["duration"] as? Double ?? 0) > 0
        let qualified = native["live-qualified"] as? Bool == true
        let buffering = native["buffering"] as? Bool == true
        let preview = native["preview-pending"] as? Bool == true
        let selectedVideo = (state["tracks"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "video" && $0["selected"] as? Bool == true }
        var preparedReason: String?
        if let unavailableReason { preparedReason = unavailableReason }
        else if native["prepared-supported"] as? Bool != true { preparedReason = "This playback core does not support Prepared mode." }
        else if modelURL == nil { preparedReason = "A neural model is required." }
        else if !source.hasPrefix("/") { preparedReason = "Prepared mode requires a local video file." }
        else if !["mp4", "m4v", "mov", "mkv"].contains(URL(fileURLWithPath: source).pathExtension.lowercased()) {
            preparedReason = "Prepared currently supports MP4, M4V, MOV and Matroska containers."
        }
        else if selectedVideo?["id"] as? Int != 1 { preparedReason = "Prepared mode supports the first video track only." }
        else if let preparationFailure { preparedReason = preparationFailure }
        let preparedAvailable = preparedReason == nil
        var modes = available ? (qualified && enabled ? ["adaptive", "live"] : ["adaptive"]) : []
        if preparedAvailable { modes.append("prepared") }
        func ranges(_ key: String) -> [[String: Any]] {
            (progress[key] as? [[String: Any]] ?? []).compactMap { range in
                func seconds(_ key: String) -> Double? {
                    guard let time = range[key] as? [String: Any], let value = time["value"] as? NSNumber,
                          let scale = time["timescale"] as? NSNumber, scale.doubleValue > 0 else { return nil }
                    return value.doubleValue / scale.doubleValue
                }
                guard let start = seconds("start"), let end = seconds("end") else { return nil }
                return ["startSeconds": start, "endSeconds": end]
            }
        }
        var prepared = progress
        prepared["capacityBytes"] = capacityBytes
        prepared["cacheDirectory"] = cacheDirectory.path
        if let preparationFailure { prepared["error"] = preparationFailure }
        prepared["availableRanges"] = ranges("availableRanges")
        prepared["completedRanges"] = ranges("completedRanges")
        state["prepared"] = prepared
        let displayedKind = native["displayed-content-kind"] as? String ?? "unknown"
        var message = "Original HDR playback"
        if effectiveEnabled {
            if mode == "prepared" {
                if progress["configurationState"] as? String == "initializing" || progress.isEmpty {
                    message = "Prepared: checking source and cached ranges…"
                } else if progress["jobState"] as? String == "preparing" {
                    message = "Preparing HDR segments; playback uses committed ranges and original for misses."
                } else if displayedKind == "prepared-enhanced" {
                    message = "Prepared HDR cache playback"
                } else if displayedKind == "prepared-original" {
                    message = "Prepared original HDR frame (zero strength)."
                } else if displayedKind == "original" {
                    message = "Original HDR; this frame has no active prepared enhancement."
                } else { message = "Prepared: ready to start or resume." }
            } else if preview { message = "Original seek preview; enhancing this timestamp…" }
            else if buffering { message = "Adaptive: audio and video paused while enhancement catches up." }
            else if mode == "live" && qualified { message = "Live: current session meets the measured processing deadline." }
            else { message = "Adaptive enhancement; audio and video buffer together when needed." }
        }
        if state["configurationPending"] as? Bool == true { message = state["message"] as? String ?? "Updating processing configuration…" }
        let colorPathLabels = ["native-dolby-vision": "Dolby Vision · Original", "hdr10-base-layer": "HDR10 base layer", "hlg-base-layer": "HLG base layer", "unsupported-dolby-vision": "Unsupported Dolby Vision"]
        state["processing"] = ["mode": mode, "enabled": effectiveEnabled, "strength": strength, "colorStrength": colorStrength,
            "width": width, "height": height, "modelAvailable": modelURL != nil, "liveQualified": qualified, "availableModes": modes,
            "enhancementAvailable": enhancementAvailable, "unavailableReason": unavailableReason ?? "",
            "nativeColorPath": colorPathLabels[native["native-color-path"] as? String ?? ""] ?? "Original HDR",
            "status": error != nil ? "error" : !effectiveEnabled ? "original" : mode == "prepared" ? (progress["jobState"] as? String ?? "initializing") : preview ? "preview" : buffering ? "buffering" : "enhancing",
            "message": error ?? unavailableReason ?? message, "subtitleBrightness": subtitleBrightness,
            "pendingFrames": native["pending-frames"] ?? 0, "completedFrames": native["completed-frames"] ?? 0,
            "completedP95Seconds": native["completed-p95-seconds"] ?? 0,
            "bufferCount": native["buffer-count"] ?? 0, "bufferSeconds": native["buffer-seconds"] ?? 0,
            "comparison": native["comparison"] ?? "enhanced", "displayedContentKind": displayedKind] as [String: Any]
        state["capabilities"] = ["enhancement": enhancementAvailable, "prepared": preparedAvailable, "preparedUnavailableReason": preparedReason ?? "", "pip": false, "sameFrameComparison": native["compare-ready"] as? Bool ?? false,
            "playbackModes": !modes.isEmpty]
    }
    private func publish() { updateProcessing(); onState?(state) }
    private func persist() {
        defaults.set(["enabled": enabled, "strength": strength, "colorStrength": colorStrength, "width": width, "height": height,
            "mode": mode, "volume": state["volume"] as? Double ?? 100, "muted": state["muted"] as? Bool ?? false,
            "subtitleBrightness": subtitleBrightness, "subtitleScale": subtitleScale, "subtitleDelay": subtitleDelay,
            "cacheCapacityGiB": Double(capacityBytes) / 1_073_741_824], forKey: "HDRPlayer.preferences.v1")
    }
}
