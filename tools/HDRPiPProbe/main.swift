import AppKit
import AVFoundation
import AVKit
import Foundation
import QuartzCore

final class ProbeView: NSView {
    let video = AVSampleBufferDisplayLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        video.videoGravity = .resizeAspect
        layer?.addSublayer(video)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); video.frame = bounds }
}

final class PiPProbe: NSObject, NSApplicationDelegate, NSWindowDelegate,
    AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    let source: URL, model: URL?, format: String, destination: URL
    let began = CACurrentMediaTime()
    var report: [String: Any] = [:]
    var events: [[String: Any]] = []
    var window: NSWindow!
    var view: ProbeView!
    var controller: AVPictureInPictureController?
    var reference: FrameReference?
    var timebase: CMTimebase?
    var poll: Timer?
    var frameReadyAt = 0.0
    var attempted = false, didStart = false, didStop = false, finishing = false
    var terminationReady = false, stopRequested = false
    var sizes: Set<String> = []

    init(source: URL, model: URL?, format: String, destination: URL) {
        self.source = source; self.model = model; self.format = format; self.destination = destination
        super.init()
        report = ["formatRequest": format, "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
            "publicAPI": "AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)",
            "pictureInPictureSupported": AVPictureInPictureController.isPictureInPictureSupported(),
            "physicalColourAccuracyMeasured": false, "streamingSynchronisationMeasured": false]
        if let url = Bundle.main.url(forResource: "build-provenance", withExtension: "json"),
           let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) {
            report["buildProvenance"] = value
        }
    }
    func event(_ name: String, _ values: [String: Any] = [:]) {
        events.append(["name": name, "hostSeconds": CACurrentMediaTime() - began].merging(values) { _, new in new })
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 120, y: 180, width: 640, height: 384),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "HDR PiP public API probe — \(format)"
        window.delegate = self
        view = ProbeView(frame: NSRect(x: 0, y: 0, width: 640, height: 384))
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        event("host-visible", ["backingScale": window.backingScaleFactor])
        Task.detached {
            do {
                let result = try await makeFrameReference(source: self.source, model: self.model, format: self.format)
                await MainActor.run { self.install(result) }
            } catch {
                await MainActor.run { self.report["error"] = String(describing: error); self.finish() }
            }
        }
    }
    func install(_ reference: FrameReference) {
        self.reference = reference
        report["frame"] = reference.evidence
        report["engineBeforePiP"] = reference.statistics()
        var clock: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &clock) == noErr, let clock else {
            report["error"] = "Cannot create an exact media timebase"; finish(); return
        }
        timebase = clock
        CMTimebaseSetTime(clock, time: reference.pts)
        CMTimebaseSetRate(clock, rate: 0)
        view.video.controlTimebase = clock
        view.video.sampleBufferRenderer.enqueue(reference.sample)
        let content = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: view.video, playbackDelegate: self)
        controller = AVPictureInPictureController(contentSource: content)
        controller?.delegate = self
        frameReadyAt = CACurrentMediaTime()
        event("completed-frame-enqueued", ["pts": exactTime(reference.pts), "engine": reference.statistics()])
        poll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }
    func tick() {
        guard !finishing else { return }
        let renderer = view.video.sampleBufferRenderer
        report["rendererStatus"] = renderer.status.rawValue
        report["rendererHasSufficientMediaData"] = renderer.hasSufficientMediaDataForReliablePlaybackStart
        report["pictureInPicturePossible"] = controller?.isPictureInPicturePossible ?? false
        if renderer.status == .failed {
            report["error"] = renderer.error?.localizedDescription ?? "AVSampleBufferVideoRenderer failed"
            finish(); return
        }
        let elapsed = CACurrentMediaTime() - frameReadyAt
        if !attempted && elapsed >= 1 && controller?.isPictureInPicturePossible == true {
            attempted = true
            event("public-start-request")
            controller?.startPictureInPicture()
        }
        if !attempted && elapsed >= 8 {
            report["unsupportedReason"] = "Completed frame enqueued, but public PiP possibility did not become true within8seconds"
            finish()
        } else if elapsed >= 16 {
            report["unsupportedReason"] = "Public PiP lifecycle did not complete within16seconds"
            controller?.stopPictureInPicture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finish() }
        }
    }
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        event("will-start")
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        didStart = true
        event("did-start", ["active": pictureInPictureController.isPictureInPictureActive])
        // The source host can resize while PiP owns the image. Only actual
        // delegate render-size transitions are recorded as PiP observations.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.window.setContentSize(NSSize(width: 800, height: 480))
            self.view.layoutSubtreeIfNeeded()
            self.event("source-host-resized", ["width": 800, "height": 480])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.event("public-stop-request")
            self.controller?.stopPictureInPicture()
        }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                     failedToStartPictureInPictureWithError error: Error) {
        event("failed-to-start", ["error": String(describing: error)])
        report["unsupportedReason"] = String(describing: error)
        finish()
    }
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        event("will-stop")
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        didStop = true
        event("did-stop", ["active": pictureInPictureController.isPictureInPictureActive])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.finish() }
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        window.makeKeyAndOrderFront(nil)
        event("restore-interface")
        completionHandler(true)
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        event("set-playing-request", ["playing": playing, "implementedScope": "held paused reference only"])
        pictureInPictureController.invalidatePlaybackState()
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        guard let reference else { return .invalid }
        return CMTimeRange(start: reference.pts, duration: reference.duration)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { true }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        sizes.insert("\(newRenderSize.width)x\(newRenderSize.height)")
        event("render-size", ["width": newRenderSize.width, "height": newRenderSize.height,
            "active": pictureInPictureController.isPictureInPictureActive])
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                     skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        if let reference, let timebase { CMTimebaseSetTime(timebase, time: reference.pts) }
        event("skip-request-clamped-to-retained-frame", ["interval": exactTime(skipInterval)])
        completion()
    }
    func windowWillClose(_ notification: Notification) { finish() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        finish(); return .terminateCancel
    }
    func finish() {
        guard !finishing else { return }
        if controller?.isPictureInPictureActive == true && !didStop {
            if !stopRequested { stopRequested = true; controller?.stopPictureInPicture() }
            return
        }
        finishing = true; poll?.invalidate()
        report["didStart"] = didStart; report["didStop"] = didStop
        report["renderSizes"] = sizes.sorted()
        report["resizeObservation"] = sizes.count > 1 ? "multiple actual render-size delegate values observed" : "PiP window resize unexercised; source host resize is separate"
        report["events"] = events
        report["hostSurvived"] = window?.contentView === view
        report["engineAfterPiP"] = reference?.statistics()
        if let reference, let timebase {
            let current = CMTimebaseGetTime(timebase)
            report["retainedPTSUnchanged"] = CMTimeCompare(current, reference.pts) == 0
            report["finalTimebase"] = exactTime(current)
            report["samplePTS"] = exactTime(CMSampleBufferGetPresentationTimeStamp(reference.sample))
        }
        report["lifecyclePassed"] = didStart && didStop && report["error"] == nil
        let retained = reference
        reference = nil
        // Ownership moves to this one drain job after all main-thread reads.
        // Repeated application termination requests cannot skip that drain.
        let drainWork = DispatchWorkItem {
            let teardown = retained?.dispose()
            DispatchQueue.main.async {
                self.report["teardown"] = teardown
                self.report["rendererFlushedBeforeEngineDestroy"] = true
                self.writeReportAndTerminate()
            }
        }
        let drained: @Sendable () -> Void = {
            DispatchQueue.global(qos: .utility).async(execute: drainWork)
        }
        if let renderer = view?.video.sampleBufferRenderer {
            renderer.flush(removingDisplayedImage: true, completionHandler: drained)
        } else {
            drained()
        }
    }
    func writeReportAndTerminate() {
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination)
            print(String(data: data, encoding: .utf8)!)
        } catch { fputs("Cannot write PiP report: \(error)\n", stderr) }
        terminationReady = true
        NSApp.terminate(nil)
    }
}

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let source = URL(fileURLWithPath: option("--source") ?? "assets/test-clips/hdr10-30.mp4").standardizedFileURL
let model = option("--model").map { URL(fileURLWithPath: $0).standardizedFileURL }
let format = option("--format") ?? "float"
guard ["float", "pq"].contains(format) else { fatalError("--format must be float or pq") }
let destination = URL(fileURLWithPath: option("--report") ?? "artifacts/pip-probe-\(format).json").standardizedFileURL
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let probe = PiPProbe(source: source, model: model, format: format, destination: destination)
app.delegate = probe
app.run()
