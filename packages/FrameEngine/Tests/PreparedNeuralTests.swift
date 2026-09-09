import CFrameEngine
import CoreVideo
import DLSSMedia
import Foundation
import Metal
import Testing
@testable import FrameEngine

private let neuralProject = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let neuralSource = neuralProject.appendingPathComponent("assets/test-clips/hdr10-30.mp4")
private let neuralModel = neuralProject.appendingPathComponent("models/neural-rendering/NeuralRendering.dlssmodel")

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil && FileManager.default.fileExists(atPath: neuralSource.path)
               && FileManager.default.fileExists(atPath: neuralModel.appendingPathComponent("weights.safetensors").path),
               "Requires local PQ fixture, Neural Rendering weights and Metal"))
func preparedNeuralPrerollRecomputesAcrossBoundaryAndCancelledResume() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try await HDRSegmentCache.open(directory: directory, capacityBytes: 64 * 1024 * 1024)
    let hash = try HDRCacheSource.fingerprint(url: neuralModel.appendingPathComponent("weights.safetensors"), streamIndex: 0).contentSHA256
    let source = try HDRCacheSource.fingerprint(url: neuralSource, streamIndex: 0)
    let settings = HDRCacheSettings(modelSHA256: hash, implementationVersion: "prepared-neural-equivalence-v1",
        processingWidth: 32, processingHeight: 24, outputWidth: 320, outputHeight: 192,
        colourPolicy: ["storage": HDRSegmentCache.storagePolicy, "referenceWhiteNits": "203"],
        effects: ["strength": 1, "colourStrength": 1, "maximumLuminanceRatio": 2])
    func segment(_ start: Int64, _ end: Int64) throws -> HDRPreparationSegment {
        try .init(identity: .init(source: source,
            range: .init(start: .init(value: start, timescale: 30), end: .init(value: end, timescale: 30)),
            settings: settings, preroll: .init(start: .init(value: 0, timescale: 30),
                policyVersion: "reset-decode-all-from-preroll-v1", randomSeed: 0)), frameCount: Int(end - start))
    }
    let segments = try [segment(0, 3), segment(3, 9)]
    let configuration = HDRPipelineConfiguration(modelURL: neuralModel, modelVersion: hash,
        processingWidth: 32, processingHeight: 24, strength: 1)
    let coordinator = HDRPreparationCoordinator(cache: cache, configuration: configuration)
    try await coordinator.start(sourceURL: neuralSource, segments: [segments[0]])
    try await coordinator.wait()
    try await coordinator.start(sourceURL: neuralSource, segments: segments)
    while true {
        let progress = await coordinator.progress()
        if progress.processedFrames > 0 || progress.state != .preparing { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    await coordinator.cancel()
    #expect(await coordinator.progress().state == .cancelled)
    #expect(try await cache.usage().stagedSegments == 0)
    #expect(try await cache.acquire(identity: segments[1].identity) == nil)
    try await coordinator.start(sourceURL: neuralSource, segments: segments)
    try await coordinator.wait()
    #expect(await coordinator.progress().reusedSegments == 1)
    #expect(await coordinator.progress().completedSegments == 2)

    // Both segments have the same deterministic zero-time preroll as the
    // independent continuous reference. This also exercises the segment seam.
    let reference = HDRPipelineProcessor(configuration: configuration)
    let reader = try await NativeHDRVideoReader(url: neuralSource)
    let leases = try await segments.asyncMap { try #require(try await cache.acquire(identity: $0.identity)) }
    var maxAbsoluteError: Float = 0, maxRelativeError: Float = 0
    for index in 0..<9 {
        let decoded = try #require(try await reader.nextDecoded())
        let input = DecoderFrameDescriptor.make(pixelBuffer: decoded.pixelBuffer.buffer, metadata: decoded.metadata,
            sourceID: 1, generation: 1)
        let output = try await reference.process(EngineInput(input))
        #expect(output.contentKind == .enhanced)
        let cached = try await cache.read(leases[index < 3 ? 0 : 1], frameIndex: index < 3 ? index : index - 3)
        #expect(cached.timing.presentationTime == (try HDRCacheTime(value: input.pts.value, timescale: input.pts.timescale)))
        #expect(CVPixelBufferLockBaseAddress(output.buffer, .readOnly) == kCVReturnSuccess)
        let address = try #require(CVPixelBufferGetBaseAddress(output.buffer))
        let stride = CVPixelBufferGetBytesPerRow(output.buffer)
        for y in 0..<192 {
            let row = address.advanced(by: y * stride).assumingMemoryBound(to: Float16.self)
            for x in 0..<(320 * 4) {
                let actual = Float(row[x]), stored = cached.rgba[y * 320 * 4 + x]
                let error = abs(actual - stored)
                maxAbsoluteError = max(maxAbsoluteError, error)
                maxRelativeError = max(maxRelativeError, error / max(1, abs(actual), abs(stored)))
            }
        }
        CVPixelBufferUnlockBaseAddress(output.buffer, .readOnly)
    }
    for lease in leases { await cache.release(lease) }
    await reader.cancel(); await reference.resetHistory()
    print("Prepared NR equivalence: 9 frames, max absolute error \(maxAbsoluteError) nits, normalized error \(maxRelativeError)")
    #expect(maxRelativeError <= 0.002)
}

private extension Array where Element: Sendable {
    func asyncMap<T: Sendable>(_ body: (Element) async throws -> T) async rethrows -> [T] {
        var output: [T] = []
        for value in self { output.append(try await body(value)) }
        return output
    }
}
