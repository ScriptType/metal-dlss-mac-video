import CryptoKit
import Foundation
import Metal
import Testing
@testable import FrameEngine

private let preparationFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("assets/test-clips/hdr10-30.mp4")

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil && FileManager.default.fileExists(atPath: preparationFixture.path),
               "Requires generated PQ fixture and Metal"))
func preparationCancelsStagingResumesAndPairsAcrossSegments() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try await HDRSegmentCache.open(directory: directory, capacityBytes: 64 * 1024 * 1024)
    let hash = SHA256.hash(data: Data("original-hdr-v1".utf8)).map { String(format: "%02x", $0) }.joined()
    let source = try HDRCacheSource.fingerprint(url: preparationFixture, streamIndex: 0)
    let settings = HDRCacheSettings(modelSHA256: hash, implementationVersion: "preparation-test-v1",
        processingWidth: 32, processingHeight: 24, outputWidth: 320, outputHeight: 192,
        colourPolicy: ["storage": HDRSegmentCache.storagePolicy],
        effects: ["strength": 0, "colourStrength": 1, "maximumLuminanceRatio": 2])
    func segment(_ first: Int64, _ end: Int64) throws -> HDRPreparationSegment {
        try .init(identity: .init(source: source,
            range: .init(start: .init(value: first, timescale: 30), end: .init(value: end, timescale: 30)),
            settings: settings, preroll: .init(start: .init(value: 0, timescale: 30), policyVersion: "reset-decode-all-from-preroll-v1")),
            frameCount: Int(end - first))
    }
    let coordinator = HDRPreparationCoordinator(cache: cache, configuration: .init(modelVersion: hash,
        processingWidth: 32, processingHeight: 24, strength: 0))
    try await coordinator.start(sourceURL: preparationFixture, segments: [segment(0, 60)])
    try await Task.sleep(for: .milliseconds(10))
    await coordinator.cancel()
    #expect(await coordinator.progress().state == .cancelled)
    #expect(try await cache.usage().stagedSegments == 0)
    let segments = try [segment(0, 3), segment(3, 6)]
    try await coordinator.start(sourceURL: preparationFixture, segments: segments)
    try await coordinator.wait()
    let prepared = await coordinator.progress()
    #expect(prepared.state == .complete)
    #expect(prepared.completedSegments == 2)
    #expect(prepared.processedFrames == 6)
    #expect(prepared.completedRanges == segments.map { $0.identity.range })
    for segment in segments {
        let lease = try #require(try await cache.acquire(identity: segment.identity))
        let frame = try await cache.read(lease, frameIndex: 0)
        #expect(frame.timing.presentationTime == segment.identity.range.start)
        #expect((frame.rgba.max() ?? 0) > 203)
        await cache.release(lease)
    }
    try await coordinator.start(sourceURL: preparationFixture, segments: segments)
    try await coordinator.wait()
    let resumed = await coordinator.progress()
    #expect(resumed.reusedSegments == 2)
    #expect(resumed.processedFrames == 0)
    #expect(try await cache.usage().byteCount <= 64 * 1024 * 1024)
}
