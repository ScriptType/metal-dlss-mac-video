import CFrameEngine
import CoreMedia
import CoreVideo
import CryptoKit
import DLSSMedia
import Foundation

public struct HDRPreparationSegment: Sendable {
    public let identity: HDRCacheIdentity
    public let frameCount: Int
    public init(identity: HDRCacheIdentity, frameCount: Int) { self.identity = identity; self.frameCount = frameCount }
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
    private var job: Task<Void, any Error>?
    private var generation: UInt64 = 0
    private var state: HDRPreparationProgress.State = .idle
    private var totalSegments = 0, completedSegments = 0, reusedSegments = 0, processedFrames = 0
    private var completedRanges: [HDRCacheRange] = []
    private var failure: String?

    public init(cache: HDRSegmentCache, configuration: HDRPipelineConfiguration) {
        self.cache = cache; self.configuration = configuration
        self.processor = HDRPipelineProcessor(configuration: configuration)
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
            let modelHash: String
            if let modelURL = configuration.modelURL {
                modelHash = try HDRCacheSource.fingerprint(url: modelURL.appendingPathComponent("weights.safetensors"), streamIndex: 0).contentSHA256
            } else {
                modelHash = SHA256.hash(data: Data("original-hdr-v1".utf8)).map { String(format: "%02x", $0) }.joined()
            }
            guard configuration.modelVersion == modelHash else {
                throw HDRCacheError.invalidIdentity("Model version does not match actual weights")
            }
            for segment in segments {
                try check(token)
                guard try PreparedSourceSignature.read(sourceURL.path) == sourceSignature else {
                    throw HDRCacheError.invalidIdentity("Source changed during preparation")
                }
                let identity = segment.identity
                guard identity.source == fingerprint,
                      identity.settings.modelSHA256 == configuration.modelVersion,
                      identity.settings.processingWidth == configuration.processingWidth,
                      identity.settings.processingHeight == configuration.processingHeight,
                      identity.settings.effects["strength"] == Double(configuration.strength),
                      identity.settings.effects["colourStrength"] == Double(configuration.colourStrength),
                      identity.settings.effects["maximumLuminanceRatio"] == Double(configuration.maximumLuminanceRatio),
                      identity.settings.colourPolicy["storage"] == HDRSegmentCache.storagePolicy,
                      identity.preroll.policyVersion == "reset-decode-all-from-preroll-v1",
                      identity.preroll.randomSeed == 0 else {
                    throw HDRCacheError.invalidIdentity("Preparation settings/source do not match actual processor")
                }
                if let lease = try await cache.acquire(identity: identity) {
                    await cache.release(lease)
                    reusedSegments += 1; completedSegments += 1; completedRanges.append(identity.range)
                    continue
                }
                let writer = try await cache.begin(identity: identity, expectedFrameCount: segment.frameCount)
                do {
                    try await prepare(sourceURL: sourceURL, segment: segment, writer: writer, token: token)
                    try check(token)
                    guard try PreparedSourceSignature.read(sourceURL.path) == sourceSignature else {
                        throw HDRCacheError.invalidIdentity("Source changed before the prepared segment could be published")
                    }
                    _ = try await cache.publish(writer)
                    completedSegments += 1; completedRanges.append(identity.range)
                } catch {
                    try? await cache.cancel(writer)
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

    private func prepare(sourceURL: URL, segment: HDRPreparationSegment, writer: HDRCacheWrite, token: UInt64) async throws {
        let identity = segment.identity
        let start = CMTime(value: identity.preroll.start.value, timescale: identity.preroll.start.timescale)
        let end = CMTime(value: identity.range.end.value, timescale: identity.range.end.timescale)
        let reader = try await NativeHDRVideoReader(url: sourceURL, generation: token,
            timeRange: CMTimeRange(start: start, end: end))
        let session = try FrameSession(limits: .init(slots: 3, bytes: 512 * 1024 * 1024,
            processingWidth: configuration.processingWidth, processingHeight: configuration.processingHeight), processor: processor)
        defer { session.close() }
        var admitted = 0, consumed = 0
        do {
            while let decoded = try await reader.nextDecoded() {
                try check(token)
                let descriptor = DecoderFrameDescriptor.make(pixelBuffer: decoded.pixelBuffer.buffer,
                    metadata: decoded.metadata, sourceID: 1, generation: session.generation)
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

    private func consume(session: FrameSession, writer: HDRCacheWrite, identity: HDRCacheIdentity, token: UInt64) async throws -> Int {
        if session.statistics().failures > 0 { throw FrameEngineError.invalid(session.error) }
        var count = 0
        while let output = session.poll() {
            try check(token)
            count += 1
            let descriptor = output.descriptor
            let pts = try HDRCacheTime(value: descriptor.pts.value, timescale: descriptor.pts.timescale)
            if pts < identity.range.start { continue }
            let duration = try HDRCacheTime(value: descriptor.duration.value, timescale: descriptor.duration.timescale)
            let buffer = output.pixelBuffer
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let rgba: [Float]
            if let address = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                var values: [Float] = []; values.reserveCapacity(width * height * 4)
                for y in 0..<height {
                    let row = address.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
                    values.append(contentsOf: UnsafeBufferPointer(start: row, count: width * 4).map(Float.init))
                }
                rgba = values
            } else {
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                throw HDRCacheError.invalidFrame("Missing completed float storage")
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            try await cache.append(HDRCacheFloatFrame(timing: .init(presentationTime: pts, duration: duration), rgba: rgba), to: writer)
            processedFrames += 1
        }
        return count
    }
}
