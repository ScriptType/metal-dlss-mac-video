import CFrameEngine
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal
import QuartzCore

public enum FrameEngineError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// Decoded storage plus an immutable adapter-neutral descriptor. Retains the
/// producer's buffer and optional owner until processing has completed.
public final class EngineInput: @unchecked Sendable {
    public let descriptor: fe_frame
    public let pixelBuffer: CVPixelBuffer
    public let readyEvent: (any MTLSharedEvent)?
    init(_ descriptor: fe_frame) {
        self.descriptor = descriptor
        pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(descriptor.pixel_buffer!).takeUnretainedValue()
        readyEvent = descriptor.ready_event.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! any MTLSharedEvent }
        if let owner = descriptor.owner { descriptor.retain_owner?(owner) }
    }
    deinit { if let owner = descriptor.owner { descriptor.release_owner?(owner) } }
}

public enum FrameContentKind: Int32, Sendable {
    case unknown = 0, original = 1, enhanced = 2, preparedOriginal = 3, preparedEnhanced = 4
}

public struct ProcessedFrame: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public let colour: fe_colour
    public let contentKind: FrameContentKind
    /// GPU stage intervals measured only after command completion.
    public let gpuSeconds: [String: Double]
    public let completedStageWallSeconds: [String: Double]
    public let allocatorBytes: [String: UInt64]
    public init(buffer: CVPixelBuffer, colour: fe_colour, gpuSeconds: [String: Double] = [:],
                completedStageWallSeconds: [String: Double] = [:], allocatorBytes: [String: UInt64] = [:],
                contentKind: FrameContentKind = .unknown) {
        self.buffer = buffer; self.colour = colour; self.gpuSeconds = gpuSeconds
        self.contentKind = contentKind
        self.completedStageWallSeconds = completedStageWallSeconds; self.allocatorBytes = allocatorBytes
    }
}

public protocol FrameProcessor: Sendable {
    /// Return only once every producer GPU write has completed.
    func process(_ frame: EngineInput) async throws -> ProcessedFrame
    func resetHistory() async
}

public struct FrameSessionLimits: Sendable {
    public let slots: Int
    public let bytes: UInt64
    public let processingWidth: Int
    public let processingHeight: Int
    public init(slots: Int = 3, bytes: UInt64 = 512 * 1024 * 1024,
                processingWidth: Int = 320, processingHeight: Int = 192) {
        self.slots = slots; self.bytes = bytes
        self.processingWidth = processingWidth; self.processingHeight = processingHeight
    }
}

private final class FrameBudget: @unchecked Sendable {
    let lock = NSLock()
    let limit: FrameSessionLimits
    var bytes: UInt64 = 0
    var slots = 0
    var peakBytes: UInt64 = 0
    var peakSlots = 0
    init(_ limit: FrameSessionLimits) { self.limit = limit }
    func reserve(_ count: UInt64) -> FrameReservation? {
        lock.withLock {
            guard slots < limit.slots, count <= limit.bytes, bytes <= limit.bytes - count else { return nil }
            bytes += count; slots += 1
            peakBytes = max(bytes, peakBytes); peakSlots = max(slots, peakSlots)
            return FrameReservation(budget: self, bytes: count)
        }
    }
    func release(_ count: UInt64) { lock.withLock { bytes -= count; slots -= 1 } }
    func snapshot() -> (UInt64, Int, UInt64, Int) { lock.withLock { (bytes, slots, peakBytes, peakSlots) } }
}

private final class FrameReservation: @unchecked Sendable {
    let budget: FrameBudget
    let bytes: UInt64
    init(budget: FrameBudget, bytes: UInt64) { self.budget = budget; self.bytes = bytes }
    deinit { budget.release(bytes) }
}

/// A lease is immutable and survives session reset/destruction. Retain it until
/// the presenter's GPU command completes; check generation at presentation time.
public final class CompletedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let contentKind: FrameContentKind
    public let submittedHostSeconds: Double
    public let completedHostSeconds: Double
    public let gpuSeconds: [String: Double]
    public let descriptorPointer: UnsafePointer<fe_frame>
    private let storage: UnsafeMutablePointer<fe_frame>
    private let reservation: FrameReservation
    fileprivate init(input: EngineInput, result: ProcessedFrame, reservation: FrameReservation,
                     submitted: Double, completed: Double) {
        self.reservation = reservation; pixelBuffer = result.buffer; contentKind = result.contentKind
        submittedHostSeconds = submitted; completedHostSeconds = completed
        gpuSeconds = result.gpuSeconds
        storage = .allocate(capacity: 1)
        var descriptor = input.descriptor
        descriptor.pixel_buffer = Unmanaged.passUnretained(result.buffer).toOpaque()
        descriptor.colour = result.colour
        descriptor.source_colour = input.descriptor.colour
        descriptor.pixel_format = CVPixelBufferGetPixelFormatType(result.buffer)
        descriptor.geometry.width = UInt32(CVPixelBufferGetWidth(result.buffer))
        descriptor.geometry.height = UInt32(CVPixelBufferGetHeight(result.buffer))
        descriptor.plane_count = UInt32(CVPixelBufferGetPlaneCount(result.buffer))
        descriptor.planes = (fe_plane(), fe_plane(), fe_plane())
        if descriptor.plane_count == 0 {
            descriptor.planes.0 = fe_plane(width: descriptor.geometry.width, height: descriptor.geometry.height,
                                           bytes_per_row: UInt32(CVPixelBufferGetBytesPerRow(result.buffer)), offset: 0)
        }
        descriptor.owner = nil; descriptor.retain_owner = nil; descriptor.release_owner = nil
        descriptor.ready_event = nil; descriptor.ready_value = 0
        storage.initialize(to: descriptor)
        descriptorPointer = UnsafePointer(storage)
    }
    public var descriptor: fe_frame { storage.pointee }
    deinit { storage.deinitialize(count: 1); storage.deallocate() }
}

public struct FrameSessionSnapshot: Sendable {
    public let submitted, completed, cancelled, failures, duplicates: UInt64
    public let retainedBytes, peakRetainedBytes: UInt64
    public let occupiedSlots, peakSlots: Int
    public let lastCompletedSeconds: Double
}

/// Serial temporal execution, nonblocking admission and bounded retained outputs.
/// Decode and presentation run independently of the worker. Missing a deadline
/// never resets valid history. Reset cancels by generation, including in-flight
/// output; GPU ownership lasts until real completion even after cancellation.
public final class FrameSession: @unchecked Sendable {
    private struct Work: @unchecked Sendable {
        let input: EngineInput
        let reservation: FrameReservation
        let submitted: Double
    }
    private let lock = NSLock()
    private let budget: FrameBudget
    private let processor: any FrameProcessor
    private var measurementRecorder: FrameMeasurementRecorder?
    public var measurements: FrameMeasurementRecorder? { lock.withLock { measurementRecorder } }
    private var queued: [Work] = []
    private var outputs: [CompletedFrame] = []
    private var latest: CompletedFrame?
    private var running = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private var needsReset = true
    private var currentGeneration: UInt64 = 1
    private var lastIdentity: (source: UInt64, stream: UInt64, id: UInt64, time: CMTime)?
    private var submitted: UInt64 = 0, completed: UInt64 = 0, cancelled: UInt64 = 0
    private var failures: UInt64 = 0, duplicates: UInt64 = 0
    private var lastCompletedSeconds: Double = 0
    private var failureMessage = ""

    public init(limits: FrameSessionLimits = .init(), processor: any FrameProcessor,
                measurements: FrameMeasurementRecorder? = nil) throws {
        guard (2...32).contains(limits.slots), limits.bytes > 0,
              (1...16384).contains(limits.processingWidth), (1...16384).contains(limits.processingHeight) else {
            throw FrameEngineError.invalid("Invalid frame slots, memory budget or processing dimensions")
        }
        budget = FrameBudget(limits); self.processor = processor; self.measurementRecorder = measurements
    }

    public var generation: UInt64 { lock.withLock { currentGeneration } }
    public var isIdle: Bool { lock.withLock { !running } }
    public var error: String { lock.withLock { failureMessage } }
    public func configureMeasurements(_ configuration: MeasurementConfiguration) -> Bool {
        lock.withLock {
            guard submitted == 0, !closed else { return false }
            measurementRecorder = FrameMeasurementRecorder(configuration: configuration)
            return true
        }
    }

    public func submit(_ descriptor: fe_frame) -> fe_status {
        let start = CACurrentMediaTime()
        defer { measurements?.recordSubmission(seconds: CACurrentMediaTime() - start) }
        return lock.withLock {
            guard !closed, descriptor.generation == currentGeneration else { return FE_CANCELLED }
            guard descriptor.abi_version == FE_ABI_VERSION,
                  descriptor.struct_size >= MemoryLayout<fe_frame>.size,
                  let pointer = descriptor.pixel_buffer,
                  descriptor.pts.timescale > 0, descriptor.duration.timescale > 0,
                  descriptor.duration.value > 0,
                  descriptor.geometry.pixel_aspect_num > 0, descriptor.geometry.pixel_aspect_den > 0,
                  descriptor.deadline_host_seconds.isFinite,
                  (descriptor.owner == nil || (descriptor.retain_owner != nil && descriptor.release_owner != nil)) else {
                failureMessage = "Invalid frame ABI, timing, geometry or owner callbacks"; return FE_FAILED
            }
            let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(pointer).takeUnretainedValue()
            let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
            guard width > 0, height > 0, width <= 16384, height <= 16384,
                  descriptor.geometry.width == width, descriptor.geometry.height == height,
                  descriptor.pixel_format == CVPixelBufferGetPixelFormatType(buffer),
                  descriptor.plane_count == CVPixelBufferGetPlaneCount(buffer) else {
                failureMessage = "Descriptor does not match pixel buffer storage"; return FE_FAILED
            }
            let time = CMTime(value: descriptor.pts.value, timescale: descriptor.pts.timescale)
            if let last = lastIdentity {
                guard last.source == descriptor.source_id, last.stream == descriptor.stream_id else {
                    failureMessage = "Reset generation before changing source or stream"; return FE_FAILED
                }
                if last.id == descriptor.frame_id || time <= last.time {
                    duplicates += 1; return FE_DUPLICATE
                }
            }
            let inputBytes = CVPixelBufferGetIOSurface(buffer).map { IOSurfaceGetAllocSize($0.takeUnretainedValue()) }
                ?? CVPixelBufferGetDataSize(buffer)
            // Reserve decoded owner, HDR output/original and proxy working storage.
            // Model/cache residency belongs to the processor's explicit budget.
            let bytes = UInt64(inputBytes) + UInt64(width * height * 32)
                + UInt64(budget.limit.processingWidth * budget.limit.processingHeight * 48)
            guard let reservation = budget.reserve(bytes) else { return FE_FULL }
            let input = EngineInput(descriptor)
            queued.append(Work(input: input, reservation: reservation, submitted: CACurrentMediaTime()))
            lastIdentity = (descriptor.source_id, descriptor.stream_id, descriptor.frame_id, time)
            submitted += 1
            if !running {
                running = true
                Task.detached(priority: .userInitiated) { await self.drain() }
            }
            return FE_ACCEPTED
        }
    }

    private func next() -> (Work, Bool)? {
        lock.withLock {
            guard !queued.isEmpty, !closed else {
                running = false
                let waiters = idleWaiters; idleWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                return nil
            }
            let reset = needsReset; needsReset = false
            return (queued.removeFirst(), reset)
        }
    }

    private func drain() async {
        while let (work, reset) = next() {
            let workerStart = CACurrentMediaTime()
            if reset { await processor.resetHistory() }
            do {
                let result = try await processor.process(work.input)
                let now = CACurrentMediaTime()
                lock.withLock {
                    guard !closed, work.input.descriptor.generation == currentGeneration else {
                        cancelled += 1; return
                    }
                    let frame = CompletedFrame(input: work.input, result: result, reservation: work.reservation,
                                               submitted: work.submitted, completed: now)
                    outputs.append(frame); latest = frame; completed += 1
                    lastCompletedSeconds = now - work.submitted
                    let snapshot = budget.snapshot()
                    measurementRecorder?.recordCompletion(FrameMeasurement(generation: frame.descriptor.generation,
                        frameID: frame.descriptor.frame_id, ptsValue: frame.descriptor.pts.value,
                        ptsTimescale: frame.descriptor.pts.timescale, submittedHostSeconds: work.submitted,
                        workerStartHostSeconds: workerStart, completedHostSeconds: now, gpuStagesSeconds: result.gpuSeconds,
                        completedStageWallSeconds: result.completedStageWallSeconds, processResidentBytes: fe_process_resident_bytes(),
                        allocatorBytes: result.allocatorBytes,
                        occupiedSlots: snapshot.1, retainedBytes: snapshot.0,
                        deadlineHostSeconds: frame.descriptor.deadline_host_seconds > 0 ? frame.descriptor.deadline_host_seconds : nil))
                }
            } catch {
                lock.withLock {
                    if work.input.descriptor.generation == currentGeneration, !closed {
                        failures += 1; failureMessage = error.localizedDescription
                        // A failed temporal input is a discontinuity, unlike a late output.
                        needsReset = true
                    } else { cancelled += 1 }
                }
            }
        }
    }

    public func poll() -> CompletedFrame? { lock.withLock { outputs.isEmpty ? nil : outputs.removeFirst() } }
    /// Asynchronously wait for all admitted producer work, including obsolete GPU
    /// work, to finish. Use before reusing a processor in a different session.
    public func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if running { idleWaiters.append(continuation) }
                else { continuation.resume() }
            }
        }
    }
    public func redraw() -> CompletedFrame? { lock.withLock { latest } }
    @discardableResult public func reset() -> UInt64 {
        lock.withLock {
            currentGeneration &+= 1
            cancelled += UInt64(queued.count)
            queued.removeAll(); outputs.removeAll(); latest = nil; lastIdentity = nil
            needsReset = true
            return currentGeneration
        }
    }
    public func close() {
        lock.withLock {
            closed = true; currentGeneration &+= 1
            cancelled += UInt64(queued.count)
            queued.removeAll(); outputs.removeAll(); latest = nil; lastIdentity = nil
        }
    }
    public func statistics() -> FrameSessionSnapshot {
        lock.withLock {
            let (bytes, slots, peakBytes, peakSlots) = budget.snapshot()
            return FrameSessionSnapshot(submitted: submitted, completed: completed, cancelled: cancelled,
                failures: failures, duplicates: duplicates, retainedBytes: bytes, peakRetainedBytes: peakBytes,
                occupiedSlots: slots, peakSlots: peakSlots, lastCompletedSeconds: lastCompletedSeconds)
        }
    }
}

/// Completed GPU copy for the C boundary diagnostic. Neural and planar input use
/// the HDR processor; this deliberately accepts only already-linear RGBA16F.
public actor LinearHDRCopyProcessor: FrameProcessor {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw FrameEngineError.invalid("Metal unavailable")
        }
        self.device = device; self.queue = queue
    }
    public func resetHistory() {}
    public func process(_ frame: EngineInput) async throws -> ProcessedFrame {
        let input = frame.pixelBuffer
        guard CVPixelBufferGetPixelFormatType(input) == kCVPixelFormatType_64RGBAHalf,
              frame.descriptor.colour.transfer == FE_LINEAR.rawValue,
              frame.descriptor.colour.primaries == FE_BT2020.rawValue,
              let source = CVPixelBufferGetIOSurface(input)?.takeUnretainedValue() else {
            throw FrameEngineError.invalid("GPU copy requires IOSurface-backed linear BT.2020 RGBA16F in nits")
        }
        var destination: CVPixelBuffer?
        let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &destination)
        guard status == kCVReturnSuccess, let destination,
              let surface = CVPixelBufferGetIOSurface(destination)?.takeUnretainedValue() else {
            throw FrameEngineError.invalid("Cannot allocate HDR output")
        }
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                   width: width, height: height, mipmapped: false)
        description.storageMode = .shared; description.usage = [.shaderRead, .shaderWrite]
        guard let sourceTexture = device.makeTexture(descriptor: description, iosurface: source, plane: 0),
              let outputTexture = device.makeTexture(descriptor: description, iosurface: surface, plane: 0),
              let command = queue.makeCommandBuffer() else { throw FrameEngineError.invalid("Cannot bind HDR textures") }
        command.label = "Frame engine boundary HDR copy"
        if let event = frame.readyEvent { command.encodeWaitForEvent(event, value: frame.descriptor.ready_value) }
        guard let encoder = command.makeBlitCommandEncoder() else { throw FrameEngineError.invalid("Cannot encode HDR copy") }
        encoder.copy(from: sourceTexture, to: outputTexture); encoder.endEncoding()
        let holder = PixelBufferOwner(destination)
        let duration: Double = try await withCheckedThrowingContinuation { continuation in
            command.addCompletedHandler { [frame, holder] completed in
                withExtendedLifetime((frame, holder)) {
                    if let error = completed.error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: max(0, completed.gpuEndTime - completed.gpuStartTime)) }
                }
            }
            command.commit()
        }
        return ProcessedFrame(buffer: destination, colour: frame.descriptor.colour, gpuSeconds: ["copy": duration])
    }
}

private final class PixelBufferOwner: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}
