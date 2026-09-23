import CFrameEngine
import CoreVideo
import DLSSMLX
import Foundation
@testable import FrameEngine
import Metal
import QuartzCore
import Testing

private let referenceProject = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
/// The retained 1080p HDR10+ reference, pinned in docs/evidence/apple-natural-hdr-source.json.
private let referenceSource = referenceProject.appendingPathComponent("artifacts/public-hdr-source-audit/apple-advanced-hdr10plus-aac.mp4")
private let referenceModel = referenceProject.appendingPathComponent("models/neural-rendering/NeuralRendering.dlssmodel")
private let referenceAvailable = MTLCreateSystemDefaultDevice() != nil
    && FileManager.default.fileExists(atPath: referenceSource.path) && HEVCEncoder.isAvailable
private let referenceWeightsAvailable = FileManager.default.fileExists(atPath: referenceModel.appendingPathComponent("weights.safetensors").path)

/// The app's default Prepared capacity (apps/macos/Sources/MPVPlaybackController.swift:306).
/// FrameEngineTests cannot import the app target.
private let defaultCapacityBytes: Int64 = 8 * 1_073_741_824

private func pqSignal(nits: Double) -> Double {
    let y = pow(min(max(nits, 0), 10_000) / 10_000, 0.1593017578125)
    return pow((0.8359375 + 18.8515625 * y) / (1 + 18.6875 * y), 78.84375)
}

private func pqNits(signal: Double) -> Double {
    let p = pow(signal, 1 / 78.84375)
    return 10_000 * pow(max(p - 0.8359375, 0) / (18.8515625 - 18.6875 * p), 1 / 0.1593017578125)
}

/// Nits spanned by one 10-bit video-range luma code (1/876 of PQ signal) above `nits`.
private func pqCodeStepNits(atNits nits: Double) -> Double {
    pqNits(signal: pqSignal(nits: nits) + 1.0 / 876) - nits
}

/// NativeHDRVideoReader gives decoded frames 1/nominal-rate durations at a 60,000 timescale
/// (2502/60000 here), while the native inventory reads the exact sample durations (1001/24000),
/// so native preparation of this 23.976 fps source fails its exact timing check at frame 0.
/// This provider keeps the native decoder's pixels and PTS and takes each duration from the
/// inventory. mpv's own provider, which the app uses, reports exact durations.
private struct InventoryDurationProvider: FramePreparationDecoderProvider {
    let native = NativeFramePreparationProvider()
    let scanned: FramePreparationInventory
    var identifier: String { native.identifier + ";inventory-durations" }

    init(source: URL) async throws { scanned = try await native.inventory(sourceURL: source, videoStreamIndex: 0) }

    func inventory(sourceURL: URL, videoStreamIndex: Int) async throws -> FramePreparationInventory { scanned }

    func decoder(sourceURL: URL, videoStreamIndex: Int, range: HDRCacheRange) async throws -> any FramePreparationDecoder {
        InventoryDurationDecoder(inner: try await native.decoder(sourceURL: sourceURL, videoStreamIndex: videoStreamIndex, range: range),
            durations: Dictionary(uniqueKeysWithValues: scanned.timings.map { ($0.presentationTime, $0.duration) }))
    }
}

private actor InventoryDurationDecoder: FramePreparationDecoder {
    let inner: any FramePreparationDecoder
    let durations: [HDRCacheTime: HDRCacheTime]
    init(inner: any FramePreparationDecoder, durations: [HDRCacheTime: HDRCacheTime]) { self.inner = inner; self.durations = durations }

    func next() async throws -> EngineInput? {
        guard let decoded = try await inner.next() else { return nil }
        var descriptor = decoded.descriptor
        let duration = try #require(durations[try HDRCacheTime(value: descriptor.pts.value, timescale: descriptor.pts.timescale)])
        descriptor.duration = fe_time(value: duration.value, timescale: duration.timescale)
        return withExtendedLifetime(decoded) { EngineInput(descriptor) }
    }

    func cancel() async { await inner.cancel() }
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.up)) - 1)]
}

private func rgbaBytes(_ buffer: CVPixelBuffer) -> Data {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer), width = CVPixelBufferGetWidth(buffer) * 8
    let base = CVPixelBufferGetBaseAddress(buffer)!
    var data = Data(capacity: width * CVPixelBufferGetHeight(buffer))
    for y in 0..<CVPixelBufferGetHeight(buffer) { data.append(base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self), count: width) }
    return data
}

@Suite(.serialized, .enabled(if: referenceAvailable, "Requires the retained 1080p HDR10+ reference, Metal and a hardware HEVC encoder"))
struct PreparedHEVCReferenceTests {
    @Test func preparedHEVCMatchesFloat32PathOnRetainedReference() async throws {
        try await compareWithFloat32Path(strength: 0)
    }

    @Test(.enabled(if: referenceWeightsAvailable, "Requires Neural Rendering weights"))
    func preparedEnhancedHEVCMatchesFloat32PathOnRetainedReference() async throws {
        try await compareWithFloat32Path(strength: 1)
    }

    /// Frames 1488-1543 (56 frames with 8 preroll) are prepared twice by the real coordinator,
    /// once per storage policy, and both are read back through the reader production uses.
    private func compareWithFloat32Path(strength: Float) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-hevc-reference-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await HDRSegmentCache.open(directory: directory, capacityBytes: 4 * 1_073_741_824)
        let provider = try await InventoryDurationProvider(source: referenceSource)
        let inventory = provider.scanned
        #expect(inventory.timings.count == 2_360 && inventory.width == 1_920 && inventory.height == 1_080)
        let modelURL = strength > 0 ? referenceModel : nil
        let configuration = HDRPipelineConfiguration(modelURL: modelURL, modelVersion: try preparedModelSHA256(modelURL),
            processingWidth: 32, processingHeight: 24, strength: strength)
        let source = try HDRCacheSource.fingerprint(url: referenceSource, streamIndex: 0,
            interpretation: ["decoder": provider.identifier])
        func segment(storage: String) throws -> HDRPreparationSegment {
            let settings = HDRCacheSettings(modelSHA256: configuration.modelVersion,
                implementationVersion: PreparedHDRContext.cacheImplementationVersion,
                processingWidth: 32, processingHeight: 24, outputWidth: inventory.width, outputHeight: inventory.height,
                colourPolicy: ["storage": storage, "referenceWhiteNits": "203"],
                effects: ["strength": Double(strength), "colourStrength": 1, "maximumLuminanceRatio": 2])
            let segments = try inventory.segments(source: source, settings: settings,
                rangeStart: inventory.timings[1_488].presentationTime, rangeEnd: inventory.timings[1_544].presentationTime,
                segmentFrames: 56, prerollFrames: 8)
            return try #require(segments.count == 1 ? segments[0] : nil)
        }
        let float32 = try segment(storage: HDRSegmentCache.storagePolicy), hevc = try segment(storage: HDRCacheHEVC.storagePolicy)
        let coordinator = HDRPreparationCoordinator(cache: cache, configuration: configuration, decoderProvider: provider)
        try await coordinator.start(sourceURL: referenceSource, segments: [float32, hevc])
        try await coordinator.wait()
        #expect(await coordinator.progress().completedSegments == 2)

        let reference = try #require(try await cache.acquire(identity: float32.identity))
        let candidate = try #require(try await cache.acquire(identity: hevc.identity))
        let hevcBytes = candidate.manifest.frames.reduce(0) { $0 + $1.byteCount }
        var bins = [UInt64](repeating: 0, count: 2_000_000)
        var statistics = hdr_cache_error_histogram()
        let float32Reader = HDRCacheFrameReader(), hevcReader = HDRCacheFrameReader()
        var hitSeconds: [Double] = [], sequential: [Int: Data] = [:]
        for index in 0..<56 {
            let expected = try await float32Reader.frame(index, of: reference, in: cache).buffer
            let start = CACurrentMediaTime()
            let actual = try await hevcReader.frame(index, of: candidate, in: cache).buffer
            hitSeconds.append(CACurrentMediaTime() - start)
            if index == 35 || index == 55 { sequential[index] = rgbaBytes(actual) }
            CVPixelBufferLockBaseAddress(expected, .readOnly); CVPixelBufferLockBaseAddress(actual, .readOnly)
            let accumulated = bins.withUnsafeMutableBufferPointer { storage in
                statistics.bins = storage.baseAddress; statistics.bin_count = storage.count; statistics.bin_width = 0.01
                return hdr_cache_accumulate_rgba16f_error(&statistics,
                    CVPixelBufferGetBaseAddress(expected), CVPixelBufferGetBytesPerRow(expected),
                    CVPixelBufferGetBaseAddress(actual), CVPixelBufferGetBytesPerRow(actual), 1_920, 1_080)
            }
            CVPixelBufferUnlockBaseAddress(expected, .readOnly); CVPixelBufferUnlockBaseAddress(actual, .readOnly)
            #expect(accumulated, "frame \(index) has finite RGBA16F pixels")
        }
        let cold = HDRCacheFrameReader()
        #expect(rgbaBytes(try await cold.frame(35, of: candidate, in: cache).buffer) == sequential[35],
                "a cold mid-segment entry equals the sequential decode")
        await cache.release(reference); await cache.release(candidate)
        // A seek as production sees it: the processor keeps its reader, releases the lease on
        // resetHistory, then acquires the segment again and enters mid-segment.
        var entrySeconds: [Int: Double] = [:]
        for index in [35, 55] {
            let start = CACurrentMediaTime()
            let lease = try #require(try await cache.acquire(identity: hevc.identity))
            let entered = try await hevcReader.frame(index, of: lease, in: cache).buffer
            entrySeconds[index] = CACurrentMediaTime() - start
            #expect(rgbaBytes(entered) == sequential[index], "seek entry at \(index) equals the sequential decode")
            await cache.release(lease)
        }

        var cumulative: UInt64 = 0
        let p99Bin = bins.firstIndex { cumulative += $0; return Double(cumulative) >= 0.99 * Double(statistics.count) }!
        let p99 = Double(p99Bin + 1) * statistics.bin_width, mean = statistics.sum / Double(statistics.count)
        // Stated before the first run. p99: within one 10-bit PQ code at 1,000 nits, so 99 % of
        // channel values land within one storage code at a typical highlight level. Max: within
        // 10 % of the compared Float32 frames' peak channel value, which bounds 4:2:0 colour-edge
        // loss plus codec ringing at the brightest pixel.
        let p99Tolerance = pqCodeStepNits(atNits: 1_000), maxTolerance = 0.1 * statistics.reference_peak
        print(String(format: "Prepared HEVC reference, strength %.0f: 56 frames 1920x1080 (1488-1543), %llu channel values; "
            + "error max %.2f nits, p99 %.2f nits, mean %.3f nits; Float32 peak %.1f nits; "
            + "tolerance p99 <= %.2f, max <= %.1f; HEVC segment %d bytes; "
            + "hit median %.1f ms, p95 %.1f ms; seek entry (acquire + decode from IDR) at 35 %.1f ms, at 55 %.1f ms (debug build)",
            strength, statistics.count, statistics.max, p99, mean, statistics.reference_peak, p99Tolerance, maxTolerance, hevcBytes,
            percentile(hitSeconds, 0.5) * 1_000, percentile(hitSeconds, 0.95) * 1_000,
            entrySeconds[35]! * 1_000, entrySeconds[55]! * 1_000))
        #expect(statistics.count == 56 * 1_920 * 1_080 * 3)
        #expect(statistics.alpha_mismatches == 0)
        #expect(p99 <= p99Tolerance)
        #expect(statistics.max <= maxTolerance)
    }

    /// The whole reference through production Prepared code at the app's default capacity.
    @Test func preparedHEVCBytesPerMinuteFitTwoHourFilmInDefaultCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-hevc-minute-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try PreparedHDRContext(request: .init(sourcePath: referenceSource.path, cacheDirectory: directory.path,
            capacityBytes: defaultCapacityBytes, segmentFrames: 60, prerollFrames: 8),
            configuration: .init(processingWidth: 32, processingHeight: 24, strength: 0),
            decoderProvider: try await InventoryDurationProvider(source: referenceSource))
        let start = CACurrentMediaTime()
        try await context.waitUntilReady()
        await context.start(); await context.wait()
        let preparationSeconds = CACurrentMediaTime() - start
        #expect(context.status.snapshot().jobState == "complete")
        #expect(context.status.snapshot().completedSegments == 40)

        let segments = directory.appendingPathComponent("segments")
        var bytes: Int64 = 0, frames = 0, extraIRAP: [String] = []
        var first: HDRCacheTime?, end: HDRCacheTime?
        for folder in try FileManager.default.contentsOfDirectory(at: segments, includingPropertiesForKeys: nil) {
            let manifest = try JSONDecoder().decode(HDRCacheManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            #expect(manifest.storagePolicy == HDRCacheHEVC.storagePolicy)
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]) {
                bytes += Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            for (index, record) in manifest.frames.enumerated() where index > 0 {
                let sample = try Data(contentsOf: folder.appendingPathComponent(record.fileName))
                let irap = sample.withUnsafeBytes { raw in
                    HDRCacheHEVCSample.nalUnits(raw)!.contains { (16...21).contains(HDRCacheHEVCSample.nalType(raw, $0)) }
                }
                if irap { extraIRAP.append("\(manifest.key.prefix(8))/\(index)") }
            }
            frames += manifest.frames.count
            first = min(first ?? manifest.frames[0].timing.presentationTime, manifest.frames[0].timing.presentationTime)
            let last = try manifest.frames[manifest.frames.count - 1].timing.end
            end = max(end ?? last, last)
        }
        let seconds = Double(try #require(end).value) / Double(try #require(end).timescale)
            - Double(try #require(first).value) / Double(try #require(first).timescale)
        let bytesPerMinute = Double(bytes) / (seconds / 60), twoHours = 120 * bytesPerMinute
        print(String(format: "Prepared HEVC size: %d frames, %.2f s of 1080p23.976, %lld bytes including manifests; "
            + "%.0f bytes (%.1f MiB) per prepared minute; 2-hour projection %.2f GiB of %.0f GiB default; "
            + "%.3f Mbit/s; extra IRAP samples %d; preparation %.0f s (strength 0, debug build)",
            frames, seconds, bytes, bytesPerMinute, bytesPerMinute / 1_048_576, twoHours / 1_073_741_824,
            Double(defaultCapacityBytes) / 1_073_741_824, Double(bytes) * 8 / seconds / 1_000_000, extraIRAP.count, preparationSeconds))
        #expect(frames == 2_360)
        #expect(extraIRAP.isEmpty, "one IDR per segment: \(extraIRAP.prefix(5))")
        #expect(twoHours <= Double(defaultCapacityBytes))
        await context.cancel()
    }
}
