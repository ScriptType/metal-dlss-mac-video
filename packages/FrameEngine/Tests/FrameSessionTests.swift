import CFrameEngine
import CoreMedia
import CoreVideo
import Foundation
import Metal
import Testing
@testable import FrameEngine

private func fixtureBuffer() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(kCFAllocatorDefault, 4, 2, kCVPixelFormatType_64RGBAHalf,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
    #expect(result == kCVReturnSuccess)
    return try #require(buffer)
}

private func descriptor(_ buffer: CVPixelBuffer, id: UInt64 = 0, generation: UInt64 = 1) -> fe_frame {
    var frame = fe_frame()
    frame.abi_version = UInt32(FE_ABI_VERSION); frame.struct_size = UInt32(MemoryLayout<fe_frame>.size)
    frame.source_id = 10; frame.stream_id = 1; frame.frame_id = id; frame.generation = generation
    frame.pts = fe_time(value: Int64(id), timescale: 30)
    frame.duration = fe_time(value: 1, timescale: 30)
    frame.geometry.width = 4; frame.geometry.height = 2
    frame.geometry.crop_width = 4; frame.geometry.crop_height = 2
    frame.geometry.pixel_aspect_num = 1; frame.geometry.pixel_aspect_den = 1
    frame.pixel_format = kCVPixelFormatType_64RGBAHalf
    frame.pixel_buffer = Unmanaged.passUnretained(buffer).toOpaque()
    frame.colour.reference_white_nits = 203; frame.colour.hlg_peak_nits = 1000
    return frame
}

private actor GateProcessor: FrameProcessor {
    var waiting: CheckedContinuation<Void, Never>?
    var starts: [UInt64] = []
    var resets = 0
    func resetHistory() { resets += 1 }
    func process(_ frame: EngineInput) async throws -> ProcessedFrame {
        starts.append(frame.descriptor.frame_id)
        await withCheckedContinuation { waiting = $0 }
        return ProcessedFrame(buffer: frame.pixelBuffer, colour: frame.descriptor.colour)
    }
    func advance() { waiting?.resume(); waiting = nil }
    var waitingCount: Int { starts.count }
}

private func eventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw FrameEngineError.invalid("Timed out waiting for worker") }
        try await Task.sleep(for: .milliseconds(1))
    }
}

@Test func generationResetDiscardsInflightAndQueuedOutput() async throws {
    let buffer = try fixtureBuffer()
    let processor = GateProcessor()
    let session = try FrameSession(processor: processor)
    #expect(session.submit(descriptor(buffer)) == FE_ACCEPTED)
    #expect(session.submit(descriptor(buffer, id: 1)) == FE_ACCEPTED)
    try await eventually { await processor.waitingCount == 1 }
    let generation = session.reset()
    #expect(generation == 2)
    #expect(session.submit(descriptor(buffer, id: 2)) == FE_CANCELLED)
    #expect(session.submit(descriptor(buffer, id: 9, generation: generation)) == FE_ACCEPTED)
    await processor.advance()
    try await eventually { await processor.waitingCount == 2 }
    #expect(session.poll() == nil)
    await processor.advance()
    try await eventually { session.statistics().completed == 1 }
    let output = try #require(session.poll())
    #expect(output.descriptor.generation == 2)
    #expect(output.descriptor.frame_id == 9)
    #expect(await processor.starts == [0, 9])
    #expect(await processor.resets == 2)
    #expect(session.statistics().cancelled == 2)
}

@Test func backpressureIncludesLeasedOutputsAndRedrawDoesNotAdvanceHistory() async throws {
    let buffer = try fixtureBuffer()
    let processor = GateProcessor()
    let session = try FrameSession(limits: .init(slots: 2), processor: processor)
    #expect(session.submit(descriptor(buffer)) == FE_ACCEPTED)
    #expect(session.submit(descriptor(buffer, id: 1)) == FE_ACCEPTED)
    #expect(session.submit(descriptor(buffer, id: 2)) == FE_FULL)
    try await eventually { await processor.waitingCount == 1 }
    await processor.advance()
    try await eventually { await processor.waitingCount == 2 }
    var output = session.poll()
    try #require(output != nil)
    #expect(output?.descriptor.frame_id == 0)
    #expect(session.redraw() === output)
    #expect(session.redraw() === output)
    #expect(await processor.starts == [0, 1])
    await processor.advance()
    try await eventually { session.statistics().completed == 2 }
    #expect(session.submit(descriptor(buffer, id: 2)) == FE_FULL)
    output = nil
    try await eventually { session.statistics().occupiedSlots == 1 }
    #expect(session.submit(descriptor(buffer, id: 2)) == FE_ACCEPTED)
    try await eventually { await processor.waitingCount == 3 }
    await processor.advance()
    try await eventually { session.statistics().completed == 3 }
    #expect(session.statistics().peakSlots == 2)
    #expect(session.submit(descriptor(buffer, id: 2)) == FE_DUPLICATE)
    #expect(await processor.resets == 1)
}

@Test func deadlineMissDoesNotResetHistoryAndLeasesSurviveClose() async throws {
    let buffer = try fixtureBuffer()
    let processor = GateProcessor()
    let session = try FrameSession(processor: processor)
    var first = descriptor(buffer)
    first.deadline_host_seconds = 1 // Expired monotonic deadline.
    #expect(session.submit(first) == FE_ACCEPTED)
    try await eventually { await processor.waitingCount == 1 }
    await processor.advance()
    try await eventually { session.statistics().completed == 1 }
    let output = try #require(session.poll())
    #expect(session.submit(descriptor(buffer, id: 1)) == FE_ACCEPTED)
    try await eventually { await processor.waitingCount == 2 }
    await processor.advance()
    try await eventually { session.statistics().completed == 2 }
    #expect(await processor.resets == 1)
    session.close()
    #expect(session.redraw() == nil)
    #expect(output.descriptor.frame_id == 0)
    #expect(CVPixelBufferGetWidth(output.pixelBuffer) == 4)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires Metal"))
func realGPURoundtripWaitsForProducerAndPreservesHDR() async throws {
    let buffer = try fixtureBuffer()
    CVPixelBufferLockBaseAddress(buffer, [])
    let pointer = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: Float16.self)
    pointer[0] = -2; pointer[1] = 203; pointer[2] = 4000; pointer[3] = 1
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let device = try #require(MTLCreateSystemDefaultDevice())
    let event = try #require(device.makeSharedEvent())
    var frame = descriptor(buffer)
    frame.ready_event = Unmanaged.passUnretained(event as AnyObject).toOpaque(); frame.ready_value = 7
    let session = try FrameSession(processor: LinearHDRCopyProcessor())
    #expect(session.submit(frame) == FE_ACCEPTED)
    try await Task.sleep(for: .milliseconds(20))
    #expect(session.poll() == nil)
    event.signaledValue = 7
    try await eventually { session.statistics().completed == 1 }
    let output = try #require(session.poll())
    CVPixelBufferLockBaseAddress(output.pixelBuffer, .readOnly)
    let values = try #require(CVPixelBufferGetBaseAddress(output.pixelBuffer)).assumingMemoryBound(to: Float16.self)
    #expect(Array(UnsafeBufferPointer(start: values, count: 4)) == [-2, 203, 4000, 1])
    CVPixelBufferUnlockBaseAddress(output.pixelBuffer, .readOnly)
    #expect((output.gpuSeconds["copy"] ?? -1) >= 0)
}
