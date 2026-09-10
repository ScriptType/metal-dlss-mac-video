import AppKit
import CoreVideo
import Metal
import QuartzCore

// Separate diagnostic host: observe the normal native display path. No target
// peak, layer metadata, colours, screen settings, or algorithm overrides.
struct TransitionFailure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw TransitionFailure(message: message) }
}
func writeJSON(_ value: Any, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        .write(to: url, options: .atomic)
}
struct InputTime: Decodable { let value: Int64, timescale: Int32 }
struct Configuration: Decodable {
    let sourcePath: String, modelPath: String, outputPath: String
    let sourcePTS: Int64, sourceDuration: Int64, timescale: Int32
    let formatStartSeconds: Double
    let firstVideoPTS: InputTime
    let lastVideoPTS: InputTime
    let expectedMetadata: [String: Double]
    let lastFrameMetadata: [String: Double]
    let processingWidth: Int, processingHeight: Int
    let metadataOnly: Bool
}

final class SourceTransitionProbe: NSObject, NSApplicationDelegate {
    var window: NSWindow!, host: NSView!
    var finished = false
    var exitCode: Int32 = 1
    let configuration: Configuration
    init(_ configuration: Configuration) { self.configuration = configuration }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 200, width: 960, height: 540),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "HDR source transition diagnostic"
        window.isReleasedWhenClosed = false
        host = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        window.contentView = host
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let address = Int64(Int(bitPattern: Unmanaged.passUnretained(host).toOpaque()))
        DispatchQueue.global(qos: .userInitiated).async { self.run(address) }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finished ? .terminateNow : .terminateCancel
    }
    @MainActor func surface() -> [String: Any] {
        var result: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "windowID": window.windowNumber, "visible": window.isVisible,
            "occlusionVisible": window.occlusionState.contains(.visible), "miniaturized": window.isMiniaturized,
            "onActiveSpace": window.isOnActiveSpace, "appActive": NSApp.isActive,
            "windowFrame": PiPBufferSnapshot.rect(window.frame), "hostBounds": PiPBufferSnapshot.rect(host.bounds),
            "hostFrameInWindow": PiPBufferSnapshot.rect(host.convert(host.bounds, to: nil)),
            "backingScale": window.backingScaleFactor, "hostSeconds": CACurrentMediaTime()]
        if let layer = host.subviews.first?.layer as? CAMetalLayer {
            result["metalLayer"] = ["pixelFormat": layer.pixelFormat.rawValue,
                "colorspace": layer.colorspace.map { PiPBufferSnapshot.json($0) } ?? NSNull(),
                "edrMetadata": layer.edrMetadata.map { String(describing: $0) } ?? "none",
                "wantsExtendedDynamicRangeContent": layer.wantsExtendedDynamicRangeContent,
                "drawableSize": [layer.drawableSize.width, layer.drawableSize.height],
                "frame": PiPBufferSnapshot.rect(layer.frame), "bounds": PiPBufferSnapshot.rect(layer.bounds),
                "contentsRect": PiPBufferSnapshot.rect(layer.contentsRect), "contentsScale": layer.contentsScale]
        }
        if let screen = window.screen {
            result["screen"] = ["frame": PiPBufferSnapshot.rect(screen.frame),
                "currentHeadroom": screen.maximumExtendedDynamicRangeColorComponentValue,
                "potentialHeadroom": screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                "referenceHeadroom": screen.maximumReferenceExtendedDynamicRangeColorComponentValue]
        }
        if let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            let keys = [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowLayer, kCGWindowBounds, kCGWindowAlpha, kCGWindowIsOnscreen].map { $0 as String }
            result["onScreenWindowStackWithoutTitles"] = rows.prefix(32).map { row in
                Dictionary(uniqueKeysWithValues: keys.compactMap { key in row[key].map { (key, $0) } })
            }
        }
        return result
    }
    func run(_ address: Int64) {
        let c = configuration, output = URL(fileURLWithPath: configuration.outputPath, isDirectory: true)
        var client: OpaquePointer?, exporter: OpaquePointer?, retained: OpaquePointer?
        var phases: [[String: Any]] = [], checks: [String] = []
        var result: [String: Any] = ["passed": false, "schemaVersion": 1,
            "metadataOnly": c.metadataOnly,
            "scope": "One source frame, native metadata transition and exact retained comparison; no physical luminance, HDR10+ display accuracy, or real-time qualification"]
        var maximumLeases: UInt32 = 0
        var expectedDecoderPTS = c.sourcePTS
        func check(_ value: Bool, _ message: String) throws { try require(value, message); checks.append(message) }
        func command(_ values: [String]) throws {
            let strings = values.map { strdup($0) }; defer { strings.forEach { free($0) } }
            var pointers = strings.map { UnsafePointer<CChar>($0) } + [nil]
            let code = pointers.withUnsafeMutableBufferPointer { mpv_command(client, $0.baseAddress) }
            try require(code >= 0, "Command \(values): \(String(cString: mpv_error_string(code)))")
        }
        func property(_ name: String) -> Any {
            guard let value = mpv_get_property_string(client, name) else { return NSNull() }
            defer { mpv_free(value) }; let text = String(cString: value)
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? text
        }
        func poll(afterRevision: UInt64 = 0) -> (mpv_hdr_status, mpv_hdr_snapshot, OpaquePointer?) {
            var s = mpv_hdr_snapshot(); s.struct_size = UInt32(MemoryLayout<mpv_hdr_snapshot>.size)
            s.abi_version = UInt32(MPV_HDR_EXPORT_ABI_VERSION)
            var frame: OpaquePointer?
            let status = mpv_hdr_export_poll(exporter, afterRevision, &s, &frame)
            maximumLeases = max(maximumLeases, s.outstanding_leases)
            return (status, s, frame)
        }
        func identity(_ s: mpv_hdr_snapshot, filePTS: Int64) -> [String: Any] {
            ["streamEpoch": s.stream_epoch, "generation": s.generation, "revision": s.revision,
             "originalFilePTS": ["value": filePTS, "timescale": c.timescale],
             "decoderPTS": ["value": s.source_pts.value, "timescale": s.source_pts.timescale],
             "decoderDuration": ["value": s.source_duration.value, "timescale": s.source_duration.timescale],
             "playerPTSSeconds": s.player_pts_seconds, "decoderToPlayerSeconds": s.source_to_player_seconds,
             "exporterTimingSemantics": "ABI source_pts is decoder-native after demux packet offset; source_to_player is decoder-to-player",
             "contentKind": s.content_kind, "supported": s.supported, "reason": s.reason,
             "rate": s.rate, "clockValid": s.clock_valid, "clockSource": s.clock_source,
             "mediaSeconds": s.media_seconds, "hostTicks": s.host_ticks, "userPaused": s.user_paused,
             "buffering": s.buffering, "pendingFrames": s.producer_pending_frames,
             "outstandingLeases": s.outstanding_leases, "producerPoolCapacity": s.producer_pool_capacity]
        }
        func isTarget(_ s: mpv_hdr_snapshot) -> Bool {
            s.source_pts.timescale > 0 &&
                Decimal(s.source_pts.value) * Decimal(c.timescale) == Decimal(expectedDecoderPTS) * Decimal(s.source_pts.timescale)
        }
        func waitFor(_ enhanced: Bool, target: Bool = true) throws -> (mpv_hdr_snapshot, OpaquePointer?) {
            let deadline = CACurrentMediaTime() + 30
            while CACurrentMediaTime() < deadline {
                let (status, s, frame) = poll()
                let params = property("video-out-params") as? [String: Any] ?? [:]
                let match = enhanced ? status == MPV_HDR_FRAME_READY && s.content_kind == 2 && params["gamma"] as? String == "linear"
                    : status == MPV_HDR_UNSUPPORTED && s.reason == UInt32(MPV_HDR_REASON_FORMAT.rawValue) && params["gamma"] as? String == "pq"
                if match && s.user_paused == 1 && (!target || isTarget(s)) { return (s, frame) }
                if let frame { mpv_hdr_frame_release(frame) }
                _ = mpv_wait_event(client, 0.01)
            }
            throw TransitionFailure(message: "No \(enhanced ? "enhanced" : "original PQ") selected target: \(property("enhancement-state"))")
        }
        func settle() { let end = CACurrentMediaTime() + 0.25; while CACurrentMediaTime() < end { _ = mpv_wait_event(client, 0.01) } }
        func capture(_ name: String, enhanced: Bool, offset: Double,
                     filePTS: Int64? = nil, metadata: [String: Double]? = nil) throws -> (mpv_hdr_snapshot, [String: Any]) {
            settle()
            let (selected, frame) = try waitFor(enhanced)
            defer { if let frame { mpv_hdr_frame_release(frame) } }
            let decoderSeconds = Double(selected.source_pts.value) / Double(selected.source_pts.timescale)
            try require(selected.source_to_player_seconds.isFinite && selected.player_pts_seconds.isFinite &&
                abs(selected.source_to_player_seconds - offset) <= 1e-8 &&
                abs(selected.player_pts_seconds - (decoderSeconds + offset)) <= 1e-8,
                "Selected decoder/player timestamp pair disagrees with exporter mapping")
            var phase: [String: Any] = ["name": name, "identity": identity(selected, filePTS: filePTS ?? c.sourcePTS)]
            for key in ["video-params", "video-out-params", "video-target-params", "enhancement-state", "demuxer-start-time", "rebase-start-time", "target-peak", "target-trc", "target-prim", "hdr-reference-white"] { phase[key] = property(key) }
            let directory = output.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            var mainError: Error?
            DispatchQueue.main.sync {
                phase["surface"] = self.surface()
                if let frame, let descriptor = mpv_hdr_frame_get(frame)?.pointee, let pixel = descriptor.pixel_buffer {
                    do {
                        phase["sourcePath"] = descriptor.source_path.map { String(cString: $0) } ?? ""
                        try require(phase["sourcePath"] as? String == c.sourcePath, "Export source identity differs from the opened pinned file")
                        phase["exported"] = try PiPBufferSnapshot.write(Unmanaged<CVPixelBuffer>.fromOpaque(pixel).takeUnretainedValue(), name: "exported", directory: directory)
                    } catch { mainError = error }
                }
            }
            if let mainError { throw mainError }
            // Snapshot only: retained reference + this phase's lease already
            // occupy the two-slot consumer budget. Do not ask for a third.
            let (afterStatus, after, duplicate) = poll(afterRevision: selected.revision)
            if let duplicate { mpv_hdr_frame_release(duplicate) }
            try require(duplicate == nil && afterStatus == (enhanced ? MPV_HDR_UNCHANGED : MPV_HDR_UNSUPPORTED),
                "Unexpected status in snapshot-only consistency check: \(afterStatus)")
            try require(after.revision == selected.revision && after.stream_epoch == selected.stream_epoch && isTarget(after), "Selection changed during metadata/readback snapshot")
            if let frame { try require(mpv_hdr_frame_is_current(frame) != 0, "Export became stale during readback") }
            let params = phase["video-out-params"] as? [String: Any] ?? [:]
            for (key, expected) in metadata ?? c.expectedMetadata {
                if enhanced { try require(params[key] == nil, "Reconstructed RGB retained source dynamic field \(key)") }
                else { try require((params[key] as? Double).map { abs($0 - expected) <= max(0.0001, abs(expected) * 2e-6) } == true, "Original dynamic field \(key) differs from exact source frame") }
            }
            try writeJSON(phase, directory.appendingPathComponent("ready.json"))
            phases.append(phase)
            return (selected, phase)
        }
        do {
            try require(!FileManager.default.fileExists(atPath: output.path), "Output already exists")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            client = mpv_create(); try require(client != nil, "mpv_create")
            let options = ["config": "no", "vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "macvk",
                "wid": String(address), "hwdec": "videotoolbox", "ao": "coreaudio", "mute": "yes", "pause": "yes",
                "sid": "no", "secondary-sid": "no", "keep-open": "yes", "target-colorspace-hint": "yes",
                "osc": "no", "osd-level": "0", "input-default-bindings": "no", "input-vo-keyboard": "no",
                "log-file": output.appendingPathComponent("mpv.log").path, "msg-level": "all=v",
                "vf": "@enhance:metal-hdr=model=%\(c.modelPath.utf8.count)%\(c.modelPath):processing-width=\(c.processingWidth):processing-height=\(c.processingHeight):strength=1:colour-strength=1:maximum-luminance-ratio=2:reference-white=203:policy=adaptive:bypass=yes:engine-report=%\(output.appendingPathComponent("engine.json").path.utf8.count)%\(output.appendingPathComponent("engine.json").path)"]
            result["options"] = options
            for (key, value) in options { try require(mpv_set_option_string(client, key, value) >= 0, "Option \(key)") }
            try require(mpv_initialize(client) >= 0, "mpv_initialize")
            try require(mpv_hdr_export_open(client, 2, &exporter) == MPV_HDR_FRAME_READY, "Exporter open")
            try command(["loadfile", c.sourcePath]); let (initial, unused) = try waitFor(false, target: false)
            if let unused { mpv_hdr_frame_release(unused) }
            guard let demuxerStart = property("demuxer-start-time") as? Double else { throw TransitionFailure(message: "Missing demuxer start") }
            var rebased: Int32 = 0
            try require(mpv_get_property(client, "rebase-start-time", MPV_FORMAT_FLAG, &rebased) >= 0, "Missing rebase policy")
            // mpv changes packet timestamps BEFORE decoding. ABI source_pts
            // therefore lives on the native decoder timeline, not necessarily
            // the original file's timeline. Keep that packet offset distinct
            // from the exporter's independently observed decoder/player offset.
            let packetOffsetSeconds = rebased != 0 ? -demuxerStart : 0
            let ticks = packetOffsetSeconds * Double(c.timescale)
            try require(ticks.isFinite && ticks.rounded() > Double(Int64.min) && ticks.rounded() < Double(Int64.max) &&
                abs(ticks - ticks.rounded()) < 1e-6,
                "Demux packet offset is not exactly representable in pinned source ticks")
            let packetOffsetTicks = Int64(ticks.rounded())
            let target = c.sourcePTS.addingReportingOverflow(packetOffsetTicks)
            let first = c.firstVideoPTS.value.addingReportingOverflow(packetOffsetTicks)
            try require(!target.overflow && !first.overflow, "Native timestamp addition overflow")
            expectedDecoderPTS = target.partialValue
            let offset = initial.source_to_player_seconds
            try check(demuxerStart.isFinite && initial.source_pts.timescale > 0 &&
                offset.isFinite && initial.player_pts_seconds.isFinite &&
                Decimal(initial.source_pts.value) * Decimal(c.timescale) == Decimal(first.partialValue) * Decimal(initial.source_pts.timescale) &&
                abs(initial.player_pts_seconds - (Double(initial.source_pts.value) / Double(initial.source_pts.timescale) + offset)) <= 1e-8,
                "Initial file/decoder/player timestamps verify separate demux and exporter mappings")
            result["timelineMapping"] = ["ffprobeFormatStartSeconds": c.formatStartSeconds,
                "nativeDemuxerStartSeconds": demuxerStart, "nativeRebaseStartTime": rebased != 0,
                "demuxPacketOffset": ["value": packetOffsetTicks, "timescale": c.timescale],
                "observedDecoderToPlayerSeconds": offset,
                "heldInitialIdentity": identity(initial, filePTS: c.firstVideoPTS.value),
                "timePosAtObservation": property("time-pos"),
                "scope": "File inventory + exact demux packet offset = decoder-native PTS; exporter separately maps decoder PTS to player PTS"]
            let playerTarget = Double(expectedDecoderPTS) / Double(c.timescale) + offset
            result["decoderToPlayerSeconds"] = offset; result["playerSeekSeconds"] = playerTarget
            try command(["seek", String(format: "%.12f", playerTarget), "absolute+exact"])
            let (_, original) = try capture("original-pq", enhanced: false, offset: offset)
            let originalState = original["enhancement-state"] as? [String: Any] ?? [:]
            try check(originalState["submitted-frames"] as? Int == 0, "Native original PQ reaches selected target without neural submissions")
            try command(["vf-command", "enhance", "bypass", "no"])
            try command(["seek", String(format: "%.12f", playerTarget), "absolute+exact"])
            let (firstEnhanced, frame) = try waitFor(true); retained = frame
            try require(frame != nil, "Missing enhanced lease")
            let (enhanced, enhancedPhase) = try capture("enhanced", enhanced: true, offset: offset)
            let state = enhancedPhase["enhancement-state"] as? [String: Any] ?? [:]
            try check(state["compare-ready"] as? Bool == true && enhanced.content_kind == 2, "Actual neural output has an exact retained comparison pair")
            try check(enhanced.source_duration.timescale > 0 &&
                Decimal(enhanced.source_duration.value) * Decimal(c.timescale) == Decimal(c.sourceDuration) * Decimal(enhanced.source_duration.timescale), "Completed output preserves exact source duration")
            try command(["vf-command", "enhance", "compare", "original"])
            let (back, backPhase) = try capture("retained-original", enhanced: false, offset: offset)
            try check(back.generation == firstEnhanced.generation && back.revision > enhanced.revision, "Retained original changes selected revision within the same generation")
            try check(mpv_hdr_frame_is_current(retained) == 0, "Retained enhanced lease invalidates on original selection")
            try command(["vf-command", "enhance", "compare", "enhanced"])
            let (again, againPhase) = try capture("retained-enhanced", enhanced: true, offset: offset)
            try check(again.generation == firstEnhanced.generation && again.revision > back.revision, "Retained enhanced restores the exact generation with a fresh revision")
            for phase in [backPhase, againPhase] {
                let current = phase["enhancement-state"] as? [String: Any] ?? [:]
                for key in ["submitted-frames", "completed-frames"] {
                    try require(current[key] as? Int == state[key] as? Int, "Retained comparison changed \(key)")
                }
            }
            try check(true, "Both retained comparisons perform no further inference")
            let initialPixels = enhancedPhase["exported"] as? [String: Any] ?? [:]
            let finalPixels = againPhase["exported"] as? [String: Any] ?? [:]
            try check(initialPixels["sha256"] as? String != nil && initialPixels["sha256"] as? String == finalPixels["sha256"] as? String, "Restored normalized float component bytes are identical")
            let completion = output.appendingPathComponent("capture-complete")
            let deadline = CACurrentMediaTime() + 30
            var visibility: [[String: Any]] = []
            repeat {
                try require(CACurrentMediaTime() < deadline, "External capture deadline exceeded")
                var sample: [String: Any] = [:]; DispatchQueue.main.sync { sample = self.surface() }
                visibility.append(sample)
                let end = CACurrentMediaTime() + 0.2
                while CACurrentMediaTime() < end { _ = mpv_wait_event(client, 0.01) }
            } while !FileManager.default.fileExists(atPath: completion.path)
            result["captureVisibility"] = visibility
            let (final, finalLease) = try waitFor(true); if let finalLease { mpv_hdr_frame_release(finalLease) }
            try check(final.revision == again.revision && final.generation == again.generation,
                c.metadataOnly ? "Native metadata observation preserves the selected enhanced frame" : "One native display capture preserves the selected enhanced frame")
            try check(maximumLeases <= 2 && final.producer_pool_capacity == 6, "Exporter stays within two leases and six producer buffers")
            // A bounded end-range check uses original passthrough only. Release
            // the enhanced reference before resetting the filter generation.
            if let frame = retained { mpv_hdr_frame_release(frame); retained = nil }
            let inferenceBefore = property("enhancement-state") as? [String: Any] ?? [:]
            try command(["vf-command", "enhance", "bypass", "yes"])
            let last = c.lastVideoPTS.value.addingReportingOverflow(packetOffsetTicks)
            try require(!last.overflow, "Last decoder timestamp overflow")
            expectedDecoderPTS = last.partialValue
            let lastPlayerPTS = Double(expectedDecoderPTS) / Double(c.timescale) + offset
            try command(["seek", String(format: "%.12f", lastPlayerPTS), "absolute+exact"])
            let (lastSelected, lastPhase) = try capture("last-original-pq", enhanced: false, offset: offset,
                filePTS: c.lastVideoPTS.value, metadata: c.lastFrameMetadata)
            guard let duration = property("duration") as? Double else { throw TransitionFailure(message: "Missing declared native duration") }
            let declaredOrigin = demuxerStart + Double(packetOffsetTicks) / Double(c.timescale) + offset
            let declaredEnd = declaredOrigin + duration
            let lastEnd = lastSelected.player_pts_seconds + Double(c.sourceDuration) / Double(c.timescale)
            let inferenceAfter = lastPhase["enhancement-state"] as? [String: Any] ?? [:]
            result["lastFrameRangeCheck"] = ["declaredDurationSeconds": duration,
                "declaredPlayerOriginSeconds": declaredOrigin, "declaredPlayerEndSeconds": declaredEnd,
                "lastFilePTS": ["value": c.lastVideoPTS.value, "timescale": c.timescale],
                "lastFileDuration": ["value": c.sourceDuration, "timescale": c.timescale],
                "lastFramePlayerEndSeconds": lastEnd,
                "inferenceBefore": inferenceBefore, "inferenceAfter": inferenceAfter]
            try check(duration.isFinite && duration > 0 && declaredEnd + 1e-6 >= lastEnd,
                "Declared native playback range includes the exact last source frame and its duration")
            for key in ["submitted-frames", "completed-frames"] {
                try require(inferenceBefore[key] as? Int != nil && inferenceBefore[key] as? Int == inferenceAfter[key] as? Int,
                    "Original-only last-frame check changed \(key)")
            }
            try check(true, "Original-only last-frame check performs no new neural work")
            result["passed"] = true
        } catch { result["error"] = String(describing: error) }
        if let frame = retained { mpv_hdr_frame_release(frame); retained = nil }
        if exporter != nil {
            // All scoped temporary leases have left scope. Observe the shared
            // count before exporter close instead of reporting inferred zero.
            let (status, observed, unexpected) = poll(afterRevision: UInt64.max)
            if let unexpected { mpv_hdr_frame_release(unexpected) }
            result["leaseDrainSnapshot"] = ["status": status.rawValue,
                "outstandingLeases": observed.outstanding_leases, "hostTicks": observed.host_ticks,
                "unexpectedLeaseReturned": unexpected != nil]
            if unexpected != nil || observed.outstanding_leases != 0 ||
                ![MPV_HDR_UNCHANGED, MPV_HDR_UNSUPPORTED, MPV_HDR_NO_FRAME].contains(status) {
                result["passed"] = false; result["leaseDrainError"] = "Consumer release did not produce an observed zero-leases snapshot"
            }
        }
        if let exporter { mpv_hdr_export_close(exporter) }
        if let client { mpv_terminate_destroy(client) }
        result["phases"] = phases; result["checks"] = checks; result["maximumLeases"] = maximumLeases
        result["coreDestroyed"] = true
        do { try writeJSON(result, output.appendingPathComponent("session.json")) }
        catch { result["passed"] = false; fputs("Could not write session report: \(error)\n", stderr) }
        DispatchQueue.main.async { self.exitCode = result["passed"] as? Bool == true ? 0 : 1; self.finished = true; NSApp.terminate(nil) }
    }
}

guard CommandLine.arguments.count == 2 else { fputs("usage: HDRSourceTransitionProbe CONFIG.json\n", stderr); exit(2) }
do {
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    try require(configuration.timescale > 0 && configuration.sourceDuration > 0 && configuration.formatStartSeconds.isFinite &&
        configuration.firstVideoPTS.timescale == configuration.timescale && configuration.lastVideoPTS.timescale == configuration.timescale,
        "Invalid source timing")
    try require(configuration.processingWidth > 0 && configuration.processingWidth <= 4096 &&
        configuration.processingHeight > 0 && configuration.processingHeight <= 4096 &&
        configuration.processingWidth * configuration.processingHeight <= 512 * 288,
        "Invalid or oversized processing dimensions")
    try require(configuration.expectedMetadata.count == 4 && configuration.expectedMetadata.values.allSatisfy { $0.isFinite && $0 >= 0 },
        "Invalid selected scene metadata")
    let application = NSApplication.shared
    let delegate = SourceTransitionProbe(configuration)
    application.delegate = delegate; application.setActivationPolicy(.regular); application.run()
    exit(delegate.exitCode)
} catch { fputs("Invalid diagnostic configuration: \(error)\n", stderr); exit(2) }
