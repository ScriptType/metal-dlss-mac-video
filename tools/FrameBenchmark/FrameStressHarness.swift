import CFrameEngine
import CoreVideo
import DLSSMedia
import DLSSMLX
import Foundation
import FrameEngine
import Metal
import QuartzCore

private struct StressMemory: Codable {
    let residentBytes, mlxActiveBytes, mlxCacheBytes, mlxPeakActiveBytes, mlxCacheLimitBytes: UInt64
    let models: HDRRuntimeResourceSnapshot
    static func sample() -> Self {
        let mlx = MLXRuntimeDiagnostics.memorySnapshot()
        return .init(residentBytes: fe_process_resident_bytes(), mlxActiveBytes: mlx.activeBytes,
            mlxCacheBytes: mlx.cacheBytes, mlxPeakActiveBytes: mlx.peakActiveBytes,
            mlxCacheLimitBytes: MLXRuntimeDiagnostics.cacheLimitBytes, models: HDRRuntimeResources.shared.snapshot())
    }
}
private struct StressCycle: Codable {
    let mode: String, index: Int
    let resetSeconds, closeDrainSeconds: Double
    let redraws: Int
    let held: StressMemory
    var drained: StressMemory?
    let measurements: FrameMeasurementReport
    let cancelledFrames: UInt64
}
private struct StressReport: Codable {
    var schemaVersion = 1
    var scope = "Bounded offscreen lifecycle and sampled allocator stress; no presentation, physical-memory hard cap or sustained FPS claim"
    var passed = false
    var violations: [String] = []
    let sourceSHA256, alternateSHA256, modelSHA256, revision: String
    let processingWidth, processingHeight, requestedCyclesPerMode, warmupCycles: Int
    let residentGrowthToleranceBytes, activeGrowthToleranceBytes: UInt64
    var cycles: [StressCycle] = []
}
private actor StressProcessor: FrameProcessor {
    let base: HDRPipelineProcessor
    private(set) var started = 0
    private(set) var resets = 0
    init(_ configuration: HDRPipelineConfiguration) { base = HDRPipelineProcessor(configuration: configuration) }
    func process(_ frame: EngineInput) async throws -> ProcessedFrame {
        started += 1
        return try await base.process(frame)
    }
    func resetHistory() async { resets += 1; await base.resetHistory() }
}

/// A real Metal blit consumes every held output after an unsignalled dependency.
/// The lease array is cleared only in the completed-command callback.
private final class StressConsumer: @unchecked Sendable {
    let gate: any MTLSharedEvent
    let command: any MTLCommandBuffer
    let lock = NSLock()
    private var leases: [CompletedFrame]
    private var views: [CVMetalTexture] = []
    private var done = false
    private var failure: String?
    init(_ outputs: [CompletedFrame], device: any MTLDevice) throws {
        leases = outputs
        guard let gate = device.makeSharedEvent(), let queue = device.makeCommandQueue(),
              let command = queue.makeCommandBuffer() else { throw FrameEngineError.invalid("Cannot create stress consumer") }
        self.gate = gate; self.command = command
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw FrameEngineError.invalid("Cannot create stress texture cache") }
        command.label = "Stress: held output leases until real GPU consumer completion"
        command.encodeWaitForEvent(gate, value: 1)
        guard let blit = command.makeBlitCommandEncoder() else { throw FrameEngineError.invalid("Cannot create stress blit") }
        for output in outputs {
            let buffer = output.pixelBuffer, width = CVPixelBufferGetWidth(output.pixelBuffer), height = CVPixelBufferGetHeight(output.pixelBuffer)
            var view: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .rgba16Float, width, height, 0, &view) == kCVReturnSuccess,
                  let view, let texture = CVMetalTextureGetTexture(view) else { throw FrameEngineError.invalid("Cannot bind retained stress output") }
            views.append(view)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            guard let destination = device.makeTexture(descriptor: descriptor) else { throw FrameEngineError.invalid("Cannot allocate stress destination") }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
                sourceSize: .init(width: width, height: height, depth: 1), to: destination,
                destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
        }
        blit.endEncoding()
        command.addCompletedHandler { [weak self] completed in
            guard let self else { return }
            lock.withLock {
                failure = completed.error?.localizedDescription
                leases.removeAll(); views.removeAll(); done = true
            }
        }
        command.commit()
    }
    func releaseGPU() { gate.signaledValue = 1 }
    var complete: Bool { lock.withLock { done } }
    func check() throws { if let error = lock.withLock({ failure }) { throw FrameEngineError.invalid(error) } }
}

enum FrameStressHarness {
    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw FrameEngineError.invalid("Stress assertion: \(message)") }
    }
    private static func eventually(seconds: Double = 30, _ predicate: () async -> Bool) async throws {
        let end = CACurrentMediaTime() + seconds
        while !(await predicate()) {
            guard CACurrentMediaTime() < end else { throw FrameEngineError.invalid("Stress drain/worker deadline exceeded") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func run(_ args: [String]) async throws {
        func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let video = option("--video"), let alternate = option("--alternate-video"),
              let modelPath = option("--model"), let reportPath = option("--report") else {
            throw FrameEngineError.invalid("--stress requires --video, --alternate-video, --model and --report")
        }
        let width = Int(option("--width") ?? "160") ?? 0, height = Int(option("--height") ?? "96") ?? 0
        let cycles = Int(option("--cycles") ?? "12") ?? 0, warmup = Int(option("--warmup-cycles") ?? "3") ?? 0
        let rssMiB = UInt64(option("--rss-growth-mib") ?? "128") ?? 0
        let activeMiB = UInt64(option("--active-growth-mib") ?? "64") ?? 0
        try check((4...100).contains(cycles) && warmup >= 1 && cycles - warmup >= 3, "cycles/warmup must leave at least three measured cycles")
        try check((1...16384).contains(width) && (1...16384).contains(height) && UInt64(width) * UInt64(height) <= HDRRuntimeResources.shared.snapshot().policy.maximumProcessingPixels,
            "processing geometry exceeds configured admission policy")
        try check(rssMiB <= 4096 && activeMiB <= 4096, "growth tolerances must be at most4096MiB")
        let source = URL(fileURLWithPath: video), replacement = URL(fileURLWithPath: alternate), model = URL(fileURLWithPath: modelPath)
        let sourceHash = try HDRCacheSource.fingerprint(url: source, streamIndex: 0).contentSHA256
        let replacementHash = try HDRCacheSource.fingerprint(url: replacement, streamIndex: 0).contentSHA256
        let modelHash = try HDRCacheSource.fingerprint(url: model.appendingPathComponent("weights.safetensors"), streamIndex: 0).contentSHA256
        var report = StressReport(sourceSHA256: sourceHash, alternateSHA256: replacementHash, modelSHA256: modelHash,
            revision: option("--revision") ?? "unrecorded", processingWidth: width, processingHeight: height,
            requestedCyclesPerMode: cycles, warmupCycles: warmup,
            residentGrowthToleranceBytes: rssMiB * 1_048_576, activeGrowthToleranceBytes: activeMiB * 1_048_576)
        let initialModels = HDRRuntimeResources.shared.snapshot().residentModels
        do {
            try check(initialModels == 0, "run stress in an isolated process without existing neural owners")
            for mode in ["original", "neural"] {
                for index in 0..<cycles {
                    var cycle = try await runCycle(source: source, replacement: replacement, model: model,
                        modelHash: modelHash, mode: mode, index: index, width: width, height: height, revision: report.revision)
                    try await eventually { HDRRuntimeResources.shared.snapshot().residentModels == initialModels }
                    cycle.drained = StressMemory.sample()
                    try check(cycle.drained!.models.residentModelPayloadBytes == 0, "model payload credits remained after actual session drain/destruction")
                    try check(cycle.drained!.mlxCacheLimitBytes == cycle.drained!.models.policy.mlxCacheBytes, "effective MLX cache limit differs from runtime policy")
                    report.cycles.append(cycle)
                    print("stress mode=\(mode) cycle=\(index + 1)/\(cycles) rss=\(cycle.drained!.residentBytes) active=\(cycle.drained!.mlxActiveBytes) cache=\(cycle.drained!.mlxCacheBytes)")
                }
                let measured = report.cycles.filter { $0.mode == mode && $0.index >= warmup }.compactMap(\.drained)
                let early = measured.prefix(max(1, measured.count / 2)), late = measured.suffix(max(1, measured.count / 2))
                func median(_ values: [UInt64]) -> UInt64 { values.sorted()[values.count / 2] }
                let rssEarly = median(early.map(\.residentBytes)), rssLate = median(late.map(\.residentBytes))
                let activeEarly = median(early.map(\.mlxActiveBytes)), activeLate = median(late.map(\.mlxActiveBytes))
                try check(rssLate <= rssEarly + report.residentGrowthToleranceBytes, "\(mode) sampled drained RSS plateau growth exceeds tolerance")
                try check(activeLate <= activeEarly + report.activeGrowthToleranceBytes, "\(mode) sampled drained active MLX plateau growth exceeds tolerance")
            }
            report.passed = true
        } catch { report.violations.append(error.localizedDescription) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        try check(report.passed, report.violations.joined(separator: "; "))
    }

    private static func runCycle(source: URL, replacement: URL, model: URL, modelHash: String,
                                 mode: String, index: Int, width: Int, height: Int, revision: String) async throws -> StressCycle {
        guard let device = MTLCreateSystemDefaultDevice(), let producerGate = device.makeSharedEvent() else {
            throw FrameEngineError.invalid("Metal unavailable")
        }
        let reader = try await NativeHDRVideoReader(url: source), alternate = try await NativeHDRVideoReader(url: replacement)
        let processor = StressProcessor(.init(modelURL: model, modelVersion: modelHash,
            processingWidth: width, processingHeight: height, strength: mode == "neural" ? 1 : 0))
        guard let first = try await reader.nextDecoded() else { throw FrameEngineError.invalid("Empty stress source") }
        let recorder = FrameMeasurementRecorder(configuration: .init(adapter: "native/shared-engine-lifecycle-stress",
            source: source.lastPathComponent + " -> " + replacement.lastPathComponent,
            sourceWidth: first.pixelBuffer.width, sourceHeight: first.pixelBuffer.height,
            processingWidth: width, processingHeight: height, displayWidth: 0, displayHeight: 0,
            sourceFPS: Double(reader.nominalFrameRate), modelVersion: mode == "neural" ? modelHash : "original",
            implementationRevision: revision, settingsJSON: "{\"strength\":\(mode == "neural" ? 1 : 0),\"referenceWhiteNits\":203,\"maximumLuminanceRatio\":2}",
            warmupFrames: 0, displayConfiguration: "offscreen Metal blit consumer; no presentation"), maximumSamples: 16)
        let session = try FrameSession(limits: .init(slots: 3, bytes: 512 * 1024 * 1024,
            processingWidth: width, processingHeight: height), processor: processor, measurements: recorder)
        var consumer: StressConsumer?
        var held: [CompletedFrame] = []
        defer { producerGate.signaledValue = 1; consumer?.releaseGPU(); session.close() }
        do {
            var input = first
            for frameID in 0..<3 {
                if frameID > 0 {
                    guard let next = try await reader.nextDecoded() else { throw FrameEngineError.invalid("Stress source needs at least four frames") }
                    input = next
                }
                var frame = DecoderFrameDescriptor.make(pixelBuffer: input.pixelBuffer.buffer, metadata: input.metadata,
                    sourceID: UInt64(index * 2 + 1), generation: session.generation)
                frame.frame_id = UInt64(frameID); frame.deadline_host_seconds = CACurrentMediaTime() - 1
                try check(session.submit(frame) == FE_ACCEPTED, "three initial frames must fit")
            }
            await session.waitUntilIdle()
            try check(session.statistics().failures == 0, session.error)
            while let output = session.poll() { held.append(output) }
            try check(held.count == 3 && session.statistics().occupiedSlots == 3, "all completed leases consume admission slots")
            let starts = await processor.started, resets = await processor.resets
            for _ in 0..<32 { try check(session.redraw() === held.last, "redraw changed output ownership") }
            let redrawStarts = await processor.started, redrawResets = await processor.resets
            try check(redrawStarts == starts && redrawResets == resets && resets == 1, "redraw or expired deadline advanced/reset history")
            guard let fourth = try await reader.nextDecoded() else { throw FrameEngineError.invalid("Stress source needs four frames") }
            var blocked = DecoderFrameDescriptor.make(pixelBuffer: fourth.pixelBuffer.buffer, metadata: fourth.metadata,
                sourceID: UInt64(index * 2 + 1), generation: session.generation)
            blocked.frame_id = 3
            try check(session.submit(blocked) == FE_FULL, "held leases must cause backpressure")
            held.removeFirst()
            try await eventually { session.statistics().occupiedSlots == 2 }
            blocked.ready_event = Unmanaged.passUnretained(producerGate as AnyObject).toOpaque(); blocked.ready_value = 1
            try check(session.submit(blocked) == FE_ACCEPTED, "release must return exactly one admission slot")
            try await eventually { await processor.started == starts + 1 }
            let resetStart = CACurrentMediaTime(), generation = session.reset()
            try check(session.submit(blocked) == FE_CANCELLED, "obsolete generation was admitted")
            try check(session.poll() == nil && session.redraw() == nil, "reset exposed an obsolete frame")
            producerGate.signaledValue = 1
            await session.waitUntilIdle()
            try check(session.statistics().cancelled == 1 && session.poll() == nil, "cancelled producer work reached output")
            try await eventually { session.statistics().occupiedSlots == 2 }
            let resetSeconds = CACurrentMediaTime() - resetStart
            guard let changed = try await alternate.nextDecoded() else { throw FrameEngineError.invalid("Empty alternate stress source") }
            var fresh = DecoderFrameDescriptor.make(pixelBuffer: changed.pixelBuffer.buffer, metadata: changed.metadata,
                sourceID: UInt64(index * 2 + 2), generation: generation)
            fresh.frame_id = 0
            try check(session.submit(fresh) == FE_ACCEPTED, "reset did not allow source replacement")
            await session.waitUntilIdle()
            var output = session.poll()
            guard output != nil else { throw FrameEngineError.invalid("Replacement failed: \(session.error)") }
            try check(output!.descriptor.generation == generation && output!.descriptor.source_id == fresh.source_id, "replacement output retained old identity")
            try check(output!.contentKind == (mode == "neural" ? .enhanced : .original), "wrong real processing path")
            try check(await processor.resets == resets + 1, "source replacement did not reset temporal history exactly once")
            held.append(output!)
            consumer = try StressConsumer(held, device: device)
            let memory = StressMemory.sample()
            try check(memory.models.residentModels == (mode == "neural" ? 1 : 0), "wrong model residency for effect strength")
            held.removeAll()
            output = nil
            let closeStart = CACurrentMediaTime()
            session.close(); await session.waitUntilIdle()
            try check(session.statistics().occupiedSlots == 3, "close released leases before their GPU consumer completed")
            consumer!.releaseGPU()
            try await eventually { consumer!.complete }
            try consumer!.check()
            try await eventually { session.statistics().occupiedSlots == 0 }
            let stats = session.statistics()
            try check(stats.retainedBytes == 0, "completed consumer retained frame budget")
            try check(stats.peakSlots == 3 && stats.peakRetainedBytes <= 512 * 1024 * 1024, "frame admission budget exceeded")
            await reader.cancel(); await alternate.cancel()
            return StressCycle(mode: mode, index: index, resetSeconds: resetSeconds,
                closeDrainSeconds: CACurrentMediaTime() - closeStart, redraws: 32, held: memory,
                measurements: recorder.report(), cancelledFrames: stats.cancelled)
        } catch {
            producerGate.signaledValue = 1; consumer?.releaseGPU()
            session.close(); await session.waitUntilIdle()
            if let consumer { try? await eventually { consumer.complete } }
            held.removeAll(); await reader.cancel(); await alternate.cancel()
            throw error
        }
    }
}
