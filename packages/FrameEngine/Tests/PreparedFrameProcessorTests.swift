import CFrameEngine
import CoreVideo
import DLSSMedia
import Foundation
import Metal
import Testing
@testable import FrameEngine

private let preparedFixture = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("assets/test-clips/hdr10-30.mp4")

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil && FileManager.default.fileExists(atPath: preparedFixture.path),
               "Requires generated PQ fixture and Metal"))
func preparedPlaybackUsesExactCachedPTSAndResetsWithoutNeuralHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = try PreparedHDRContext(request: .init(sourcePath: preparedFixture.path,
        cacheDirectory: directory.path, capacityBytes: 64 * 1024 * 1024,
        rangeStart: .init(value: 0, timescale: 30), rangeEnd: .init(value: 6, timescale: 30),
        segmentFrames: 3, prerollFrames: 1), configuration: .init(processingWidth: 32, processingHeight: 24, strength: 0))
    try await context.waitUntilReady()
    await context.start(); await context.wait()
    #expect(context.status.snapshot().jobState == "complete")
    #expect(context.status.snapshot().completedSegments == 2)
    let processor = PreparedFrameProcessor(context: context)
    let reader = try await NativeHDRVideoReader(url: preparedFixture)
    var first: NativeHDRDecodedFrame?
    for index in 0..<6 {
        let decoded = try #require(try await reader.nextDecoded())
        if index == 0 { first = decoded }
        let descriptor = DecoderFrameDescriptor.make(pixelBuffer: decoded.pixelBuffer.buffer, metadata: decoded.metadata,
            sourceID: 1, generation: 10)
        let output = try await processor.process(EngineInput(descriptor))
        #expect(output.colour.transfer == FE_LINEAR.rawValue)
        #expect(output.contentKind == .preparedOriginal)
        #expect(output.completedStageWallSeconds["prepared_cache_read"] != nil)
        #expect(CVPixelBufferGetPixelFormatType(output.buffer) == kCVPixelFormatType_64RGBAHalf)
        CVPixelBufferLockBaseAddress(output.buffer, .readOnly)
        let address = try #require(CVPixelBufferGetBaseAddress(output.buffer))
        let row = address.assumingMemoryBound(to: Float16.self)
        #expect(UnsafeBufferPointer(start: row, count: 320 * 4).contains(where: { $0 > 203 }))
        CVPixelBufferUnlockBaseAddress(output.buffer, .readOnly)
    }
    #expect(context.status.snapshot().cacheHits == 6)
    #expect(context.status.snapshot().cacheMisses == 0)
    await processor.resetHistory()
    let repeated = try #require(first)
    let descriptor = DecoderFrameDescriptor.make(pixelBuffer: repeated.pixelBuffer.buffer, metadata: repeated.metadata,
        sourceID: 1, generation: 11)
    _ = try await processor.process(EngineInput(descriptor))
    #expect(context.status.snapshot().lastGeneration == 11)
    #expect(context.status.snapshot().cacheHits == 7)
    let outside = try #require(try await reader.nextDecoded())
    let fallback = try await processor.process(EngineInput(DecoderFrameDescriptor.make(pixelBuffer: outside.pixelBuffer.buffer,
        metadata: outside.metadata, sourceID: 1, generation: 11)))
    #expect(fallback.contentKind == .original)
    #expect(context.status.snapshot().cacheMisses == 1)
    #expect(context.status.snapshot().lastOutput == "original")
    await reader.cancel(); await processor.resetHistory()
    await context.start(); await context.wait()
    #expect(context.status.snapshot().reusedSegments == 2)
    #expect(context.status.snapshot().processedFrames == 0)
    await context.cancel()
    #expect(context.status.snapshot().isIdle)
}

@Test func preparedControlRejectsInvalidRanges() throws {
    #expect(throws: (any Error).self) {
        _ = try PreparedHDRContext(request: .init(sourcePath: "/tmp/source.mp4", cacheDirectory: "/tmp/cache",
            capacityBytes: 1024, segmentFrames: 0), configuration: .init())
    }
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: preparedFixture.path), "Requires PQ fixture"))
func preparedCControlsBindOpenedSourceAndCancelAnImmediateStart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = PreparedHDRRequest(sourcePath: preparedFixture.path, cacheDirectory: directory.path,
        capacityBytes: 64 * 1024 * 1024, rangeStart: try .init(value: 0, timescale: 30),
        rangeEnd: try .init(value: 6, timescale: 30), segmentFrames: 3)
    let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    var config = fe_config()
    config.struct_size = UInt32(MemoryLayout<fe_config>.size); config.abi_version = UInt32(FE_ABI_VERSION)
    config.max_in_flight = 3; config.memory_limit_bytes = 512 * 1024 * 1024
    config.processing_width = 32; config.processing_height = 24
    config.reference_white_nits = 203; config.colour_strength = 1; config.maximum_luminance_ratio = 2
    var error = [CChar](repeating: 0, count: 2048)
    let wrong = json.withCString { value in
        "/tmp/a-different-opened-source.mp4".withCString { path in fePreparedCreate(&config, value, path, &error, error.count) }
    }
    #expect(wrong == nil)
    let handle = try #require(json.withCString { value in
        preparedFixture.path.withCString { path in fePreparedCreate(&config, value, path, &error, error.count) }
    })
    defer { fePreparedDestroy(handle) }
    #expect(fePreparedStart(handle) == Int32(FE_ACCEPTED.rawValue))
    fePreparedCancel(handle)
    for _ in 0..<500 where fePreparedIsIdle(handle) == 0 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(fePreparedIsIdle(handle) == 1)
    let size = fePreparedProgressJSON(handle, nil, 0)
    var bytes = [CChar](repeating: 0, count: size)
    #expect(fePreparedProgressJSON(handle, &bytes, size) <= size)
    let value = try JSONSerialization.jsonObject(with: Data(bytes.dropLast().map { UInt8(bitPattern: $0) })) as? [String: Any]
    #expect(value?["jobState"] as? String == "cancelled")
    #expect(value?["processedFrames"] as? Int == 0)
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: preparedFixture.path), "Requires PQ fixture"))
func preparedReplacementSharesCacheAndRejectsChangedSource() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.mp4")
    try FileManager.default.copyItem(at: preparedFixture, to: source)
    let request = PreparedHDRRequest(sourcePath: source.path, cacheDirectory: directory.appendingPathComponent("cache").path,
        capacityBytes: 64 * 1024 * 1024, rangeStart: try .init(value: 0, timescale: 30),
        rangeEnd: try .init(value: 6, timescale: 30), segmentFrames: 3)
    let first = try PreparedHDRContext(request: request, configuration: .init(processingWidth: 32, processingHeight: 24))
    let replacement = try PreparedHDRContext(request: request, configuration: .init(processingWidth: 16, processingHeight: 16))
    async let one: Void = first.waitUntilReady()
    async let two: Void = replacement.waitUntilReady()
    _ = try await (one, two)
    #expect(first.status.snapshot().configurationState == "ready")
    #expect(replacement.status.snapshot().configurationState == "ready")
    let file = try FileHandle(forWritingTo: source)
    try file.seekToEnd(); try file.write(contentsOf: Data([0])); try file.close()
    var pixels: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 320, 192, kCVPixelFormatType_64RGBAHalf, nil, &pixels) == kCVReturnSuccess)
    let buffer = try #require(pixels)
    var descriptor = fe_frame()
    descriptor.pixel_buffer = Unmanaged.passUnretained(buffer).toOpaque()
    descriptor.pixel_format = kCVPixelFormatType_64RGBAHalf
    descriptor.pts = fe_time(value: 0, timescale: 30); descriptor.duration = fe_time(value: 1, timescale: 30)
    descriptor.geometry.width = 320; descriptor.geometry.height = 192
    do {
        _ = try await PreparedFrameProcessor(context: first).process(EngineInput(descriptor))
        Issue.record("A mutated source must never produce a cache hit")
    } catch FrameEngineError.invalid(let reason) {
        #expect(reason.contains("source changed"))
    }
    #expect(first.status.snapshot().configurationState == "failed")
    #expect(first.status.snapshot().cacheHits == 0)
    await first.cancel(); await replacement.cancel()
}
