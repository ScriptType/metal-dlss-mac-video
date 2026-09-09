import AVFoundation
import CFrameEngine
import CoreVideo
import DLSSMedia
import Foundation

/// Exact decoded-frame timing and fixed coded geometry for one selected stream.
/// At most one million timing records are retained; pixel storage is never kept
/// by the inventory. Duplicate PTS and changing geometry are unsupported.
public struct FramePreparationInventory: Sendable {
    public let timings: [HDRCacheFrameTiming]
    public let width, height: Int
    public init(timings: [HDRCacheFrameTiming], width: Int, height: Int) throws {
        guard (1...16384).contains(width), (1...16384).contains(height),
              !timings.isEmpty, timings.count <= 1_000_000 else {
            throw FrameEngineError.invalid("Invalid Prepared inventory geometry/count; maximum one million frames")
        }
        let sorted = timings.sorted { $0.presentationTime < $1.presentationTime }
        for (index, frame) in sorted.enumerated() {
            guard frame.duration.value > 0,
                  index == 0 || sorted[index - 1].presentationTime < frame.presentationTime else {
                throw FrameEngineError.invalid("Prepared inventory requires strictly increasing PTS and positive durations")
            }
            _ = try frame.end
        }
        self.timings = sorted; self.width = width; self.height = height
    }

    /// Coverage is partitioned by the next frame's PTS, not by the previous
    /// frame's duration. Exact durations remain in the bound timing inventory.
    public func segments(source: HDRCacheSource, settings: HDRCacheSettings,
                         rangeStart: HDRCacheTime? = nil, rangeEnd: HDRCacheTime? = nil,
                         segmentFrames: Int = 60, prerollFrames: Int = 8) throws -> [HDRPreparationSegment] {
        guard (1...600).contains(segmentFrames), (0...600).contains(prerollFrames) else {
            throw FrameEngineError.invalid("Invalid Prepared segment/preroll frame limits")
        }
        let eof = try timings.last!.end
        let start = rangeStart ?? timings[0].presentationTime, end = rangeEnd ?? eof
        guard start < end, let first = timings.firstIndex(where: { $0.presentationTime == start }),
              end == eof || timings.contains(where: { $0.presentationTime == end }) else {
            throw FrameEngineError.invalid("Prepared range boundaries must coincide with exact source PTS or final frame end")
        }
        let limit = timings.firstIndex(where: { $0.presentationTime >= end }) ?? timings.count
        guard first < limit else { throw FrameEngineError.invalid("Prepared range contains no frames") }
        guard (limit - first + segmentFrames - 1) / segmentFrames <= 100_000 else {
            throw FrameEngineError.invalid("Prepared planning exceeds 100000 segments; increase segmentFrames or select a smaller range")
        }
        var result: [HDRPreparationSegment] = [], index = first
        while index < limit {
            try Task.checkCancellation()
            let next = min(index + segmentFrames, limit), preroll = max(0, index - prerollFrames)
            let segmentEnd = next == limit ? end : timings[next].presentationTime
            let outputTimings = Array(timings[index..<next])
            let identity = try HDRCacheIdentity(source: source,
                range: .init(start: timings[index].presentationTime, end: segmentEnd), settings: settings,
                preroll: .init(start: timings[preroll].presentationTime, policyVersion: "reset-decode-all-from-preroll-v1"),
                timingInventorySHA256: HDRCacheFrameTiming.inventoryDigest(outputTimings))
            result.append(.init(identity: identity, frameCount: outputTimings.count,
                decodeTimingsSlice: timings[preroll..<next]))
            index = next
        }
        return result
    }
}

public protocol FramePreparationDecoder: Sendable {
    /// Ordered immutable decoded source storage. The result owns its CV buffer.
    func next() async throws -> EngineInput?
    func cancel() async
}

public protocol FramePreparationDecoderProvider: Sendable {
    var identifier: String { get }
    func inventory(sourceURL: URL, videoStreamIndex: Int) async throws -> FramePreparationInventory
    func decoder(sourceURL: URL, videoStreamIndex: Int, range: HDRCacheRange) async throws -> any FramePreparationDecoder
}

/// Standalone native harness backend. Selected playback cores can supply their
/// own provider without linking a second copy of their decoder into this library.
public struct NativeFramePreparationProvider: FramePreparationDecoderProvider {
    public let identifier = "NativeHDRVideoReader-planar-output-timing-v2"
    public init() {}
    public func inventory(sourceURL: URL, videoStreamIndex: Int) async throws -> FramePreparationInventory {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.indices.contains(videoStreamIndex),
              let format = try await tracks[videoStreamIndex].load(.formatDescriptions).first else {
            throw FrameEngineError.invalid("Prepared source has no selected video format")
        }
        let track = tracks[videoStreamIndex], dimensions = CMVideoFormatDescriptionGetDimensions(format)
        // Same documented missing-duration interpretation as NativeHDRVideoReader.
        let rate = try await track.load(.nominalFrameRate)
        let fallbackDuration = CMTime(seconds: 1 / Double(rate.isFinite && rate > 0 ? rate : 30), preferredTimescale: 60000)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FrameEngineError.invalid("Cannot scan Prepared timestamps") }
        let provider = reader.outputProvider(for: output)
        guard reader.startReading() else { throw reader.error ?? FrameEngineError.invalid("Cannot start Prepared timestamp scan") }
        defer { reader.cancelReading() }
        var timings: [HDRCacheFrameTiming] = []
        while let sample = try await provider.next() {
            try Task.checkCancellation()
            if sample.sampleCount == 0 { continue }
            guard sample.sampleCount == 1 else { throw FrameEngineError.invalid("Prepared scan requires one compressed video frame per sample") }
            let pts = sample.outputPresentationTimeStamp
            let duration = sample.outputDuration.isNumeric && sample.outputDuration > .zero ? sample.outputDuration : fallbackDuration
            guard pts.isNumeric, timings.count < 1_000_000 else { throw FrameEngineError.invalid("Invalid Prepared timestamp inventory") }
            timings.append(try .init(presentationTime: .init(value: pts.value, timescale: pts.timescale),
                duration: .init(value: duration.value, timescale: duration.timescale)))
        }
        if reader.status == .failed { throw reader.error ?? FrameEngineError.invalid("Prepared timestamp scan failed") }
        return try .init(timings: timings, width: Int(dimensions.width), height: Int(dimensions.height))
    }
    public func decoder(sourceURL: URL, videoStreamIndex: Int, range: HDRCacheRange) async throws -> any FramePreparationDecoder {
        guard videoStreamIndex == 0 else { throw FrameEngineError.invalid("Native preparation currently supports the first video stream") }
        let reader = try await NativeHDRVideoReader(url: sourceURL,
            timeRange: CMTimeRange(start: .init(value: range.start.value, timescale: range.start.timescale),
                                  end: .init(value: range.end.value, timescale: range.end.timescale)))
        return NativeFramePreparationDecoder(reader)
    }
}

private actor NativeFramePreparationDecoder: FramePreparationDecoder {
    let reader: NativeHDRVideoReader
    init(_ reader: NativeHDRVideoReader) { self.reader = reader }
    func next() async throws -> EngineInput? {
        guard let frame = try await reader.nextDecoded() else { return nil }
        return EngineInput(DecoderFrameDescriptor.make(pixelBuffer: frame.pixelBuffer.buffer,
            metadata: frame.metadata, sourceID: 1, generation: 1))
    }
    func cancel() async { await reader.cancel() }
}

/// The vtable is immutable. The optional user owner and callback code outlive all
/// per-context readers; each reader has its own serial utility queue.
final class CFramePreparationProvider: FramePreparationDecoderProvider, @unchecked Sendable {
    let identifier: String
    let callbacks: fe_preparation_decoder_provider
    init(_ pointer: UnsafePointer<fe_preparation_decoder_provider>) throws {
        let value = pointer.pointee
        guard value.struct_size >= MemoryLayout<fe_preparation_decoder_provider>.size,
              value.abi_version == FE_ABI_VERSION, let identifier = value.identifier,
              value.open != nil, value.next != nil, value.cancel != nil, value.close != nil,
              value.user == nil || (value.retain_user != nil && value.release_user != nil) else {
            throw FrameEngineError.invalid("Invalid Prepared decoder ABI, callbacks or user ownership")
        }
        self.identifier = String(cString: identifier)
        guard !self.identifier.isEmpty, self.identifier.utf8.count <= 4096 else {
            throw FrameEngineError.invalid("Prepared decoder identifier must contain a bounded semantic version")
        }
        callbacks = value
        if let user = value.user { value.retain_user?(user) }
    }
    deinit { if let user = callbacks.user { callbacks.release_user?(user) } }

    func inventory(sourceURL: URL, videoStreamIndex: Int) async throws -> FramePreparationInventory {
        let reader = CFramePreparationDecoder(provider: self, mode: FE_PREPARATION_INVENTORY.rawValue)
        do {
            try await reader.open(sourceURL: sourceURL, videoStreamIndex: videoStreamIndex, range: nil)
            var timings: [HDRCacheFrameTiming] = [], width: UInt32?, height: UInt32?
            while let sample = try await reader.sample() {
                try Task.checkCancellation()
                let frame = sample.descriptor
                if width == nil { width = frame.geometry.width; height = frame.geometry.height }
                guard frame.geometry.width == width, frame.geometry.height == height, timings.count < 1_000_000 else {
                    throw FrameEngineError.invalid("Prepared inventory changes geometry or exceeds one million frames")
                }
                timings.append(try .init(presentationTime: .init(value: frame.pts.value, timescale: frame.pts.timescale),
                    duration: .init(value: frame.duration.value, timescale: frame.duration.timescale)))
            }
            await reader.cancel()
            return try .init(timings: timings, width: Int(width ?? 0), height: Int(height ?? 0))
        } catch { await reader.cancel(); throw error }
    }
    func decoder(sourceURL: URL, videoStreamIndex: Int, range: HDRCacheRange) async throws -> any FramePreparationDecoder {
        let reader = CFramePreparationDecoder(provider: self, mode: FE_PREPARATION_PIXELS.rawValue)
        do {
            try await reader.open(sourceURL: sourceURL, videoStreamIndex: videoStreamIndex, range: range)
            return reader
        } catch { await reader.cancel(); throw error }
    }
}

private final class PreparationSample: @unchecked Sendable {
    let descriptor: fe_frame
    let input: EngineInput?
    init(_ descriptor: fe_frame, input: EngineInput?) { self.descriptor = descriptor; self.input = input }
}

private final class CFramePreparationDecoder: FramePreparationDecoder, @unchecked Sendable {
    let provider: CFramePreparationProvider
    let mode: UInt32
    let queue = DispatchQueue(label: "FrameEngine.preparation.decoder", qos: .utility)
    let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var cancelled = false
    init(provider: CFramePreparationProvider, mode: UInt32) { self.provider = provider; self.mode = mode }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async { continuation.resume(with: Result { try body() }) }
            }
        } onCancel: { self.signalCancel() }
    }
    func open(sourceURL: URL, videoStreamIndex: Int, range: HDRCacheRange?) async throws {
        try await perform {
            var error = [CChar](repeating: 0, count: 2048)
            let start = range.map { fe_time(value: $0.start.value, timescale: $0.start.timescale) } ?? fe_time()
            let end = range.map { fe_time(value: $0.end.value, timescale: $0.end.timescale) } ?? fe_time()
            let pointer = sourceURL.path.withCString { path in
                self.provider.callbacks.open?(self.provider.callbacks.user, path, UInt32(videoStreamIndex), start, end, self.mode, &error, error.count)
            }
            guard let pointer else { throw FrameEngineError.invalid("Prepared decoder open: \(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))") }
            self.lock.withLock {
                self.handle = pointer
                if self.cancelled { self.provider.callbacks.cancel?(pointer) }
            }
        }
    }
    func sample() async throws -> PreparationSample? {
        try await perform {
            let pointer = try self.lock.withLock {
                guard !self.cancelled, let handle = self.handle else { throw CancellationError() }
                return handle
            }
            var error = [CChar](repeating: 0, count: 2048), frame = fe_frame()
            let result = self.provider.callbacks.next?(pointer, &frame, &error, error.count)
            if result == FE_CANCELLED || self.lock.withLock({ self.cancelled }) { throw CancellationError() }
            if result == FE_EMPTY { return nil }
            guard result == FE_ACCEPTED else { throw FrameEngineError.invalid("Prepared decoder next: \(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))") }
            guard frame.struct_size >= MemoryLayout<fe_frame>.size, frame.abi_version == FE_ABI_VERSION,
                  frame.pts.timescale > 0, frame.duration.timescale > 0, frame.duration.value > 0,
                  (1...16384).contains(frame.geometry.width), (1...16384).contains(frame.geometry.height),
                  frame.owner == nil || (frame.retain_owner != nil && frame.release_owner != nil) else {
                throw FrameEngineError.invalid("Prepared decoder returned invalid frame ABI/timing/geometry/ownership")
            }
            if self.mode == FE_PREPARATION_PIXELS.rawValue {
                guard frame.pixel_buffer != nil else { throw FrameEngineError.invalid("Prepared decoder returned no pixel buffer") }
                return PreparationSample(frame, input: EngineInput(frame))
            }
            return PreparationSample(frame, input: nil)
        }
    }
    func next() async throws -> EngineInput? { try await sample()?.input }
    private func signalCancel() {
        lock.withLock {
            cancelled = true
            if let handle { provider.callbacks.cancel?(handle) }
        }
    }
    func cancel() async {
        signalCancel()
        // Cleanup must execute even in an already-cancelled Swift task.
        await withCheckedContinuation { continuation in
            queue.async {
                let pointer = self.lock.withLock { let old = self.handle; self.handle = nil; return old }
                if let pointer { self.provider.callbacks.close?(pointer) }
                continuation.resume()
            }
        }
    }
    deinit {
        // Normal owners explicitly cancel/close. This covers a dropped reader too.
        if let handle {
            provider.callbacks.cancel?(handle)
            let provider = provider, address = UInt(bitPattern: handle)
            queue.async { provider.callbacks.close?(UnsafeMutableRawPointer(bitPattern: address)) }
        }
    }
}
