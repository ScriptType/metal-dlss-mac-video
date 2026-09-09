import Foundation
import FrameEngine
import Testing

private func cacheTime(_ value: Int64, _ scale: Int32 = 24) throws -> HDRCacheTime {
    try HDRCacheTime(value: value, timescale: scale)
}

private func cacheIdentity(start: Int64 = 0, frames: Int64 = 2) throws -> HDRCacheIdentity {
    HDRCacheIdentity(
        source: HDRCacheSource(contentSHA256: String(repeating: "a", count: 64), byteCount: 100, streamIndex: 0),
        range: try HDRCacheRange(start: cacheTime(start), end: cacheTime(start + frames)),
        settings: HDRCacheSettings(modelSHA256: String(repeating: "b", count: 64), implementationVersion: "test-v1",
                                   processingWidth: 8, processingHeight: 8, outputWidth: 8, outputHeight: 8,
                                   colourPolicy: ["working": "linear-bt2020-absolute-nits", "referenceWhiteNits": "203"],
                                   guides: ["motion": "full"], effects: ["strength": 1]),
        preroll: HDRCachePreroll(start: try cacheTime(0), policyVersion: "reset-at-source-start-v1"))
}

private func cachePixels() -> [Float] {
    // Includes negative reconstruction excursions, exact float32 dark values, BT.2020 saturated
    // colours and highlights well above 203-nit reference white.
    (0..<64).flatMap { pixel -> [Float] in
        let luminances: [Float] = [-0.25, 0, 0.0001, 0.1, 100, 203, 1_000, 10_000]
        let value = luminances[pixel % luminances.count]
        return [value, pixel % 2 == 0 ? value : 0, pixel % 3 == 0 ? value : 0, 1]
    }
}

private func cacheDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-cache-tests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeSegment(_ cache: HDRSegmentCache, identity: HDRCacheIdentity, frames: Int = 2) async throws -> HDRCacheManifest {
    let writer = try await cache.begin(identity: identity, expectedFrameCount: frames)
    var time = identity.range.start
    for _ in 0..<frames {
        let timing = try HDRCacheFrameTiming(presentationTime: time, duration: cacheTime(1))
        try await cache.append(HDRCacheFloatFrame(timing: timing, rgba: cachePixels()), to: writer)
        time = try timing.end
    }
    return try await cache.publish(writer)
}

@Test func cacheIdentityUsesExactCanonicalRationalsAndAllSettings() throws {
    let identity = try cacheIdentity()
    var equivalent = identity
    equivalent.range = try HDRCacheRange(start: cacheTime(0, 48), end: cacheTime(4, 48))
    #expect(try identity.key() == equivalent.key())
    #expect(try cacheTime(Int64.min, 1) < cacheTime(Int64.max, Int32.max))
    var mutations: [HDRCacheIdentity] = []
    var variant = identity
    variant.source.contentSHA256 = String(repeating: "c", count: 64); mutations.append(variant)
    variant = identity; variant.source.streamIndex = 1; mutations.append(variant)
    variant = identity; variant.source.interpretation["rotation"] = "90"; mutations.append(variant)
    variant = identity; variant.settings.modelSHA256 = String(repeating: "d", count: 64); mutations.append(variant)
    variant = identity; variant.settings.processingWidth = 16; mutations.append(variant)
    variant = identity; variant.settings.outputHeight = 16; mutations.append(variant)
    variant = identity; variant.settings.implementationVersion = "v2"; mutations.append(variant)
    variant = identity; variant.settings.effects["strength"] = 0.5; mutations.append(variant)
    variant = identity; variant.settings.colourPolicy["referenceWhiteNits"] = "100"; mutations.append(variant)
    variant = identity; variant.settings.guides["motion"] = "half"; mutations.append(variant)
    variant = identity; variant.settings.execution["precision"] = "float16"; mutations.append(variant)
    variant = identity; variant.preroll.randomSeed = 1; mutations.append(variant)
    variant = identity; variant.preroll.policyVersion = "v2"; mutations.append(variant)
    variant = identity; variant.preroll.start = try cacheTime(-1); mutations.append(variant)
    for variant in mutations { #expect(try variant.key() != identity.key()) }
    #expect(Set(try mutations.map { try $0.key() }).count == mutations.count)
}

@Test func cacheRejectsInvalidIdentityAndOverflow() throws {
    #expect(throws: HDRCacheError.self) { try HDRCacheTime(value: 1, timescale: 0) }
    #expect(throws: HDRCacheError.self) { try cacheTime(Int64.max, 1).adding(cacheTime(1, 1)) }
    var identity = try cacheIdentity()
    identity.settings.effects["strength"] = .nan
    #expect(throws: HDRCacheError.self) { try identity.key() }
    identity = try cacheIdentity()
    identity.preroll.start = try cacheTime(1)
    #expect(throws: HDRCacheError.self) { try identity.key() }
}

@Test func cacheFloatRoundTripPreservesHDRBitsAndTiming() async throws {
    let directory = try cacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try HDRSegmentCache(directory: directory, capacityBytes: 1_048_576)
    try await cache.recover()
    let identity = try cacheIdentity()
    let manifest = try await writeSegment(cache, identity: identity)
    #expect(manifest.storagePolicy == HDRSegmentCache.storagePolicy)
    let lease = try #require(try await cache.acquire(identity: identity))
    for index in 0..<2 {
        let frame = try await cache.read(lease, frameIndex: index)
        #expect(frame.rgba.map(\.bitPattern) == cachePixels().map(\.bitPattern))
        #expect(frame.timing.presentationTime == (try cacheTime(Int64(index))))
    }
    await cache.release(lease)
    let ranges = try await cache.completedRanges(source: identity.source, settings: identity.settings)
    #expect(ranges.count == 1)
    #expect(ranges.first?.range == identity.range)
    #expect(ranges.first?.preroll == identity.preroll)
    var changed = identity
    changed.settings.effects["strength"] = 0
    #expect(try await cache.acquire(identity: changed) == nil)
}

@Test func stagedAndInterruptedSegmentsNeverBecomePlayable() async throws {
    let directory = try cacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try HDRSegmentCache(directory: directory, capacityBytes: 1_048_576)
    try await cache.recover()
    let identity = try cacheIdentity()
    let writer = try await cache.begin(identity: identity, expectedFrameCount: 2)
    try await cache.append(HDRCacheFloatFrame(timing: HDRCacheFrameTiming(presentationTime: cacheTime(0), duration: cacheTime(1)),
                                             rgba: cachePixels()), to: writer)
    #expect(try await cache.acquire(identity: identity) == nil)
    await #expect(throws: HDRCacheError.self) { try await cache.publish(writer) }
    #expect(try await cache.completedRanges(source: identity.source, settings: identity.settings).isEmpty)
    try await cache.cancel(writer)
    // A terminated process may leave arbitrary partial files in staging. Recovery removes these,
    // while rebuilding the completed range index from validated, atomically published directories.
    _ = try await writeSegment(cache, identity: identity)
    let abandoned = directory.appendingPathComponent("staging/abandoned")
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: abandoned.appendingPathComponent("partial.rgba32f"))
    try await cache.recover()
    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
    #expect(try await cache.completedRanges(source: identity.source, settings: identity.settings).count == 1)
}

@Test func cacheValidatesContiguousVFRRanges() async throws {
    let directory = try cacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try HDRSegmentCache(directory: directory, capacityBytes: 1_048_576)
    try await cache.recover()
    var identity = try cacheIdentity()
    identity.range = try HDRCacheRange(start: cacheTime(0), end: cacheTime(100, 1_000))
    let writer = try await cache.begin(identity: identity, expectedFrameCount: 3)
    for (start, duration): (Int64, Int64) in [(0, 33), (33, 17), (50, 50)] {
        let timing = try HDRCacheFrameTiming(presentationTime: cacheTime(start, 1_000), duration: cacheTime(duration, 1_000))
        try await cache.append(HDRCacheFloatFrame(timing: timing, rgba: cachePixels()), to: writer)
    }
    let manifest = try await cache.publish(writer)
    #expect(manifest.frames.count == 3)
    #expect(try manifest.frames.last?.timing.end == cacheTime(1, 10))
}

@Test func cacheRejectsGapsWrongPixelCountsAndNonfiniteValues() async throws {
    let directory = try cacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try HDRSegmentCache(directory: directory, capacityBytes: 1_048_576)
    try await cache.recover()
    let writer = try await cache.begin(identity: cacheIdentity(), expectedFrameCount: 2)
    let gap = try HDRCacheFrameTiming(presentationTime: cacheTime(1), duration: cacheTime(1))
    await #expect(throws: HDRCacheError.self) { try await cache.append(HDRCacheFloatFrame(timing: gap, rgba: cachePixels()), to: writer) }
    let timing = try HDRCacheFrameTiming(presentationTime: cacheTime(0), duration: cacheTime(1))
    await #expect(throws: HDRCacheError.self) { try await cache.append(HDRCacheFloatFrame(timing: timing, rgba: [1]), to: writer) }
    var pixels = cachePixels(); pixels[0] = .infinity
    let nonfinite = HDRCacheFloatFrame(timing: timing, rgba: pixels)
    await #expect(throws: HDRCacheError.self) { try await cache.append(nonfinite, to: writer) }
    #expect(try await cache.usage().byteCount == 0)
    try await cache.cancel(writer)
}

@Test func cacheRejectsCorruptionBeforeLeaseAndOnRecovery() async throws {
    let directory = try cacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try HDRSegmentCache(directory: directory, capacityBytes: 1_048_576)
    try await cache.recover()
    let identity = try cacheIdentity()
    let manifest = try await writeSegment(cache, identity: identity)
    let file = directory.appendingPathComponent("segments/\(manifest.key)/\(manifest.frames[0].fileName)")
    var data = try Data(contentsOf: file); data[0] ^= 255; try data.write(to: file)
    await #expect(throws: HDRCacheError.self) { try await cache.acquire(identity: identity) }
    #expect(try await cache.acquire(identity: identity) == nil)
    _ = try await writeSegment(cache, identity: identity)
    try Data([1]).write(to: file)
    try await cache.recover()
    #expect(try await cache.usage().completedSegments == 0)
    #expect(try await cache.usage().byteCount == 0)
}

@Test func cacheValidatesStagingBeforeAtomicPublication() async throws {
    let directory = try cacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try await HDRSegmentCache.open(directory: directory, capacityBytes: 1_048_576)
    let identity = try cacheIdentity()
    let writer = try await cache.begin(identity: identity, expectedFrameCount: 2)
    for index in 0..<2 {
        let timing = try HDRCacheFrameTiming(presentationTime: cacheTime(Int64(index)), duration: cacheTime(1))
        try await cache.append(HDRCacheFloatFrame(timing: timing, rgba: cachePixels()), to: writer)
    }
    let stage = try #require(FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("staging"),
                                                                   includingPropertiesForKeys: nil).first)
    try Data([0]).write(to: stage.appendingPathComponent("00000000.rgba32f"))
    await #expect(throws: HDRCacheError.self) { try await cache.publish(writer) }
    #expect(try await cache.acquire(identity: identity) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("segments").path).isEmpty)
    try await cache.cancel(writer)
    #expect(try await cache.usage().byteCount == 0)
}

@Test func cacheOversizedFramesLeaveNoPublishedOrStagedPayload() async throws {
    let directory = try cacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try await HDRSegmentCache.open(directory: directory, capacityBytes: 100)
    let writer = try await cache.begin(identity: cacheIdentity(), expectedFrameCount: 2)
    let timing = try HDRCacheFrameTiming(presentationTime: cacheTime(0), duration: cacheTime(1))
    await #expect(throws: HDRCacheError.capacityExceeded) {
        try await cache.append(HDRCacheFloatFrame(timing: timing, rgba: cachePixels()), to: writer)
    }
    #expect(try await cache.usage().byteCount == 0)
    try await cache.cancel(writer)
}

@Test func cachePinnedReadersBlockEvictionWithinDiskBudget() async throws {
    let directory = try cacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // A segment is ~4 KB at 8x8 RGBA32F. Determine its exact manifest size separately.
    let measureDirectory = try cacheDirectory()
    defer { try? FileManager.default.removeItem(at: measureDirectory) }
    let measure = try HDRSegmentCache(directory: measureDirectory, capacityBytes: 1_048_576)
    try await measure.recover()
    _ = try await writeSegment(measure, identity: cacheIdentity())
    let segmentBytes = try await measure.usage().byteCount
    let capacity = segmentBytes * 2 - 1
    let cache = try HDRSegmentCache(directory: directory, capacityBytes: capacity)
    try await cache.recover()
    let first = try cacheIdentity()
    _ = try await writeSegment(cache, identity: first)
    let lease = try #require(try await cache.acquire(identity: first))
    let second = try cacheIdentity(start: 2)
    let writer = try await cache.begin(identity: second, expectedFrameCount: 2)
    for index in 2..<4 {
        let timing = try HDRCacheFrameTiming(presentationTime: cacheTime(Int64(index)), duration: cacheTime(1))
        try await cache.append(HDRCacheFloatFrame(timing: timing, rgba: cachePixels()), to: writer)
    }
    await #expect(throws: HDRCacheError.self) { try await cache.publish(writer) }
    #expect(try await cache.usage().byteCount <= capacity)
    #expect(try await cache.read(lease, frameIndex: 0).rgba == cachePixels())
    await cache.release(lease)
    _ = try await cache.publish(writer)
    #expect(try await cache.acquire(identity: first) == nil)
    #expect(try await cache.usage().completedSegments == 1)
    #expect(try await cache.usage().byteCount <= capacity)
}

@Test func cacheSourceFingerprintUsesContentAndSingleDirectoryOwner() throws {
    let directory = try cacheDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.bin")
    try Data([1, 2, 3]).write(to: source)
    let first = try HDRCacheSource.fingerprint(url: source, streamIndex: 0)
    try Data([3, 2, 1]).write(to: source)
    let changed = try HDRCacheSource.fingerprint(url: source, streamIndex: 0)
    #expect(first.byteCount == changed.byteCount)
    #expect(first.contentSHA256 != changed.contentSHA256)
    let cache = try HDRSegmentCache(directory: directory.appendingPathComponent("cache"), capacityBytes: 1_000)
    _ = withExtendedLifetime(cache) {
        #expect(throws: HDRCacheError.cacheInUse) {
            try HDRSegmentCache(directory: directory.appendingPathComponent("cache"), capacityBytes: 1_000)
        }
    }
}
