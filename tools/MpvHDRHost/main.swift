import Cocoa
import Metal
import QuartzCore

// Built with libmpv/client.h as the bridging header. All libmpv calls, including
// destruction, run off AppKit's main thread; macvk dispatches native work to it.
final class PlaybackWorker: @unchecked Sendable {
    let viewPointer: Int64
    let media: String
    let model: String?
    let seconds: Double
    let processingWidth: Int
    let processingHeight: Int
    let maximumLuminanceRatio: Double
    let diagnostics: [String: String]
    let completed: @Sendable ([String: Any]) -> Void
    private let lock = NSLock()
    private var stopping = false

    init(view: NSView, media: String, model: String?, seconds: Double,
         processingWidth: Int, processingHeight: Int, maximumLuminanceRatio: Double,
         diagnostics: [String: String], completed: @escaping @Sendable ([String: Any]) -> Void) {
        viewPointer = Int64(Int(bitPattern: Unmanaged.passUnretained(view).toOpaque()))
        self.media = media; self.model = model; self.seconds = seconds; self.completed = completed
        self.processingWidth = processingWidth; self.processingHeight = processingHeight
        self.maximumLuminanceRatio = maximumLuminanceRatio; self.diagnostics = diagnostics
    }
    func stop() { lock.lock(); stopping = true; lock.unlock() }
    func shouldStop() -> Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    func run() {
        guard let mpv = mpv_create() else { completed(["error": "mpv_create failed"]); return }
        var report: [String: Any] = ["source": media, "model": model ?? "none", "vo": "gpu-next", "gpuContext": "macvk", "requestedSeconds": seconds,
            "avOffsetMeasurement": "includes startup, looping, exact seeks and pause/resume; maximum is not a steady-state synchronization qualification"]
        var errors: [String] = [], logs: [String] = []
        var filterOptions = "processing-width=\(processingWidth):processing-height=\(processingHeight):maximum-luminance-ratio=\(maximumLuminanceRatio):reference-white=203:bypass=no"
        for key in diagnostics.keys.sorted() { filterOptions += ":\(key)=\(diagnostics[key]!)" }
        let filter = model.map { "metal-hdr=model=\($0):strength=1:\(filterOptions)" }
            ?? "metal-hdr=strength=0:\(filterOptions)"
        report["filter"] = filter
        let settings = ["config": "no", "vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "macvk",
            "wid": String(viewPointer), "hwdec": "videotoolbox", "ao": "null", "keep-open": "yes",
            "loop-file": "inf", "vf": filter, "target-colorspace-hint": "yes", "input-default-bindings": "no",
            "input-vo-keyboard": "no", "osc": "no", "osd-level": "0", "msg-level": "all=warn"]
        for (key, value) in settings {
            let result = mpv_set_option_string(mpv, key, value)
            if result < 0 { errors.append("\(key): \(String(cString: mpv_error_string(result)))") }
        }
        let initialized = mpv_initialize(mpv)
        if initialized < 0 {
            errors.append("initialize: \(String(cString: mpv_error_string(initialized)))")
        } else {
            mpv_request_log_messages(mpv, "debug")
            let command = "loadfile \"\(media.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
            let loaded = mpv_command_string(mpv, command)
            if loaded < 0 { errors.append("loadfile: \(String(cString: mpv_error_string(loaded)))") }
            let start = Date()
            var actions: Set<Int> = []
            var offsets: [Double] = []
            var presented = 0
            while !shouldStop() && Date().timeIntervalSince(start) < seconds {
                let elapsed = Date().timeIntervalSince(start)
                if let event = mpv_wait_event(mpv, 0.03)?.pointee {
                    if event.event_id == MPV_EVENT_LOG_MESSAGE, let data = event.data {
                        let log = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                        let text = "[\(String(cString: log.prefix))] \(String(cString: log.text))".trimmingCharacters(in: .whitespacesAndNewlines)
                        if logs.count < 400 && (text.contains("Metal layer") || text.contains("metal-hdr") || text.contains("Vulkan") || text.contains("surface") || text.contains("error")) { logs.append(text) }
                    }
                    if event.event_id == MPV_EVENT_PLAYBACK_RESTART { presented += 1 }
                    if event.event_id == MPV_EVENT_SHUTDOWN { break }
                }
                for (key, deadline, action) in [(1, 1.0, "seek 0.7 absolute+exact"), (2, 2.0, "set pause yes"), (3, 2.3, "set pause no"), (4, 3.5, "seek 0.2 absolute+exact")] {
                    if elapsed >= deadline && !actions.contains(key) {
                        let result = mpv_command_string(mpv, action)
                        if result < 0 { errors.append("\(action): \(String(cString: mpv_error_string(result)))") }
                        actions.insert(key)
                    }
                }
                var offset: Double = 0
                if mpv_get_property(mpv, "avsync", MPV_FORMAT_DOUBLE, &offset) >= 0 && offset.isFinite { offsets.append(offset) }
            }
            for property in ["video-out-params", "video-out-params/pixelformat", "video-out-params/primaries", "video-out-params/gamma", "video-out-params/sig-peak", "video-params", "video-dec-params", "frame-drop-count", "decoder-frame-drop-count", "estimated-vf-fps", "time-pos", "pause", "track-list", "vo-configured"] {
                if let value = mpv_get_property_string(mpv, property) {
                    report[property] = String(cString: value); mpv_free(value)
                }
            }
            report["playbackRestarts"] = presented
            report["avOffsetSamples"] = offsets.count
            report["avOffsetMaximumAbsoluteSeconds"] = offsets.map(abs).max().map { $0 as Any } ?? NSNull()
            report["actions"] = actions.sorted()
        }
        mpv_terminate_destroy(mpv)
        report["errors"] = errors; report["logs"] = logs
        report["evidence"] = "in-process embedded macvk surface and playback lifecycle; not physical HDR display accuracy or M5 performance"
        completed(report)
    }
}

@MainActor
final class HostDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var container: NSView!
    var worker: PlaybackWorker?
    var snapshots: [[String: Any]] = []
    var timer: Timer?
    var finished = false
    let started = Date()
    let args = Array(CommandLine.arguments.dropFirst())
    func option(_ key: String) -> String? {
        guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let media = args.first, !media.hasPrefix("--") else {
            fputs("usage: MpvHDRHost MEDIA [--model PACKAGE] [--seconds 8] [--report FILE] [--fullscreen]\n", stderr)
            finished = true; NSApp.terminate(nil); return
        }
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Native mpv HDR host"
        window.isReleasedWhenClosed = false; window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        container = NSView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(container)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        worker = PlaybackWorker(view: container, media: URL(fileURLWithPath: media).standardized.path,
            model: option("--model"), seconds: Double(option("--seconds") ?? "8") ?? 8,
            processingWidth: Int(option("--processing-width") ?? "32") ?? 32,
            processingHeight: Int(option("--processing-height") ?? "24") ?? 24,
            maximumLuminanceRatio: Double(option("--max-luminance-ratio") ?? "2") ?? 2,
            diagnostics: Dictionary(uniqueKeysWithValues: ["engine-report", "measurement-config", "measurements"].compactMap { key in
                option("--" + key).map { (key, $0) }
            })) { [weak self] report in
                DispatchQueue.main.async { self?.finish(report) }
            }
        let playback = worker!
        DispatchQueue.global(qos: .userInitiated).async { playback.run() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.snapshot() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.window.setContentSize(NSSize(width: 800, height: 500)) }
        if args.contains("--fullscreen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in self?.window.toggleFullScreen(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in self?.window.toggleFullScreen(nil) }
        }
    }
    func snapshot() {
        var snapshot: [String: Any] = ["elapsed": Date().timeIntervalSince(started), "windowCount": NSApp.windows.filter { $0.isVisible }.count,
            "childViews": container.subviews.count, "hostWidth": container.bounds.width, "hostHeight": container.bounds.height,
            "fullscreen": window.styleMask.contains(.fullScreen), "currentHeadroom": window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1]
        let visibleWindows = NSApp.windows.filter { $0.isVisible }
        snapshot["visibleWindowClasses"] = visibleWindows.map { NSStringFromClass(type(of: $0)) }
        snapshot["rendererOwnedWindows"] = visibleWindows.filter { NSStringFromClass(type(of: $0)).hasSuffix(".Window") }.count
        if let child = container.subviews.first, let layer = child.layer as? CAMetalLayer {
            snapshot["pixelFormat"] = layer.pixelFormat.rawValue
            snapshot["extendedRange"] = layer.wantsExtendedDynamicRangeContent
            snapshot["colorSpace"] = layer.colorspace?.name as String? ?? "unavailable"
            snapshot["drawableWidth"] = layer.drawableSize.width; snapshot["drawableHeight"] = layer.drawableSize.height
            snapshot["childWidth"] = child.bounds.width; snapshot["childHeight"] = child.bounds.height
            snapshot["contentsScale"] = layer.contentsScale
        }
        snapshots.append(snapshot)
    }
    func finish(_ result: [String: Any]) {
        finished = true; timer?.invalidate()
        var result = result
        result["surfaceSnapshots"] = snapshots
        result["childrenAfterTeardown"] = container.subviews.count
        result["hostWindowStillVisibleAfterTeardown"] = window.isVisible
        let observedSurface = snapshots.contains { ($0["extendedRange"] as? Bool) == true && ($0["childViews"] as? Int) == 1 }
        let leakedWindow = snapshots.contains { ($0["rendererOwnedWindows"] as? Int ?? 0) > 0 }
        let resizedSurface = snapshots.contains { row in
            guard let width = row["hostWidth"] as? CGFloat, let child = row["childWidth"] as? CGFloat,
                  let scale = row["contentsScale"] as? CGFloat, let drawable = row["drawableWidth"] as? CGFloat else { return false }
            return width >= 799 && abs(child - width) < 1 && abs(drawable - width * scale) < 2
        }
        result["resizedSurfaceMatchedHost"] = resizedSurface
        let failures = result["errors"] as? [String] ?? []
        let passed = failures.isEmpty && observedSurface && resizedSurface && !leakedWindow && container.subviews.isEmpty && window.isVisible
        result["passed"] = passed
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            if let path = option("--report") { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
            else { FileHandle.standardOutput.write(data) }
        } catch { fputs("report error: \(error)\n", stderr) }
        if !passed { exit(1) }
        NSApp.terminate(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { worker?.stop(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if finished { return .terminateNow }
        worker?.stop(); return .terminateCancel
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { HostDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
