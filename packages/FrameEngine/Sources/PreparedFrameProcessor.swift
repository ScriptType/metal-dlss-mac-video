import CFrameEngine
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import QuartzCore

/// File paths are supplied by the playback adapter after checking sourcePath
/// against its actual opened media. Ranges are exact source presentation times.
public struct PreparedHDRRequest: Codable, Sendable {
    public var sourcePath: String
    public var cacheDirectory: String
    public var capacityBytes: Int64
    public var rangeStart: HDRCacheTime?
    public var rangeEnd: HDRCacheTime?
    public var segmentFrames: Int?
    public var prerollFrames: Int?
    public init(sourcePath: String, cacheDirectory: String, capacityBytes: Int64,
                rangeStart: HDRCacheTime? = nil, rangeEnd: HDRCacheTime? = nil,
                segmentFrames: Int = 60, prerollFrames: Int = 8) {
        self.sourcePath = sourcePath; self.cacheDirectory = cacheDirectory; self.capacityBytes = capacityBytes
        self.rangeStart = rangeStart; self.rangeEnd = rangeEnd
        self.segmentFrames = segmentFrames; self.prerollFrames = prerollFrames
    }
    func validate() throws {
        guard !sourcePath.isEmpty, !cacheDirectory.isEmpty, capacityBytes > 0,
              (1...600).contains(segmentFrames ?? 60), (0...600).contains(prerollFrames ?? 8),
              rangeStart == nil || rangeEnd == nil || rangeStart! < rangeEnd! else {
            throw FrameEngineError.invalid("Invalid Prepared source, range or storage limits")
        }
    }
}

public struct PreparedHDRProgress: Codable, Sendable {
    public var configurationState = "initializing"
    public var jobState = "idle"
    public var completedSegments = 0, totalSegments = 0, reusedSegments = 0, processedFrames = 0
    public var completedRanges: [HDRCacheRange] = []
    public var availableRanges: [HDRCacheRange] = []
    public var cacheHits: UInt64 = 0, cacheMisses: UInt64 = 0
    public var lastOutput = "original"
    public var lastGeneration: UInt64?, lastFrameID: UInt64?
    public var lastPTS: HDRCacheTime?
    public var error: String?
    public var isIdle: Bool { configurationState != "initializing" && jobState != "preparing" }
}

/// The C progress getter never waits for an actor, disk I/O or GPU work.
public final class PreparedHDRStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var value = PreparedHDRProgress()
    private var control: UInt64 = 0
    public func snapshot() -> PreparedHDRProgress { lock.withLock { value } }
    fileprivate func beginControl(_ state: String?) -> UInt64 {
        lock.withLock { control &+= 1; if let state { value.jobState = state }; return control }
    }
    fileprivate func currentControl() -> UInt64 { lock.withLock { control } }
    fileprivate func update(_ body: (inout PreparedHDRProgress) -> Void) { lock.withLock { body(&value) } }
}

private struct PreparedHDRResources: Sendable {
    let cache: HDRSegmentCache
    let coordinator: HDRPreparationCoordinator
    let segments: [HDRPreparationSegment]
    let expectedKeys: Set<String>
    let sourceSignature: PreparedSourceSignature
}

struct PreparedSourceSignature: Equatable, Sendable {
    let device, inode: UInt64
    let bytes, modifiedSeconds, modifiedNanoseconds, changedSeconds, changedNanoseconds: Int64
    static func read(_ path: String) throws -> Self {
        var value = stat()
        guard stat(path, &value) == 0 else { throw FrameEngineError.invalid("Prepared source is no longer accessible") }
        return Self(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino), bytes: value.st_size,
            modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
}

/// Replacing an mpv filter briefly overlaps old and new contexts. Share one
/// owning cache actor for that directory, while identities and jobs stay separate.
/// Weak entries release the filesystem lock after the final context/lease ends.
private actor PreparedCacheRegistry {
    static let shared = PreparedCacheRegistry()
    private final class Entry {
        weak var cache: HDRSegmentCache?
        let capacity: Int64
        init(_ cache: HDRSegmentCache, capacity: Int64) { self.cache = cache; self.capacity = capacity }
    }
    private struct Pending {
        let id: UUID, capacity: Int64
        let task: Task<HDRSegmentCache, any Error>
    }
    private var entries: [String: Entry] = [:]
    private var pending: [String: Pending] = [:]
    func open(directory: URL, capacity: Int64) async throws -> HDRSegmentCache {
        entries = entries.filter { $0.value.cache != nil }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath(), key = directory.path
        if let entry = entries[key], let cache = entry.cache {
            guard entry.capacity == capacity else { throw FrameEngineError.invalid("Close existing Prepared contexts before changing cache capacity") }
            return cache
        }
        if let opening = pending[key] {
            guard opening.capacity == capacity else { throw FrameEngineError.invalid("Prepared cache is opening with a different capacity") }
            return try await opening.task.value
        }
        let id = UUID()
        let task = Task { try await HDRSegmentCache.open(directory: directory, capacityBytes: capacity) }
        pending[key] = Pending(id: id, capacity: capacity, task: task)
        do {
            let cache = try await task.value
            entries[key] = Entry(cache, capacity: capacity)
            if pending[key]?.id == id { pending.removeValue(forKey: key) }
            return cache
        } catch {
            if pending[key]?.id == id { pending.removeValue(forKey: key) }
            throw error
        }
    }
}

/// One source/configuration owns one existing cache actor. Preparation and
/// playback share its completed index and leases; there is no second cache.
public actor PreparedHDRContext {
    public nonisolated let status = PreparedHDRStatus()
    public nonisolated let request: PreparedHDRRequest
    public nonisolated let configuration: HDRPipelineConfiguration
    private let decoderProvider: any FramePreparationDecoderProvider
    private var resources: PreparedHDRResources?
    private var initialization: Task<PreparedHDRResources, any Error>?
    private var initializationRevision: UInt64 = 0
    private var job: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var invalidated = false

    public init(request: PreparedHDRRequest, configuration: HDRPipelineConfiguration,
                decoderProvider: any FramePreparationDecoderProvider = NativeFramePreparationProvider()) throws {
        try request.validate()
        self.request = request; self.configuration = configuration
        self.decoderProvider = decoderProvider
    }

    public nonisolated func initializeInBackground() {
        let token = status.currentControl()
        Task { await self.initializeIfCurrent(token) }
    }

    private func initializeIfCurrent(_ token: UInt64) async {
        guard token == status.currentControl() else { return }
        _ = try? await initialize()
    }

    private func initialize() async throws -> PreparedHDRResources {
        guard !invalidated else { throw FrameEngineError.invalid("Prepared source changed; reopen the media to create a new context") }
        if let resources { return resources }
        if initialization == nil {
            initializationRevision &+= 1
            let request = request, configuration = configuration, decoderProvider = decoderProvider
            initialization = Task.detached(priority: .utility) {
                try await Self.buildResources(request: request, configuration: configuration, decoderProvider: decoderProvider)
            }
        }
        let revision = initializationRevision, task = initialization!
        do {
            let result = try await task.value
            guard revision == initializationRevision else { throw CancellationError() }
            resources = result
            let available = await availableRanges(result)
            status.update { $0.configurationState = "ready"; $0.totalSegments = result.segments.count; $0.availableRanges = available }
            return result
        } catch {
            guard revision == initializationRevision else { throw error }
            if error is CancellationError { initialization = nil }
            status.update {
                $0.configurationState = error is CancellationError ? "cancelled" : "failed"
                $0.error = error is CancellationError ? nil : error.localizedDescription
            }
            throw error
        }
    }

    public func waitUntilReady() async throws { _ = try await initialize() }

    public nonisolated func requestStart() {
        let token = status.beginControl("preparing")
        Task { await self.start(requestToken: token) }
    }

    public func start() async { await start(requestToken: status.beginControl("preparing")) }

    private func start(requestToken token: UInt64) async {
        guard token == status.currentControl() else { return }
        generation = token
        let previous = job
        previous?.cancel()
        if let resources { await resources.coordinator.cancel() }
        if let previous { await previous.value }
        guard token == generation, token == status.currentControl() else { return }
        status.update { $0.jobState = "preparing"; $0.error = nil }
        job = Task { await self.run(token: token) }
    }

    public func wait() async { await job?.value }

    public nonisolated func requestCancel() {
        let token = status.beginControl(nil)
        Task { await self.cancel(requestToken: token) }
    }

    public func cancel() async { await cancel(requestToken: status.beginControl(nil)) }

    private func cancel(requestToken token: UInt64) async {
        guard token == status.currentControl() else { return }
        generation = token
        job?.cancel()
        if resources == nil, let pending = initialization {
            initializationRevision &+= 1
            initialization = nil
            pending.cancel()
            _ = await pending.result
        }
        if token == status.currentControl(), resources == nil {
            status.update { $0.configurationState = "cancelled"; $0.error = nil }
        }
        if let resources { await resources.coordinator.cancel() }
        if let job { await job.value }
        if token == status.currentControl() { status.update { $0.jobState = "cancelled" } }
    }

    private func run(token: UInt64) async {
        do {
            let resources = try await initialize()
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            try await resources.coordinator.start(sourceURL: URL(fileURLWithPath: request.sourcePath), segments: resources.segments)
            while true {
                try Task.checkCancellation()
                let progress = await resources.coordinator.progress()
                let available = await availableRanges(resources)
                guard token == generation, token == status.currentControl() else { throw CancellationError() }
                status.update {
                    $0.jobState = progress.state.rawValue; $0.totalSegments = progress.totalSegments
                    $0.completedSegments = progress.completedSegments; $0.reusedSegments = progress.reusedSegments
                    $0.processedFrames = progress.processedFrames; $0.completedRanges = progress.completedRanges
                    $0.availableRanges = available; $0.error = progress.error
                }
                if progress.state != .preparing { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try await resources.coordinator.wait()
        } catch {
            if error is CancellationError, let resources { await resources.coordinator.cancel() }
            if token == generation {
                status.update {
                    $0.jobState = error is CancellationError ? "cancelled" : "failed"
                    $0.error = error is CancellationError ? nil : error.localizedDescription
                }
            }
        }
    }

    private func availableRanges(_ resources: PreparedHDRResources) async -> [HDRCacheRange] {
        guard let identity = resources.segments.first?.identity else { return [] }
        return await resources.cache.indexedCompletedRanges(source: identity.source, settings: identity.settings)
            .filter { resources.expectedKeys.contains($0.key) }.map(\.range)
    }

    fileprivate func lookup(_ pts: HDRCacheTime) throws -> (HDRSegmentCache, HDRCacheIdentity)? {
        guard let resources else { return nil }
        do {
            guard try PreparedSourceSignature.read(request.sourcePath) == resources.sourceSignature else {
                throw FrameEngineError.invalid("Prepared source changed after fingerprinting; reopen the media before reusing cached frames")
            }
        } catch {
            invalidated = true
            status.update { $0.configurationState = "failed"; $0.error = error.localizedDescription; $0.availableRanges = [] }
            requestCancel()
            throw error
        }
        var low = 0, high = resources.segments.count
        while low < high {
            let mid = (low + high) / 2
            if resources.segments[mid].identity.range.end <= pts { low = mid + 1 } else { high = mid }
        }
        guard low < resources.segments.count else { return nil }
        let identity = resources.segments[low].identity
        return identity.range.start <= pts ? (resources.cache, identity) : nil
    }

    /// The selected provider supplies exact frame timing. Sorting handles decode
    /// order/B-frames without rounding timestamps or retaining pixel data.
    private static func buildResources(request: PreparedHDRRequest,
                                       configuration original: HDRPipelineConfiguration,
                                       decoderProvider: any FramePreparationDecoderProvider) async throws -> PreparedHDRResources {
        let sourceURL = URL(fileURLWithPath: request.sourcePath)
        let signature = try PreparedSourceSignature.read(request.sourcePath)
        let source = try HDRCacheSource.fingerprint(url: sourceURL, streamIndex: 0,
            interpretation: ["decoder": decoderProvider.identifier, "geometry": "unbaked-source-crop-transform-aspect-v1"])
        guard try PreparedSourceSignature.read(request.sourcePath) == signature else {
            throw FrameEngineError.invalid("Prepared source changed while being fingerprinted")
        }
        try Task.checkCancellation()
        var configuration = original
        if let model = configuration.modelURL {
            configuration.modelVersion = try HDRCacheSource.fingerprint(url: model.appendingPathComponent("weights.safetensors"), streamIndex: 0).contentSHA256
        } else {
            configuration.modelVersion = SHA256.hash(data: Data("original-hdr-v1".utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let inventory = try await decoderProvider.inventory(sourceURL: sourceURL, videoStreamIndex: 0)
        let settings = HDRCacheSettings(modelSHA256: configuration.modelVersion,
            implementationVersion: "frame-engine-prepared-v1;mlx-hdr-f2ce1772",
            processingWidth: configuration.processingWidth, processingHeight: configuration.processingHeight,
            outputWidth: inventory.width, outputHeight: inventory.height,
            colourPolicy: ["storage": HDRSegmentCache.storagePolicy, "referenceWhiteNits": String(configuration.referenceWhiteNits),
                "hlgPeakNits": "1000", "proxy": "srgb-bt709-proxy-v1", "reconstruction": "linear-bt2020-nits-ratio-v1", "displayMapping": "none"],
            guides: ["motion": "NativeOpticalFlow-automatic-v1", "temporal": "persistent-neural-defaults-v1", "sceneCutThreshold": "0.3"],
            effects: ["strength": Double(configuration.strength), "colourStrength": Double(configuration.colourStrength),
                "maximumLuminanceRatio": Double(configuration.maximumLuminanceRatio)],
            execution: ["precision": "float16", "backend": "MLX-Metal", "output": "RGBA16F-absolute-nits"])
        let segments = try inventory.segments(source: source, settings: settings,
            rangeStart: request.rangeStart, rangeEnd: request.rangeEnd,
            segmentFrames: request.segmentFrames ?? 60, prerollFrames: request.prerollFrames ?? 8)
        guard try PreparedSourceSignature.read(request.sourcePath) == signature else {
            throw FrameEngineError.invalid("Prepared source changed while timestamps were being indexed")
        }
        let cache = try await PreparedCacheRegistry.shared.open(directory: URL(fileURLWithPath: request.cacheDirectory), capacity: request.capacityBytes)
        return PreparedHDRResources(cache: cache, coordinator: HDRPreparationCoordinator(cache: cache, configuration: configuration, decoderProvider: decoderProvider),
                                    segments: segments, expectedKeys: Set(try segments.map { try $0.identity.key() }), sourceSignature: signature)
    }
}

/// Cache reads use source PTS and duration, never frame rate or a separate clock.
/// Disk Float32 pixels are packed to CPU-complete IOSurface RGBA16F buffers; the
/// ordinary output lease then owns them through the presenter's GPU completion.
public actor PreparedFrameProcessor: FrameProcessor {
    private let context: PreparedHDRContext
    private let original: HDRPipelineProcessor
    private var active: (HDRSegmentCache, HDRCacheLease)?
    public init(context: PreparedHDRContext) {
        self.context = context
        var configuration = context.configuration
        configuration.modelURL = nil; configuration.strength = 0
        original = HDRPipelineProcessor(configuration: configuration)
    }
    deinit {
        if let (cache, lease) = active { Task { await cache.release(lease) } }
    }
    public func resetHistory() async {
        if let (cache, lease) = active { await cache.release(lease) }
        active = nil
        await original.resetHistory()
    }
    public func process(_ frame: EngineInput) async throws -> ProcessedFrame {
        let descriptor = frame.descriptor
        let pts = try HDRCacheTime(value: descriptor.pts.value, timescale: descriptor.pts.timescale)
        let duration = try HDRCacheTime(value: descriptor.duration.value, timescale: descriptor.duration.timescale)
        let start = CACurrentMediaTime()
        if let (cache, identity) = try await context.lookup(pts) {
            guard identity.settings.outputWidth == Int(descriptor.geometry.width),
                  identity.settings.outputHeight == Int(descriptor.geometry.height) else {
                throw FrameEngineError.invalid("Prepared cache source geometry differs from decoded playback")
            }
            if active?.1.manifest.key != (try identity.key()) {
                if let (oldCache, oldLease) = active { await oldCache.release(oldLease) }
                active = nil
                if let lease = try await cache.acquire(identity: identity) { active = (cache, lease) }
            }
            if let (_, lease) = active,
               let index = lease.manifest.frames.firstIndex(where: { $0.timing.presentationTime == pts && $0.timing.duration == duration }) {
                let cached = try await cache.read(lease, frameIndex: index)
                let readEnd = CACurrentMediaTime()
                let buffer = try Self.pack(cached.rgba, width: identity.settings.outputWidth, height: identity.settings.outputHeight)
                var colour = descriptor.colour
                colour.primaries = FE_BT2020.rawValue; colour.transfer = FE_LINEAR.rawValue
                colour.matrix = FE_RGB.rawValue; colour.range = FE_FULL_RANGE.rawValue; colour.chroma_location = 0
                colour.reference_white_nits = Double(context.configuration.referenceWhiteNits)
                colour.mastering_xy = (0, 0, 0, 0, 0, 0, 0, 0)
                colour.mastering_min_nits = 0; colour.mastering_max_nits = 0; colour.max_cll = 0; colour.max_fall = 0
                context.status.update {
                    $0.cacheHits += 1; $0.lastOutput = "prepared"; $0.lastGeneration = descriptor.generation
                    $0.lastFrameID = descriptor.frame_id; $0.lastPTS = pts
                }
                return ProcessedFrame(buffer: buffer, colour: colour,
                    completedStageWallSeconds: ["prepared_cache_read": readEnd - start, "prepared_rgba16f_pack": CACurrentMediaTime() - readEnd],
                    contentKind: context.configuration.modelURL != nil && context.configuration.strength > 0 ? .preparedEnhanced : .preparedOriginal)
            }
        } else if let (cache, lease) = active {
            await cache.release(lease); active = nil
        }
        context.status.update {
            $0.cacheMisses += 1; $0.lastOutput = "original"; $0.lastGeneration = descriptor.generation
            $0.lastFrameID = descriptor.frame_id; $0.lastPTS = pts
        }
        return try await original.process(frame)
    }

    private static func pack(_ rgba: [Float], width: Int, height: Int) throws -> CVPixelBuffer {
        guard rgba.count == width * height * 4 else { throw HDRCacheError.invalidFrame("Prepared payload geometry mismatch") }
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer,
              CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw FrameEngineError.invalid("Cannot allocate Prepared RGBA16F storage")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw FrameEngineError.invalid("Prepared buffer has no storage") }
        try HDRCachePixels.pack(rgba, width: width, height: height,
            to: address, rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_Linear, .shouldPropagate)
        return buffer
    }
}
