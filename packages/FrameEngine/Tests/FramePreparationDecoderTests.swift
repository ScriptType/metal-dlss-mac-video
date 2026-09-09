import CFrameEngine
import CoreVideo
import Foundation
@testable import FrameEngine
import Testing

private final class DecoderFixture: @unchecked Sendable {
    let condition = NSCondition()
    var opens = 0, closes = 0, retains = 0, releases = 0, frameRetains = 0, frameReleases = 0
    var waiting = false, cancelled = false, block = false
    let pts: [Int64] = [0, 33, 67, 100, 133, 167]
    func locked<T>(_ body: () -> T) -> T { condition.lock(); defer { condition.unlock() }; return body() }
}
private final class DecoderFixtureReader {
    let fixture: DecoderFixture, mode: UInt32
    var index = 0
    var buffer: CVPixelBuffer?
    init(_ fixture: DecoderFixture, mode: UInt32) { self.fixture = fixture; self.mode = mode }
}
private func fixture(_ pointer: UnsafeMutableRawPointer) -> DecoderFixture {
    Unmanaged<DecoderFixture>.fromOpaque(pointer).takeUnretainedValue()
}
private func fixtureReader(_ pointer: UnsafeMutableRawPointer) -> DecoderFixtureReader {
    Unmanaged<DecoderFixtureReader>.fromOpaque(pointer).takeUnretainedValue()
}
private func fixtureProvider(_ owner: DecoderFixture) throws -> CFramePreparationProvider {
    var callbacks = fe_preparation_decoder_provider()
    callbacks.struct_size = UInt32(MemoryLayout<fe_preparation_decoder_provider>.size)
    callbacks.abi_version = UInt32(FE_ABI_VERSION)
    callbacks.user = Unmanaged.passUnretained(owner).toOpaque()
    callbacks.retain_user = { pointer in
        guard let pointer else { return }; fixture(pointer).locked { fixture(pointer).retains += 1 }
        _ = Unmanaged<DecoderFixture>.fromOpaque(pointer).retain()
    }
    callbacks.release_user = { pointer in
        guard let pointer else { return }; fixture(pointer).locked { fixture(pointer).releases += 1 }
        Unmanaged<DecoderFixture>.fromOpaque(pointer).release()
    }
    callbacks.open = { user, _, _, _, _, mode, _, _ in
        guard let user else { return nil }
        let fixture = fixture(user)
        fixture.locked { fixture.opens += 1 }
        return Unmanaged.passRetained(DecoderFixtureReader(fixture, mode: mode)).toOpaque()
    }
    callbacks.next = { pointer, output, _, _ in
        guard let pointer, let output else { return FE_FAILED }
        let reader = fixtureReader(pointer), fixture = reader.fixture
        fixture.condition.lock()
        if fixture.block {
            fixture.waiting = true; fixture.condition.broadcast()
            while !fixture.cancelled { fixture.condition.wait() }
        }
        let cancelled = fixture.cancelled
        fixture.condition.unlock()
        if cancelled { return FE_CANCELLED }
        if reader.index == fixture.pts.count { return FE_EMPTY }
        var frame = fe_frame()
        frame.struct_size = UInt32(MemoryLayout<fe_frame>.size); frame.abi_version = UInt32(FE_ABI_VERSION)
        frame.pts = fe_time(value: fixture.pts[reader.index], timescale: 1000)
        frame.duration = fe_time(value: 1, timescale: 30)
        frame.geometry.width = 4; frame.geometry.height = 2
        frame.geometry.crop_width = 4; frame.geometry.crop_height = 2
        frame.geometry.pixel_aspect_num = 1; frame.geometry.pixel_aspect_den = 1
        if reader.mode == FE_PREPARATION_PIXELS.rawValue {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 4, 2, kCVPixelFormatType_64RGBAHalf,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess else { return FE_FAILED }
            reader.buffer = buffer
            frame.pixel_buffer = Unmanaged.passUnretained(buffer!).toOpaque()
            frame.owner = Unmanaged.passUnretained(fixture).toOpaque()
            frame.retain_owner = { pointer in
                guard let pointer else { return }; let value = Unmanaged<DecoderFixture>.fromOpaque(pointer)
                value.takeUnretainedValue().locked { value.takeUnretainedValue().frameRetains += 1 }; _ = value.retain()
            }
            frame.release_owner = { pointer in
                guard let pointer else { return }; let value = Unmanaged<DecoderFixture>.fromOpaque(pointer)
                value.takeUnretainedValue().locked { value.takeUnretainedValue().frameReleases += 1 }; value.release()
            }
        }
        output.pointee = frame; reader.index += 1
        return FE_ACCEPTED
    }
    callbacks.cancel = { pointer in
        guard let pointer else { return }; let fixture = fixtureReader(pointer).fixture
        fixture.locked { fixture.cancelled = true; fixture.condition.broadcast() }
    }
    callbacks.close = { pointer in
        guard let pointer else { return }; let fixture = fixtureReader(pointer).fixture
        fixture.locked { fixture.closes += 1 }
        Unmanaged<DecoderFixtureReader>.fromOpaque(pointer).release()
    }
    return try "fixture-decoded-exact-v1".withCString {
        callbacks.identifier = $0
        return try withUnsafePointer(to: &callbacks) { try CFramePreparationProvider($0) }
    }
}

@Test func preparationProviderPlansExactBoundariesAndPrerollWithoutDurationRounding() async throws {
    let fixture = DecoderFixture()
    var provider: CFramePreparationProvider? = try fixtureProvider(fixture)
    let inventory = try await provider!.inventory(sourceURL: URL(fileURLWithPath: "/unused"), videoStreamIndex: 0)
    #expect(inventory.width == 4 && inventory.height == 2)
    #expect(inventory.timings.map { $0.presentationTime } == (try fixture.pts.map { try HDRCacheTime(value: $0, timescale: 1000) }))
    let segments = try inventory.segments(source: .init(contentSHA256: String(repeating: "a", count: 64), byteCount: 1, streamIndex: 0),
        settings: .init(modelSHA256: String(repeating: "b", count: 64), implementationVersion: "test-v1",
            processingWidth: 4, processingHeight: 2, outputWidth: 4, outputHeight: 2, colourPolicy: ["storage": HDRSegmentCache.storagePolicy]),
        segmentFrames: 3, prerollFrames: 2)
    #expect(segments.count == 2)
    #expect(segments[0].identity.range.end == inventory.timings[3].presentationTime)
    #expect(segments[1].identity.range.start == segments[0].identity.range.end)
    #expect(segments[1].identity.preroll.start == inventory.timings[1].presentationTime)
    #expect(segments[1].decodeTimings == inventory.timings[1...])
    #expect(try segments[0].identity.timingInventorySHA256 == HDRCacheFrameTiming.inventoryDigest(Array(inventory.timings[..<3])))
    provider = nil
    // The queue closure can release its captured provider just after resuming
    // the awaiting task; owner destruction is not an immediate-return promise.
    for _ in 0..<1000 {
        if fixture.locked({ fixture.releases == 1 }) { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(fixture.locked { fixture.opens } == 1)
    #expect(fixture.locked { fixture.closes } == 1)
    #expect(fixture.locked { fixture.retains } == 1)
    #expect(fixture.locked { fixture.releases } == 1)
}

@Test func preparationProviderRetainsBorrowedPixelsThroughReaderClose() async throws {
    let fixture = DecoderFixture(), provider = try fixtureProvider(fixture)
    let reader = try await provider.decoder(sourceURL: URL(fileURLWithPath: "/unused"), videoStreamIndex: 0,
        range: .init(start: .init(value: 0, timescale: 1), end: .init(value: 1, timescale: 1)))
    var frame = try await reader.next()
    try #require(frame != nil)
    await reader.cancel()
    #expect(fixture.locked { fixture.closes == 1 && fixture.frameRetains == 1 && fixture.frameReleases == 0 })
    #expect(CVPixelBufferGetWidth(frame!.pixelBuffer) == 4)
    frame = nil
    #expect(fixture.locked { fixture.frameReleases == 1 })
    await reader.cancel()
    #expect(fixture.locked { fixture.closes == 1 })
}

@Test func preparationProviderCancellationInterruptsBlockedNextAndClosesOnce() async throws {
    let fixture = DecoderFixture(); fixture.block = true
    let provider = try fixtureProvider(fixture)
    let task = Task { try await provider.inventory(sourceURL: URL(fileURLWithPath: "/unused"), videoStreamIndex: 0) }
    for _ in 0..<1000 {
        if fixture.locked({ fixture.waiting }) { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(fixture.locked { fixture.waiting })
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled inventory unexpectedly completed") }
    catch { #expect(error is CancellationError) }
    #expect(fixture.locked { fixture.cancelled && fixture.opens == 1 && fixture.closes == 1 })
}

@Test func preparationContextCancelsInventoryAndCanInitializeAgain() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-provider-context-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.mkv")
    try Data([1, 2, 3]).write(to: source)
    let fixture = DecoderFixture(); fixture.block = true
    let context = try PreparedHDRContext(request: .init(sourcePath: source.path,
        cacheDirectory: directory.appendingPathComponent("cache").path, capacityBytes: 1_048_576),
        configuration: .init(processingWidth: 4, processingHeight: 2, strength: 0),
        decoderProvider: fixtureProvider(fixture))
    context.initializeInBackground()
    for _ in 0..<1000 {
        if fixture.locked({ fixture.waiting }) { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(fixture.locked { fixture.waiting })
    await context.cancel()
    #expect(context.status.snapshot().isIdle)
    #expect(context.status.snapshot().jobState == "cancelled")
    fixture.locked { fixture.block = false; fixture.cancelled = false }
    try await context.waitUntilReady()
    #expect(context.status.snapshot().configurationState == "ready")
    #expect(fixture.locked { fixture.opens == 2 && fixture.closes == 2 })
    await context.cancel()
}

@Test func preparationImmediateCancelCannotRestartQueuedInitialization() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-provider-immediate-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.mkv")
    try Data([1, 2, 3]).write(to: source)
    for index in 0..<20 {
        let fixture = DecoderFixture()
        let context = try PreparedHDRContext(request: .init(sourcePath: source.path,
            cacheDirectory: directory.appendingPathComponent("cache-\(index)").path, capacityBytes: 1_048_576),
            configuration: .init(processingWidth: 4, processingHeight: 2, strength: 0),
            decoderProvider: fixtureProvider(fixture))
        context.initializeInBackground()
        await context.cancel()
        let cancelledState = context.status.snapshot().configurationState
        try await Task.sleep(for: .milliseconds(1))
        #expect(context.status.snapshot().isIdle)
        #expect(context.status.snapshot().configurationState == cancelledState)
        #expect(context.status.snapshot().jobState == "cancelled")
        #expect(fixture.locked { fixture.opens == fixture.closes })
    }
}
