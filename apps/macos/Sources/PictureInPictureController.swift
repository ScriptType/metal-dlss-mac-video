import AppKit
import AVFoundation
import AVKit
import CMpv
import CoreMedia

private final class PiPPlaybackUIState: @unchecked Sendable {
    private let lock = NSLock()
    private var duration = 0.0, paused = true
    func update(duration: Double? = nil, paused: Bool? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let duration { self.duration = duration }; if let paused { self.paused = paused }
    }
    var value: (Double, Bool) { lock.lock(); defer { lock.unlock() }; return (duration, paused) }
}

private final class PiPCompletion<Value>: @unchecked Sendable {
    let invoke: (Value) -> Void
    init(_ invoke: @escaping (Value) -> Void) { self.invoke = invoke }
}

/// A diagnostic video-only consumer of libmpv's selected, completed surfaces.
/// The native worker remains the sole decoder, inference and audio owner.
@MainActor
final class PlayerPictureInPicture: NSObject, AVPictureInPictureControllerDelegate,
    AVPictureInPictureSampleBufferPlaybackDelegate {
    let diagnosticEnabled: Bool
    let displayLayer = AVSampleBufferDisplayLayer()
    var onChange: (() -> Void)?
    private let command: (String, Any?) -> Void
    private let restore: () -> Void
    private weak var host: NSView?
    private var controller: AVPictureInPictureController?
    let coreClock: NativePiPCoreClock?
    private var timer: Timer?
    private var snapshot: NativePiPSnapshot?
    private var pending: NativePiPFrame?
    private var submitted: NativePiPFrame?
    private var epoch: UInt64 = 0, generation: UInt64 = 0
    private var lastEnqueuedRevision: UInt64 = 0
    private var lastSamplePTS = CMTime.invalid
    private var flushing = false, clearAfterFlush = false
    private var requests = PiPRequestState()
    private var closing: Bool { requests.closing }
    private var startRequested: Bool { requests.startRequested }
    private var reason = "PiP is disabled until streamed playback is qualified."
    private var compatible = false, possible = false
    private var duration = 0.0
    private var comparingOriginal = false
    private var maxExportedLeases: UInt32 = 0
    private var enqueued = 0, flushed = 0, discarded = 0, backpressure = 0
    private var events: [[String: Any]] = []
    private var shutdownCompletion: (() -> Void)?
    private var skipCompletion: (() -> Void)?
    private var skipGeneration: UInt64 = 0, skipEpoch: UInt64 = 0
    private var skipDeadline: Date?
    private nonisolated let playbackUI = PiPPlaybackUIState()

    init(host: NSView, diagnosticEnabled: Bool, command: @escaping (String, Any?) -> Void,
         restore: @escaping () -> Void) {
        self.host = host; self.diagnosticEnabled = diagnosticEnabled; self.command = command; self.restore = restore
        coreClock = diagnosticEnabled ? NativePiPCoreClock() : nil
        super.init()
        guard diagnosticEnabled else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            reason = "Picture in Picture is unavailable on this system."; return
        }
        guard let coreClock else { reason = "The native PiP clock could not be created."; return }
        displayLayer.controlTimebase = coreClock.timebase
        displayLayer.videoGravity = .resizeAspect
        host.wantsLayer = true
        // Keep mpv's native child view above the inline AVKit source layer.
        // It is attached to the actual window, with no web video or screen copy.
        host.layer?.insertSublayer(displayLayer, at: 0)
        layout()
        let content = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        controller = AVPictureInPictureController(contentSource: content)
        controller?.delegate = self
        reason = "PiP requires a completed float frame with supported timing and colour."
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        event("consumer-created")
    }

    var state: [String: Any] {
        let native = snapshot?.state ?? mpv_hdr_snapshot()
        let clock = coreClock?.state ?? [:]
        return ["diagnosticEnabled": diagnosticEnabled, "available": available, "active": controller?.isPictureInPictureActive ?? false,
            "reason": reason, "compatibleStream": compatible, "systemPossible": possible,
            "enqueuedFrames": enqueued, "discardedFrames": discarded, "flushes": flushed, "backpressureObservations": backpressure,
            "pendingFrames": pending == nil ? 0 : 1, "submittedLeases": submitted == nil ? 0 : 1,
            "maximumObservedExportLeases": maxExportedLeases, "exportLeaseLimit": native.maximum_leases,
            "producerPoolCapacity": native.producer_pool_capacity, "epoch": epoch, "generation": generation,
            "revision": lastEnqueuedRevision, "clockRate": clock["rate"] ?? 0, "clock": clock,
            "samplePTS": ["value": lastSamplePTS.value, "timescale": lastSamplePTS.timescale,
                "rounded": lastSamplePTS.flags.contains(.hasBeenRounded)],
            "clockSource": native.clock_source, "sourcePTS": ["value": native.source_pts.value, "timescale": native.source_pts.timescale],
            "sourceDuration": ["value": native.source_duration.value, "timescale": native.source_duration.timescale],
            "contentKind": native.content_kind, "physicalAVSyncQualified": false, "physicalHDRQualified": false]
    }
    var available: Bool { diagnosticEnabled && compatible && possible && requests.acceptsFrames && submitted != nil && lastEnqueuedRevision > 0 }

    func layout() {
        guard let host, displayLayer.frame != host.bounds else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.frame = host.bounds
        CATransaction.commit()
    }
    func updatePlaybackState(_ value: [String: Any]) {
        duration = max(0, value["duration"] as? Double ?? 0)
        playbackUI.update(duration: duration)
        let native = value["nativeEnhancement"] as? [String: Any] ?? [:]
        comparingOriginal = native["comparison"] as? String == "original" && native["compare-ready"] as? Bool == true
        // Stream eligibility comes from the atomic exporter snapshot. A slower
        // JSON subtitle/track poll must not reject the first valid frame after
        // that native gate changes and consume its one delivery revision.
    }

    func receive(_ value: NativePiPSnapshot) {
        guard diagnosticEnabled, controller != nil, !closing else { return }
        snapshot = value
        let native = value.state
        playbackUI.update(paused: native.user_paused != 0)
        maxExportedLeases = max(maxExportedLeases, native.outstanding_leases)
        if let failure = requests.rendererFailure {
            invalidate(reason: failure, stop: true)
            return
        }
        let discontinuity = native.stream_epoch != epoch || native.generation != generation
        if discontinuity {
            epoch = native.stream_epoch; generation = native.generation
            pending = nil; lastEnqueuedRevision = 0
            event("generation-invalidated")
            flush(removingImage: true)
        }
        guard value.unavailableReason == nil, native.supported != 0, native.clock_valid != 0 else {
            let text = value.unavailableReason ?? Self.unsupported(native.reason)
            // Seek previews may be nonfloat. Clear old-generation samples and
            // keep PiP waiting for the matching supported result, without
            // mislabelling a raw preview as enhanced float output.
            let transient = native.reason == UInt32(MPV_HDR_REASON_STALE.rawValue) ||
                native.reason == UInt32(MPV_HDR_REASON_NO_VIDEO.rawValue) ||
                (native.reason == UInt32(MPV_HDR_REASON_FORMAT.rawValue) && native.buffering != 0 && !comparingOriginal)
            invalidate(reason: text, stop: !transient)
            return
        }
        controller?.invalidatePlaybackState()
        if !compatible { compatible = true; reason = "Diagnostic PiP preview; HDR brightness and streamed presentation remain unqualified."; onChange?() }
        if let frame = value.frame, frame.state.revision != lastEnqueuedRevision {
            if pending != nil { discarded += 1 }
            pending = frame
            drain()
        }
        tick()
    }

    private func drain(afterFlush: Bool = false) {
        guard requests.acceptsFrames, !flushing, compatible, let frame = pending else { return }
        guard frame.isCurrent, frame.state.stream_epoch == epoch, frame.state.generation == generation else {
            pending = nil; discarded += 1; return
        }
        let renderer = displayLayer.sampleBufferRenderer
        guard renderer.isReadyForMoreMediaData else { backpressure += 1; return }
        if submitted != nil && !afterFlush { flush(removingImage: false); return }
        do {
            let sample = try Self.sample(frame)
            guard frame.isCurrent else { pending = nil; discarded += 1; return }
            renderer.enqueue(sample)
            lastSamplePTS = CMSampleBufferGetPresentationTimeStamp(sample)
            submitted = frame; pending = nil; lastEnqueuedRevision = frame.state.revision; enqueued += 1
            if enqueued <= 12 || enqueued % 60 == 0 { event("frame-enqueued") }
            if skipCompletion != nil && (epoch != skipEpoch || generation != skipGeneration) {
                event("skip-generation-established"); finishSkip()
            }
        } catch { invalidate(reason: error.localizedDescription, stop: true) }
    }

    private func flush(removingImage: Bool) {
        if flushing { clearAfterFlush = clearAfterFlush || removingImage; return }
        flushing = true
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: removingImage) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.submitted = nil; self.flushing = false; self.flushed += 1
                if self.clearAfterFlush {
                    self.clearAfterFlush = false; self.flush(removingImage: true)
                } else if self.closing { self.finishShutdown() }
                else { self.drain(afterFlush: true) }
            }
        }
    }

    private func invalidate(reason text: String, stop: Bool) {
        let changed = compatible || reason != text
        compatible = false; reason = text; pending = nil
        if submitted != nil { flush(removingImage: true) }
        if stop && (controller?.isPictureInPictureActive == true || startRequested) && requests.requestStop() {
            controller?.stopPictureInPicture()
        }
        if changed { event("stream-unavailable", ["reason": text]); onChange?() }
    }

    private func tick() {
        guard !closing else { return }
        layout()
        let next = controller?.isPictureInPicturePossible ?? false
        if next != possible { possible = next; onChange?() }
        if displayLayer.sampleBufferRenderer.status == .failed {
            let error = displayLayer.sampleBufferRenderer.error?.localizedDescription ?? "The PiP video renderer failed."
            if requests.failRenderer(error + " Restart the player to retry PiP.") {
                invalidate(reason: requests.rendererFailure!, stop: true)
                finishSkip()
                // A paused selected revision is exported only once. Clearing a
                // failed renderer cannot silently recover that consumed frame.
                // Fail closed until restart and flush even without an app lease.
                flush(removingImage: true)
            }
        }
        if let skipDeadline, Date() >= skipDeadline {
            event("skip-timeout"); reason = "PiP seek did not establish a supported frame in time."; finishSkip(); onChange?()
        }
        drain()
    }
    func toggle() {
        if controller?.isPictureInPictureActive == true || startRequested {
            if requests.requestStop() { event("stop-request"); controller?.stopPictureInPicture() }
        } else if available && requests.requestStart() {
            event("start-request"); controller?.startPictureInPicture()
        }
    }
    func shutdown(completion: @escaping () -> Void) {
        guard requests.beginShutdown() else { return }
        shutdownCompletion = completion; timer?.invalidate(); timer = nil; pending = nil
        coreClock?.close()
        finishSkip(); event("shutdown-request")
        if controller?.isPictureInPictureActive == true || startRequested {
            _ = requests.requestStop(); controller?.stopPictureInPicture()
        } else { flush(removingImage: true) }
    }
    private func finishShutdown() {
        guard closing, !flushing, controller?.isPictureInPictureActive != true, !startRequested else { return }
        submitted = nil; pending = nil
        snapshot = snapshot.map { NativePiPSnapshot(state: $0.state, unavailableReason: $0.unavailableReason) }
        displayLayer.removeFromSuperlayer()
        event("renderer-flushed-and-leases-released")
        if let path = ProcessInfo.processInfo.environment["HDRPLAYER_PIP_REPORT"] {
            let output: [String: Any] = ["version": 1, "state": state, "events": events,
                "scope": "Diagnostic selected-frame PiP consumer; no physical HDR or A/V qualification"]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
                let url = URL(fileURLWithPath: path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
        let complete = shutdownCompletion; shutdownCompletion = nil; complete?()
    }
    private func event(_ name: String, _ extra: [String: Any] = [:]) {
        guard events.count < 1000 else { return }
        events.append(["event": name, "hostSeconds": ProcessInfo.processInfo.systemUptime,
            "epoch": epoch, "generation": generation, "revision": lastEnqueuedRevision,
            "enqueuedFrames": enqueued].merging(extra) { _, new in new })
    }
    private func finishSkip() { let complete = skipCompletion; skipCompletion = nil; skipDeadline = nil; complete?() }

    private static func sample(_ frame: NativePiPFrame) throws -> CMSampleBuffer {
        func failure(_ text: String) -> NSError { NSError(domain: "HDRPlayer.PiP", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        let native = frame.state
        guard CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_64RGBAHalf,
              native.source_pts.timescale > 0, native.source_duration.timescale > 0, native.source_duration.value > 0,
              native.source_to_player_seconds.isFinite else { throw failure("PiP requires completed RGBA16F with exact source timing.") }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.pixelBuffer, formatDescriptionOut: &description) == noErr,
              let description else { throw failure("The PiP float format description could not be created.") }
        let sourcePTS = CMTime(value: native.source_pts.value, timescale: native.source_pts.timescale)
        // Adding a zero time with an unrelated large timescale can round an
        // exact 1/30 timestamp. Preserve the source rational unchanged when the
        // core timeline has no offset; record any nonzero offset separately.
        let playerPTS = native.source_to_player_seconds == 0 ? sourcePTS : CMTimeAdd(sourcePTS,
            CMTime(seconds: native.source_to_player_seconds, preferredTimescale: 1_000_000_000))
        var timing = CMSampleTimingInfo(duration: CMTime(value: native.source_duration.value, timescale: native.source_duration.timescale),
            presentationTimeStamp: playerPTS, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: frame.pixelBuffer,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw failure("The PiP frame sample could not be created.") }
        return sample
    }
    private static func unsupported(_ reason: UInt32) -> String {
        switch reason {
        case UInt32(MPV_HDR_REASON_DOLBY_VISION.rawValue): return "PiP does not yet include Dolby Vision processing."
        case UInt32(MPV_HDR_REASON_SUBTITLES.rawValue): return "Turn subtitles off before using this PiP preview."
        case UInt32(MPV_HDR_REASON_GEOMETRY.rawValue): return "PiP currently requires uncropped, unrotated square-pixel video."
        case UInt32(MPV_HDR_REASON_CLOCK.rawValue): return "PiP requires a supported native playback clock."
        case UInt32(MPV_HDR_REASON_TIMING.rawValue): return "PiP requires exact frame timing."
        case UInt32(MPV_HDR_REASON_STALE.rawValue): return "PiP is waiting for the new seek or stream generation."
        case UInt32(MPV_HDR_REASON_NO_VIDEO.rawValue): return "Open a supported video before starting PiP."
        case UInt32(MPV_HDR_REASON_FORMAT.rawValue): return "PiP currently requires completed float enhancement output."
        default: return "This frame is unavailable for PiP."
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { [self] in
            let shouldStop = requests.didStart()
            event("did-start"); onChange?()
            if shouldStop { controller?.stopPictureInPicture() }
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { [self] in
            requests.didFailToStart(); reason = requests.rendererFailure ?? message
            event("start-failed", ["reason": reason]); onChange?()
            if closing { flush(removingImage: true) }
        }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { [self] in
            requests.didStop(); event("did-stop"); onChange?()
            if closing { flush(removingImage: true) }
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        let callback = PiPCompletion(completionHandler)
        DispatchQueue.main.async { [self] in restore(); event("restore-interface"); callback.invoke(true) }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        DispatchQueue.main.async { [self] in
            guard requests.acceptsPlaybackCommands else { return }
            event("play-request", ["playing": playing]); command(playing ? "play" : "pause", nil)
        }
    }
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: playbackUI.value.0, preferredTimescale: 1_000_000_000))
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        playbackUI.value.1
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        DispatchQueue.main.async { [self] in event("render-size", ["width": newRenderSize.width, "height": newRenderSize.height]) }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        let callback = PiPCompletion<Void> { _ in completion() }
        DispatchQueue.main.async { [self] in skip(by: skipInterval) { callback.invoke(()) } }
    }
    private func skip(by skipInterval: CMTime, completion: @escaping () -> Void) {
        // AVKit can deliver a queued delegate callback after shutdown removed
        // the timer and frame drain. Complete it now, without starting a seek.
        guard requests.acceptsPlaybackCommands else { completion(); return }
        finishSkip()
        let interval = CMTimeGetSeconds(skipInterval)
        guard interval.isFinite, let snapshot, snapshot.state.clock_valid != 0 else { completion(); return }
        let target = max(0, min(max(0, duration - 0.001), (coreClock?.currentMediaSeconds ?? snapshot.state.media_seconds) + interval))
        skipCompletion = completion; skipEpoch = epoch; skipGeneration = generation; skipDeadline = Date().addingTimeInterval(10)
        event("skip-request", ["targetSeconds": target]); command("seek", target)
    }
}
