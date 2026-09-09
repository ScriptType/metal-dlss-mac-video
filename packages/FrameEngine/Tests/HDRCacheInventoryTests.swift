import Foundation
import FrameEngine
import Testing

private func inventoryTime(_ value: Int64, _ scale: Int32 = 1000) throws -> HDRCacheTime {
    try .init(value: value, timescale: scale)
}

private func inventoryIdentity(_ timings: [HDRCacheFrameTiming]) throws -> HDRCacheIdentity {
    try HDRCacheIdentity(source: .init(contentSHA256: String(repeating: "a", count: 64), byteCount: 4, streamIndex: 0),
        range: .init(start: timings[0].presentationTime, end: inventoryTime(120)),
        settings: .init(modelSHA256: String(repeating: "b", count: 64), implementationVersion: "inventory-test-v1",
            processingWidth: 1, processingHeight: 1, outputWidth: 1, outputHeight: 1, colourPolicy: ["storage": HDRSegmentCache.storagePolicy]),
        preroll: .init(start: inventoryTime(0), policyVersion: "reset-v1"),
        timingInventorySHA256: HDRCacheFrameTiming.inventoryDigest(timings))
}

@Test func cacheExactInventoryPreservesMillisecondPTSAndUnequalDurationsAcrossRecovery() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-inventory-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try await HDRSegmentCache.open(directory: directory, capacityBytes: 1_048_576)
    // Coarse container ticks overlap/gap nominal durations, then a VFR duration.
    // Final frame extends beyond the next segment's PTS=120ms; keep both exact.
    let timings = try [(Int64(0), Int64(1), Int32(30)), (33, 1, 30), (67, 70, 1000)].map {
        try HDRCacheFrameTiming(presentationTime: inventoryTime($0.0), duration: inventoryTime($0.1, $0.2))
    }
    let identity = try inventoryIdentity(timings)
    let writer = try await cache.begin(identity: identity, expectedFrameCount: timings.count)
    for timing in timings { try await cache.append(.init(timing: timing, rgba: [-0.1, 203, 2000, 1]), to: writer) }
    let manifest = try await cache.publish(writer)
    #expect(manifest.schemaVersion == 2)
    #expect(manifest.frames.map(\.timing) == timings)
    try await cache.recover()
    let lease = try #require(try await cache.acquire(identity: identity))
    for index in timings.indices {
        #expect(try await cache.read(lease, frameIndex: index).timing == timings[index])
    }
    await cache.release(lease)
    #expect(try await cache.completedRanges(source: identity.source, settings: identity.settings).count == 1)

    // The digest binds the complete inventory even if a tampered manifest removes
    // a middle record and repairs every ordinal/file name consistently.
    let manifestURL = directory.appendingPathComponent("segments/\(manifest.key)/manifest.json")
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    var frames = try #require(object["frames"] as? [[String: Any]])
    frames.removeLast(); object["frames"] = frames
    try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
    await #expect(throws: HDRCacheError.self) { try await cache.acquire(identity: identity) }
    #expect(try await cache.acquire(identity: identity) == nil)
}

@Test func cacheExactInventoryRejectsMissingOrChangedEntriesBeforePublication() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-inventory-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try await HDRSegmentCache.open(directory: directory, capacityBytes: 1_048_576)
    let timings = try [Int64(0), 33, 67].map {
        try HDRCacheFrameTiming(presentationTime: inventoryTime($0), duration: inventoryTime(1, 30))
    }
    let identity = try inventoryIdentity(timings)
    let incomplete = try await cache.begin(identity: identity, expectedFrameCount: 2)
    for timing in [timings[0], timings[2]] { try await cache.append(.init(timing: timing, rgba: [0, 203, 1000, 1]), to: incomplete) }
    await #expect(throws: HDRCacheError.self) { try await cache.publish(incomplete) }
    #expect(try await cache.acquire(identity: identity) == nil)
    try await cache.cancel(incomplete)
    let wrongDuration = try await cache.begin(identity: identity, expectedFrameCount: 3)
    for timing in timings {
        let changed = try HDRCacheFrameTiming(presentationTime: timing.presentationTime, duration: inventoryTime(33))
        try await cache.append(.init(timing: changed, rgba: [0, 203, 1000, 1]), to: wrongDuration)
    }
    await #expect(throws: HDRCacheError.self) { try await cache.publish(wrongDuration) }
    try await cache.cancel(wrongDuration)
    #expect(try await cache.usage().completedSegments == 0)
}

@Test func cacheInventoryCanonicalizesRationalsAndKeepsLegacyIdentityEncoding() throws {
    let first = try HDRCacheFrameTiming(presentationTime: inventoryTime(33), duration: inventoryTime(1, 30))
    let equivalent = try HDRCacheFrameTiming(presentationTime: inventoryTime(66, 2000), duration: inventoryTime(2, 60))
    #expect(try HDRCacheFrameTiming.inventoryDigest([first]) == HDRCacheFrameTiming.inventoryDigest([equivalent]))
    #expect(throws: HDRCacheError.self) { try HDRCacheFrameTiming.inventoryDigest([first, first]) }
    var identity = try inventoryIdentity([.init(presentationTime: inventoryTime(0), duration: inventoryTime(120))])
    identity.timingInventorySHA256 = nil
    let data = try JSONEncoder().encode(identity)
    #expect(!String(decoding: data, as: UTF8.self).contains("timingInventory"))
    #expect(try JSONDecoder().decode(HDRCacheIdentity.self, from: data) == identity)
}
