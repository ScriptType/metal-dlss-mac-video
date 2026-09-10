import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Diagnostic of the public renderer's paused sample scheduling. Synthetic
/// float pixels isolate timing; this is neither neural nor physical HDR proof.
@MainActor
final class PausedRendererProbe: NSObject, NSApplicationDelegate {
    let output: URL
    let layer = AVSampleBufferDisplayLayer()
    var window: NSWindow!
    var timebase: CMTimebase!
    var observations: [[String: Any]] = []
    var report: [String: Any] = ["schemaVersion": 1,
        "scope": "Public AVSampleBufferVideoRenderer paused scheduling and copied displayed pixel identity; synthetic linear BT.2020 float, no PiP window/physical HDR or A/V qualification"]

    init(output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 320, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Paused HDR renderer timing probe"
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.wantsLayer = true; window.contentView = view
        layer.frame = view.bounds; view.layer?.addSublayer(layer)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        Task { await run() }
    }

    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "PausedRendererProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func makeImage(_ channels: [Float16]) throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        try require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_64RGBAHalf,
            attributes as CFDictionary, &image) == kCVReturnSuccess, "Cannot allocate float image")
        guard let image else { throw NSError(domain: "PausedRendererProbe", code: 2) }
        CVPixelBufferLockBaseAddress(image, []); defer { CVPixelBufferUnlockBaseAddress(image, []) }
        let base = CVPixelBufferGetBaseAddress(image)!
        for y in 0..<48 {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(image)).assumingMemoryBound(to: UInt16.self)
            for x in 0..<64 { for c in 0..<4 { row[x * 4 + c] = channels[c].bitPattern } }
        }
        CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_Linear, .shouldPropagate)
        return image
    }
    func enqueue(_ image: CVPixelBuffer, pts: CMTime) throws {
        var description: CMVideoFormatDescription?
        try require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &description) == noErr, "Cannot describe float image")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try require(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
            formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, "Cannot create timed sample")
        layer.sampleBufferRenderer.enqueue(sample!)
    }
    func displayed() -> [String: Any] {
        guard let image = layer.sampleBufferRenderer.displayedPixelBuffer() else {
            return ["available": false, "rendererStatus": layer.sampleBufferRenderer.status.rawValue]
        }
        var value: [String: Any] = ["available": true, "pixelFormat": CVPixelBufferGetPixelFormatType(image),
            "width": CVPixelBufferGetWidth(image), "height": CVPixelBufferGetHeight(image)]
        if CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_64RGBAHalf {
            CVPixelBufferLockBaseAddress(image, .readOnly); defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            let raw = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt16.self)
            value["firstPixelBits"] = (0..<4).map { raw[$0] }
        }
        return value
    }
    func flush() async {
        await withCheckedContinuation { continuation in
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true) { continuation.resume() }
        }
    }
    func run() async {
        do {
            var clock: CMTimebase?
            try require(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(), timebaseOut: &clock) == noErr, "Cannot create timebase")
            timebase = clock!; layer.controlTimebase = timebase
            CMTimebaseSetRate(timebase, rate: 0)
            for (index, offset) in [0.020, 0.005].enumerated() {
                await flush()
                let channels: [Float16] = index == 0 ? [1, 0, 0, 1] : [0, 0, 1, 1]
                let image = try makeImage(channels)
                let pts = CMTime(value: Int64(index + 1), timescale: 1)
                CMTimebaseSetTime(timebase, time: CMTimeSubtract(pts, CMTime(seconds: offset, preferredTimescale: 1_000_000)))
                try enqueue(image, pts: pts)
                try await Task.sleep(for: .milliseconds(500))
                let before = displayed()
                let held = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
                CMTimebaseSetTime(timebase, time: pts)
                var after = displayed()
                for _ in 0..<100 where after["available"] as? Bool != true {
                    try await Task.sleep(for: .milliseconds(20)); after = displayed()
                }
                observations.append(["sourcePTS": ["value": pts.value, "timescale": pts.timescale],
                    "heldClockSeconds": held, "sampleAheadSeconds": offset, "beforeSelectedAnchor": before,
                    "afterSelectedAnchor": after, "expectedPixelBits": channels.map(\.bitPattern)])
                try require(after["firstPixelBits"] as? [UInt16] == channels.map(\.bitPattern), "Selected anchor did not expose the exact float image")
            }
            report["passed"] = true
        } catch { report["passed"] = false; report["error"] = error.localizedDescription }
        await flush()
        report["observations"] = observations
        report["afterFlush"] = displayed()
        report["osVersion"] = ProcessInfo.processInfo.operatingSystemVersionString
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: output)
        }
        layer.removeFromSuperlayer(); window.orderOut(nil)
        let success = report["passed"] as? Bool == true
        NSApp.stop(nil)
        exit(success ? 0 : 1)
    }
}

@main
struct PausedRendererMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "artifacts/pip-paused-renderer.json")
        let delegate = PausedRendererProbe(output: output)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
