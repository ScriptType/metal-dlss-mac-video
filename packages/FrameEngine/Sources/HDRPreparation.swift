import CFrameEngine
import DLSSMLX
import Foundation

public struct HDRPreparationSegment: Sendable {
    public let identity: HDRCacheIdentity
    public let frameCount: Int
    public let decodeTimings: ArraySlice<HDRCacheFrameTiming>?
    public init(identity: HDRCacheIdentity, frameCount: Int, decodeTimings: [HDRCacheFrameTiming]? = nil) {
        self.identity = identity; self.frameCount = frameCount; self.decodeTimings = decodeTimings.map { $0[...] }
    }
    init(identity: HDRCacheIdentity, frameCount: Int, decodeTimingsSlice: ArraySlice<HDRCacheFrameTiming>) {
        self.identity = identity; self.frameCount = frameCount; self.decodeTimings = decodeTimingsSlice
    }
}

/// Cache identity of the model weights. Context setup and the preparation job must agree.
func preparedModelSHA256(_ modelURL: URL?) throws -> String {
    guard let modelURL else { return cacheDigest(Data("original-hdr-v1".utf8)) }
    return try HDRCacheSource.fingerprint(url: modelURL.appendingPathComponent("weights.safetensors"), streamIndex: 0).contentSHA256
}

public struct HDRPreparationProgress: Sendable {
    public enum State: String, Sendable { case idle, preparing, complete, cancelled, failed }
    public let state: State
    public let totalSegments, completedSegments, reusedSegments, processedFrames: Int
    public let completedRanges: [HDRCacheRange]
    public let error: String?
}

/// One preparation job owns at most one session and one segment writer. Replacing
/// the job cancels its generation, waits for admitted GPU work, then reuses the
/// persistent processor. Committed segments are reusable; staging is discarded.
public actor HDRPreparationCoordinator {
    private let cache: HDRSegmentCache
    private let configuration: HDRPipelineConfiguration
    private let processor: HDRPipelineProcessor
    private let decoderProvider: any FramePreparationDecoderProvider
    private var job: Task<Void, any Error>?
    private var generation: UInt64 = 0
    private var state: HDRPreparationProgress.State = .idle
    private var totalSegments = 0, completedSegments = 0, reusedSegments = 0, processedFrames = 0
    private var completedRanges: [HDRCacheRange] = []
    private var failure: String?

    public init(cache: HDRSegmentCache, configuration: HDRPipelineConfiguration,
                decoderProvider: any FramePreparationDecoderProvider = NativeFramePreparationProvider()) {
        self.cache = cache; self.configuration = configuration
        self.processor = HDRPipelineProcessor(configuration: configuration)
        self.decoderProvider = decoderProvider
    }

    public func start(sourceURL: URL, segments: [HDRPreparationSegment]) async throws {
        generation &+= 1
        let token = generation
        let previous = job
        previous?.cancel()
        if let previous { _ = await previous.result }
        guard token == generation else { throw CancellationError() }
        totalSegments = segments.count; completedSegments = 0; reusedSegments = 0; processedFrames = 0
        completedRanges = []; failure = nil; state = .preparing
        job = Task { try await self.run(sourceURL: sourceURL, segments: segments, token: token) }
    }

    public func wait() async throws { try await job?.value }
    public func cancel() async {
        generation &+= 1
        job?.cancel()
        if let job { _ = await job.result }
        state = .cancelled
    }
    public func progress() -> HDRPreparationProgress {
        .init(state: state, totalSegments: totalSegments, completedSegments: completedSegments,
              reusedSegments: reusedSegments, processedFrames: processedFrames, completedRanges: completedRanges, error: failure)
    }

    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func run(sourceURL: URL, segments: [HDRPreparationSegment], token: UInt64) async throws {
        do {
            guard let first = segments.first else { state = .complete; return }
            let sourceSignature = try PreparedSourceSignature.read(sourceURL.path)
            let fingerprint = try HDRCacheSource.fingerprint(url: sourceURL, streamIndex: first.identity.source.streamIndex,
                interpretation: first.identity.source.interpretation)
            guard try PreparedSourceSignature.read(sourceURL.path) == sourceSignature else {
                throw HDRCacheError.invalidIdentity("Source changed while preparation was fingerprinting it")
            }
            guard try configuration.modelVersion == preparedModelSHA256(configuration.modelURL) else {
                throw HDRCacheError.invalidIdentity("Model version does not match actual weights")
            }
            for segment in segments {
                try check(token)
                guard try PreparedSourceSignature.read(sourceURL.path) == sourceSignature else {
                    throw HDRCacheError.invalidIdentity("Source changed during preparation")
                }
                let identity = segment.identity
                guard identity.source == fingerprint,
                      identity.timingInventorySHA256 == nil || identity.source.interpretation["decoder"] == decoderProvider.identifier,
                      identity.settings.modelSHA256 == configuration.modelVersion,
                      identity.settings.processingWidth == configuration.processingWidth,
                      identity.settings.processingHeight == configuration.processingHeight,
                      identity.settings.effects["strength"] == Double(configuration.strength),
                      identity.settings.effects["colourStrength"] == Double(configuration.colourStrength),
                      identity.settings.effects["maximumLuminanceRatio"] == Double(configuration.maximumLuminanceRatio),
                      identity.settings.colourPolicy["storage"] != nil,
                      identity.preroll.policyVersion == "reset-decode-all-from-preroll-v1",
                      identity.preroll.randomSeed == 0 else {
                    throw HDRCacheError.invalidIdentity("Preparation settings/source do not match actual processor")
                }
                if let lease = try await cache.acquire(identity: identity) {
                    await cache.release(lease)
                    reusedSegments += 1; completedSegments += 1; completedRanges.append(identity.range)
                    continue
                }
                // The store rejects a storage policy it does not know when the writer begins.
                let writer = try await HDRCacheSegmentWriter.begin(cache, identity: identity, frameCount: segment.frameCount)
                do {
                    try await prepare(sourceURL: sourceURL, segment: segment, writer: writer, token: token)
                    try check(token)
                    guard try PreparedSourceSignature.read(sourceURL.path) == sourceSignature else {
                        throw HDRCacheError.invalidIdentity("Source changed before the prepared segment could be published")
                    }
                    try await writer.publish()
                    completedSegments += 1; completedRanges.append(identity.range)
                } catch {
                    await writer.cancel()
                    throw error
                }
            }
            try check(token)
            state = .complete
        } catch {
            if token == generation {
                state = error is CancellationError ? .cancelled : .failed
                failure = error is CancellationError ? nil : error.localizedDescription
            }
            throw error
        }
    }

    private func prepare(sourceURL: URL, segment: HDRPreparationSegment, writer: HDRCacheSegmentWriter, token: UInt64) async throws {
        let identity = segment.identity
        let session = try FrameSession(limits: .init(slots: 3, bytes: 512 * 1024 * 1024,
            processingWidth: configuration.processingWidth, processingHeight: configuration.processingHeight), processor: processor)
        defer { session.close() }
        let reader = try await decoderProvider.decoder(sourceURL: sourceURL,
            videoStreamIndex: identity.source.streamIndex,
            range: .init(start: identity.preroll.start, end: identity.range.end))
        var admitted = 0, consumed = 0
        do {
            while let decoded = try await reader.next() {
                defer { withExtendedLifetime(decoded) {} }
                try check(token)
                var descriptor = decoded.descriptor
                descriptor.source_id = 1; descriptor.generation = session.generation; descriptor.frame_id = UInt64(admitted)
                if let expected = segment.decodeTimings {
                    let timing = try HDRCacheFrameTiming(presentationTime: .init(value: descriptor.pts.value, timescale: descriptor.pts.timescale),
                        duration: .init(value: descriptor.duration.value, timescale: descriptor.duration.timescale))
                    guard admitted < expected.count, expected[expected.startIndex + admitted] == timing else {
                        throw HDRCacheError.invalidFrame("Prepared decoder differs from exact indexed preroll/output timing at frame \(admitted)")
                    }
                }
                while session.submit(descriptor) == FE_FULL {
                    consumed += try await consume(session: session, writer: writer, identity: identity, token: token)
                    try await Task.sleep(for: .milliseconds(1))
                }
                // The descriptor must have been accepted; failed inputs are detected
                // explicitly so a job cannot wait forever for an unsubmitted frame.
                guard session.statistics().submitted == UInt64(admitted + 1) else {
                    throw FrameEngineError.invalid("Preparation submission failed: \(session.error)")
                }
                admitted += 1
                consumed += try await consume(session: session, writer: writer, identity: identity, token: token)
            }
            if let expected = segment.decodeTimings, admitted != expected.count {
                throw HDRCacheError.invalidFrame("Prepared decoder omitted indexed preroll/output frames")
            }
            while consumed < admitted {
                try check(token)
                consumed += try await consume(session: session, writer: writer, identity: identity, token: token)
                if consumed < admitted { try await Task.sleep(for: .milliseconds(1)) }
            }
        } catch {
            session.reset()
            await reader.cancel()
            // Admitted work retains the shared processor. Wait until cancelled GPU
            // work finishes before another segment/job can reset temporal history.
            await session.waitUntilIdle()
            throw error
        }
        await reader.cancel()
    }

    private func consume(session: FrameSession, writer: HDRCacheSegmentWriter, identity: HDRCacheIdentity, token: UInt64) async throws -> Int {
        if session.statistics().failures > 0 { throw FrameEngineError.invalid(session.error) }
        var count = 0
        while let output = session.poll() {
            try check(token)
            count += 1
            let descriptor = output.descriptor
            let pts = try HDRCacheTime(value: descriptor.pts.value, timescale: descriptor.pts.timescale)
            if pts < identity.range.start { continue }
            let duration = try HDRCacheTime(value: descriptor.duration.value, timescale: descriptor.duration.timescale)
            try await writer.append(MLXPixelBuffer(output.pixelBuffer), timing: .init(presentationTime: pts, duration: duration))
            processedFrames += 1
        }
        return count
    }
}
