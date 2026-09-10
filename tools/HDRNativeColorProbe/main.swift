import AppKit
import CoreVideo
import Metal
import QuartzCore

// Diagnostic host only. Uses the existing public exporter and runtime target
// options; it never changes the playback filter or opens a PiP window.
struct ProbeFailure: Error { let message: String }
func require(_ value: Bool, _ message: String) throws {
    if !value { throw ProbeFailure(message: message) }
}
func writeJSON(_ value: Any, to path: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: path, options: .atomic)
}

final class NativeColorProbe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var host: NSView!
    var finished = false
    let args = CommandLine.arguments
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard args.count == 4 || (args.count == 5 && ["--metadata-control", "--scale-control"].contains(args[4])) else {
            fputs("usage: HDRNativeColorProbe SOURCE MODEL NEW_OUTPUT [--metadata-control|--scale-control]\n", stderr); exit(2)
        }
        window = NSWindow(contentRect: NSRect(x: 180, y: 200, width: 1060, height: 524),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "HDR native color diagnostic"
        window.isReleasedWhenClosed = false
        host = NSView(frame: NSRect(x: 0, y: 0, width: 1060, height: 524))
        window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let pointer = Int64(Int(bitPattern: Unmanaged.passUnretained(host).toOpaque()))
        DispatchQueue.global(qos: .userInitiated).async { self.run(pointer) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finished ? .terminateNow : .terminateCancel
    }
    @MainActor func surface() -> [String: Any] {
        var result: [String: Any] = ["windowID": window.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier,
            "visible": window.isVisible, "occlusionVisible": window.occlusionState.contains(.visible),
            "miniaturized": window.isMiniaturized, "appActive": NSApp.isActive,
            "contentBounds": PiPBufferSnapshot.rect(host.bounds), "backingScale": window.backingScaleFactor]
        if let layer = host.subviews.first?.layer as? CAMetalLayer {
            result["metalLayer"] = ["pixelFormat": layer.pixelFormat.rawValue,
                "colorspace": layer.colorspace.map { PiPBufferSnapshot.json($0) } ?? NSNull(),
                "wantsExtendedDynamicRangeContent": layer.wantsExtendedDynamicRangeContent,
                "edrMetadata": layer.edrMetadata.map { String(describing: $0) } ?? "none",
                "drawableSize": [layer.drawableSize.width, layer.drawableSize.height],
                "contentsScale": layer.contentsScale, "contentsRect": PiPBufferSnapshot.rect(layer.contentsRect)]
        }
        if let screen = window.screen {
            result["screen"] = ["currentHeadroom": screen.maximumExtendedDynamicRangeColorComponentValue,
                "potentialHeadroom": screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                "referenceHeadroom": screen.maximumReferenceExtendedDynamicRangeColorComponentValue]
        }
        return result
    }
    func run(_ view: Int64) {
        let output = URL(fileURLWithPath: args[3], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            fputs("Refusing an existing output directory\n", stderr)
            DispatchQueue.main.async { self.finished = true; NSApp.terminate(nil) }
            return
        }
        var result: [String: Any] = ["passed": false, "scope": "Same retained frame under runtime target-peak controls; native compositor capture is separate from mpv screenshot conversion and physical display luminance"]
        var client: OpaquePointer?, exporter: OpaquePointer?, held: OpaquePointer?
        func command(_ values: [String]) throws {
            let text = values.map { strdup($0) }; defer { text.forEach { free($0) } }
            var pointers = text.map { UnsafePointer<CChar>($0) } + [nil]
            let code = pointers.withUnsafeMutableBufferPointer { mpv_command(client, $0.baseAddress) }
            try require(code >= 0, "command \(values): \(String(cString: mpv_error_string(code)))")
        }
        func property(_ key: String) -> Any {
            guard let value = mpv_get_property_string(client, key) else { return NSNull() }
            defer { mpv_free(value) }
            let text = String(cString: value)
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? text
        }
        func poll() -> (mpv_hdr_status, mpv_hdr_snapshot, OpaquePointer?) {
            var snapshot = mpv_hdr_snapshot(); snapshot.struct_size = UInt32(MemoryLayout<mpv_hdr_snapshot>.size)
            snapshot.abi_version = UInt32(MPV_HDR_EXPORT_ABI_VERSION)
            var frame: OpaquePointer?
            let status = mpv_hdr_export_poll(exporter, 0, &snapshot, &frame)
            return (status, snapshot, frame)
        }
        func identity(_ value: mpv_hdr_snapshot) -> [String: Any] {
            ["generation": value.generation, "revision": value.revision,
             "sourcePTS": ["value": value.source_pts.value, "timescale": value.source_pts.timescale],
             "contentKind": value.content_kind, "rate": value.rate, "hostTicks": value.host_ticks,
             "pendingFrames": value.producer_pending_frames, "outstandingLeases": value.outstanding_leases]
        }
        func next(at seconds: Double? = nil) throws -> (mpv_hdr_snapshot, OpaquePointer) {
            let deadline = CACurrentMediaTime() + 25
            while CACurrentMediaTime() < deadline {
                let (status, snapshot, frame) = poll()
                if let frame {
                    if status == MPV_HDR_FRAME_READY && snapshot.content_kind == 2 &&
                        snapshot.rate == 0 && (seconds == nil || abs(Double(snapshot.source_pts.value) / Double(snapshot.source_pts.timescale) - seconds!) < 1e-8) {
                        return (snapshot, frame)
                    }
                    mpv_hdr_frame_release(frame)
                }
                _ = mpv_wait_event(client, 0.01)
            }
            throw ProbeFailure(message: "No selected enhanced paused frame; \(property("enhancement-state"))")
        }
        do {
            try require(!FileManager.default.fileExists(atPath: output.path), "Output directory already exists")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            client = mpv_create(); try require(client != nil, "mpv_create")
            let options = ["config": "no", "vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "macvk",
                "wid": String(view), "hwdec": "videotoolbox", "ao": "coreaudio", "mute": "yes", "pause": "yes",
                "sid": "no", "secondary-sid": "no", "keep-open": "yes", "target-colorspace-hint": "yes",
                "osc": "no", "osd-level": "0", "input-default-bindings": "no", "input-vo-keyboard": "no",
                "screenshot-format": "png", "screenshot-high-bit-depth": "yes", "screenshot-tag-colorspace": "yes",
                "log-file": output.appendingPathComponent("mpv.log").path, "msg-level": "all=v",
                "vf": "@enhance:metal-hdr=model=%\(args[2].utf8.count)%\(args[2]):processing-width=32:processing-height=24:strength=1:colour-strength=1:maximum-luminance-ratio=2:reference-white=203:policy=adaptive"]
            result["options"] = options
            for (key, value) in options { try require(mpv_set_option_string(client, key, value) >= 0, "option \(key)") }
            try require(mpv_initialize(client) >= 0, "mpv_initialize")
            try require(mpv_hdr_export_open(client, 2, &exporter) == MPV_HDR_FRAME_READY, "export open")
            try command(["loadfile", args[1]])
            let (_, initial) = try next(); mpv_hdr_frame_release(initial)
            try command(["seek", "20", "absolute+exact"])
            let (selected, retained) = try next(at: 20); held = retained
            let descriptor = mpv_hdr_frame_get(retained)!.pointee
            let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(descriptor.pixel_buffer!).takeUnretainedValue()
            let metadataControl = args.contains("--metadata-control")
            let scaleControl = args.contains("--scale-control")
            var originalMetadata: CAEDRMetadata?
            DispatchQueue.main.sync { originalMetadata = (self.host.subviews.first?.layer as? CAMetalLayer)?.edrMetadata }
            if metadataControl { try require(originalMetadata != nil, "No initial layer metadata to isolate") }
            let cases = scaleControl ? [("scale1", "1000"), ("scale203", "1000"), ("scale1-repeat", "1000")]
                : metadataControl ? [("metadata-original", "1000"), ("metadata-cleared", "1000"), ("metadata-restored", "1000")]
                : [("auto", "auto"), ("peak1000", "1000"), ("auto-repeat", "auto")]
            var phases: [[String: Any]] = []
            for (name, peak) in cases {
                var apiCalls: [[String: Any]] = []
                let directory = output.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try command(["set", "target-peak", peak])
                let settle = CACurrentMediaTime() + 0.4
                while CACurrentMediaTime() < settle { _ = mpv_wait_event(client, 0.01) }
                if metadataControl {
                    DispatchQueue.main.sync {
                        (self.host.subviews.first?.layer as? CAMetalLayer)?.edrMetadata = name == "metadata-cleared" ? nil : originalMetadata
                        CATransaction.flush()
                    }
                    let metadataSettle = CACurrentMediaTime() + 0.3
                    while CACurrentMediaTime() < metadataSettle { _ = mpv_wait_event(client, 0.01) }
                }
                if scaleControl {
                    let scale: Float = name == "scale203" ? 203 : 1
                    let minNits: Float = 0, maxNits: Float = 1018.656982421875
                    DispatchQueue.main.sync {
                        (self.host.subviews.first?.layer as? CAMetalLayer)?.edrMetadata = .hdr10(minLuminance: minNits, maxLuminance: maxNits, opticalOutputScale: scale)
                        apiCalls.append(["api": "CAMetalLayer.edrMetadata = CAEDRMetadata.hdr10(minLuminance:maxLuminance:opticalOutputScale:)",
                            "minLuminance": minNits, "maxLuminance": maxNits, "opticalOutputScale": scale, "hostSeconds": CACurrentMediaTime()])
                        CATransaction.flush()
                    }
                    // Force a fresh VO draw with public render geometry options.
                    // Return to exact original geometry before capture; the
                    // filter, selected frame and inference count stay fixed.
                    for pan in ["0.0001", "0"] {
                        try command(["set", "video-pan-x", pan])
                        apiCalls.append(["api": "mpv_command", "arguments": ["set", "video-pan-x", pan], "hostSeconds": CACurrentMediaTime()])
                        let redraw = CACurrentMediaTime() + 0.25
                        while CACurrentMediaTime() < redraw { _ = mpv_wait_event(client, 0.01) }
                    }
                }
                try require(mpv_hdr_frame_is_current(retained) != 0, "Retained frame changed")
                let (now, current) = try next(at: 20)
                defer { mpv_hdr_frame_release(current) }
                try require(now.generation == selected.generation && now.revision == selected.revision, "Target change changed selected frame identity")
                let currentBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(mpv_hdr_frame_get(current)!.pointee.pixel_buffer!).takeUnretainedValue()
                var phase: [String: Any] = ["name": name, "requestedTargetPeak": peak, "identity": identity(now), "hostSeconds": CACurrentMediaTime()]
                phase["diagnosticAPICalls"] = apiCalls
                for propertyName in ["target-peak", "target-trc", "target-prim", "hdr-reference-white", "video-params", "video-out-params", "video-target-params", "enhancement-state"] {
                    phase[propertyName] = property(propertyName)
                }
                var mainError: Error?
                DispatchQueue.main.sync {
                    do {
                        phase["surface"] = self.surface()
                        phase["exported"] = try PiPBufferSnapshot.write(currentBuffer, name: "exported", directory: directory)
                    } catch { mainError = error }
                }
                if let mainError { throw mainError }
                try writeJSON(phase, to: directory.appendingPathComponent("ready.json"))
                print("READY \(name)"); fflush(stdout)
                let deadline = CACurrentMediaTime() + 25
                while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("capture-complete").path) {
                    try require(CACurrentMediaTime() < deadline, "Capture deadline exceeded for \(name)")
                    _ = mpv_wait_event(client, 0.02)
                }
                // gpu-next screenshot uses a separate UNORM render target and
                // clears linear source max_luma. Keep it as a diagnostic only.
                try command(["screenshot-to-file", directory.appendingPathComponent("mpv-window.png").path, "window"])
                phase["identityAfter"] = identity(now)
                phase["leaseCurrentAfter"] = mpv_hdr_frame_is_current(retained) != 0
                phase["stateAfter"] = property("enhancement-state")
                phases.append(phase)
                try writeJSON(phase, to: directory.appendingPathComponent("phase.json"))
            }
            result["phases"] = phases; result["passed"] = true
            withExtendedLifetime(buffer) {}
        } catch { result["error"] = String(describing: error) }
        if let held { mpv_hdr_frame_release(held) }
        if let exporter { mpv_hdr_export_close(exporter) }
        if let client { mpv_terminate_destroy(client) }
        try? writeJSON(result, to: output.appendingPathComponent("session.json"))
        DispatchQueue.main.async { self.finished = true; NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = NativeColorProbe()
app.delegate = delegate
app.run()
