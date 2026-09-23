import CoreMedia
import CoreVideo
import DLSSMLX
import Foundation
import IOSurface
import Metal
import VideoToolbox

/// The production HEVC storage policy. Every constant that can change stored pixels is
/// interpolated into `storagePolicy`, which is part of every key, so changing one
/// invalidates old segments instead of misreading them.
public enum HDRCacheHEVC {
    static let averageBitsPerSecondAt1080p = 8_000_000
    static let peakBitsPerSecondAt1080p = 9_000_000
    public static let storagePolicy =
        "hevc-main10-videotoolbox-hw;st2084-bt2020nc-video-range-420-chroma-topleft-decimated;"
        + "rgb-clip-0-10000-nits;opaque;"
        + "abr-\(averageBitsPerSecondAt1080p)-peak-\(peakBitsPerSecondAt1080p)-1s-per-1080p-area;"
        + "one-idr-per-segment;no-reordering;nal-length-4;v1"

    /// Scales with output area, never below the 1080p rates.
    static func bitRates(width: Int, height: Int) -> (average: Int, peak: Int) {
        let scale = max(1, Double(width) * Double(height) / (1920 * 1080))
        return (Int(Double(averageBitsPerSecondAt1080p) * scale), Int(Double(peakBitsPerSecondAt1080p) * scale))
    }

    /// Index: the Float16 bit pattern of a linear-nits channel. Value: the ST 2084 E′ of that
    /// channel clipped to 0...10,000 nits, or -1 for NaN and infinity, which reject the frame.
    /// RGBA16F has exactly 65,536 inputs, so the table is the exact encoder for every one.
    static let pqTable: [Float] = {
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
        let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        return (0...UInt16.max).map { bits in
            let value = Float16(bitPattern: bits)
            guard value.isFinite else { return -1 }
            let y = pow(min(max(Double(value), 0), 10_000) / 10_000, m1)
            return Float(pow((c1 + c2 * y) / (1 + c3 * y), m2))
        }
    }()

    /// Decode-side colour, told to the importer explicitly rather than read from stream tags.
    static let colour = MLXHDRColorMetadata(transfer: .pq, primaries: .bt2020, matrix: .bt2020,
                                            fullRange: false, chromaLocation: .topLeft)
}

/// One segment being prepared. Callers append completed linear-nits RGBA16F frames in PTS
/// order and publish. The identity's storage decides which bytes reach the store.
actor HDRCacheSegmentWriter {
    private enum Encoding {
        case float32
        case hevc(HEVCEncoder)
    }
    private let cache: HDRSegmentCache
    private let token: HDRCacheWrite
    private let encoding: Encoding

    private init(cache: HDRSegmentCache, token: HDRCacheWrite, encoding: Encoding) {
        self.cache = cache; self.token = token; self.encoding = encoding
    }

    /// The token is cancelled if the compression session cannot be created.
    static func begin(_ cache: HDRSegmentCache, identity: HDRCacheIdentity, frameCount: Int) async throws -> HDRCacheSegmentWriter {
        let token = try await cache.begin(identity: identity, expectedFrameCount: frameCount)
        do {
            let encoding: Encoding
            switch try HDRCacheStorage(identity) {
            case .float32: encoding = .float32
            case .hevc: encoding = .hevc(try HEVCEncoder(width: identity.settings.outputWidth,
                                                         height: identity.settings.outputHeight, frameCount: frameCount))
            }
            return HDRCacheSegmentWriter(cache: cache, token: token, encoding: encoding)
        } catch {
            try? await cache.cancel(token)
            throw error
        }
    }

    func append(_ frame: MLXPixelBuffer, timing: HDRCacheFrameTiming) async throws {
        guard CVPixelBufferGetPixelFormatType(frame.buffer) == kCVPixelFormatType_64RGBAHalf else {
            throw HDRCacheError.invalidFrame("Prepared frames must be RGBA16F")
        }
        switch encoding {
        case .float32:
            try await cache.append(HDRCacheFloatFrame(timing: timing, rgba: try Self.floats(frame.buffer)), to: token)
        case .hevc(let encoder):
            for sample in try await encoder.encode(frame, timing: timing) { try await cache.append(sample, to: token) }
        }
    }

    @discardableResult
    func publish() async throws -> HDRCacheManifest {
        if case .hevc(let encoder) = encoding {
            for sample in try encoder.finish() { try await cache.append(sample, to: token) }
            encoder.invalidate()
        }
        return try await cache.publish(token)
    }

    /// Safe to repeat, and after a failed publish: it converges to no session and no stage.
    func cancel() async {
        if case .hevc(let encoder) = encoding { encoder.invalidate() }
        try? await cache.cancel(token)
    }

    private static func floats(_ buffer: CVPixelBuffer) throws -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else {
            throw HDRCacheError.invalidFrame("Missing completed float storage")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var rgba: [Float] = []; rgba.reserveCapacity(width * height * 4)
        for y in 0..<height {
            let row = address.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
            rgba.append(contentsOf: UnsafeBufferPointer(start: row, count: width * 4).map(Float.init))
        }
        return rgba
    }
}

/// Playback half. Returns frame `index` of a lease as a complete RGBA16F IOSurface buffer in
/// linear BT.2020 absolute nits, whatever the storage. It keeps one HEVC decode position, so
/// sequential frames cost one decode each and a mid-segment entry decodes from the IDR.
actor HDRCacheFrameReader {
    private struct DecodePosition {
        let lease: UUID
        let decoder: HEVCDecoder
        let next: Int
    }
    private var importer: MLXHDRImporter?
    private var writer: (writer: MLXPixelBufferWriter, width: Int, height: Int)?
    private var position: DecodePosition?

    init() {}

    func frame(_ index: Int, of lease: HDRCacheLease, in cache: HDRSegmentCache) async throws -> MLXPixelBuffer {
        let settings = lease.manifest.identity.settings
        switch try HDRCacheStorage(lease.manifest.identity) {
        case .float32:
            let frame = try await cache.read(lease, frameIndex: index)
            return try Self.pack(frame.rgba, width: settings.outputWidth, height: settings.outputHeight)
        case .hevc:
            return try await decode(index, of: lease, in: cache)
        }
    }

    private func decode(_ index: Int, of lease: HDRCacheLease, in cache: HDRSegmentCache) async throws -> MLXPixelBuffer {
        let resume = position.flatMap { $0.lease == lease.id && $0.next <= index ? $0 : nil }
        let first = resume?.next ?? 0
        var samples: [HDRCacheHEVCSample] = []
        for frameIndex in first...index { samples.append(try await cache.readSample(lease, frameIndex: frameIndex)) }
        // Another frame() call may have advanced the decoder while this one awaited the store.
        guard resume == nil || (position?.lease == lease.id && position?.next == first) else {
            throw HDRCacheError.unavailable
        }
        let decoder: HEVCDecoder
        if let resume {
            decoder = resume.decoder
        } else {
            let format = try HEVCDecoder.format(firstSample: samples[0].data)
            if let reusable = position?.decoder, reusable.accepts(format.description) {
                decoder = reusable
            } else {
                decoder = try HEVCDecoder(format.description)
            }
            decoder.format = format.description
            samples[0] = HDRCacheHEVCSample(timing: samples[0].timing, data: Data(samples[0].data.dropFirst(format.pictureOffset)))
        }
        position = nil
        let image = try decoder.decode(samples)
        position = DecodePosition(lease: lease.id, decoder: decoder, next: index + 1)

        let settings = lease.manifest.identity.settings, timing = samples[samples.count - 1].timing
        try HDRRuntimeResources.shared.prepareAllocator()
        if importer == nil { importer = try MLXHDRImporter() }
        let original = try await importer!.importFrame(pixelBuffer: MLXPixelBuffer(image),
            metadata: .init(time: CMTime(timing.presentationTime), duration: CMTime(timing.duration),
                            sourceID: "prepared-hevc", frameIndex: UInt64(index), color: HDRCacheHEVC.colour))
        if writer?.width != settings.outputWidth || writer?.height != settings.outputHeight {
            writer = (try MLXPixelBufferWriter(width: settings.outputWidth, height: settings.outputHeight, halfOutput: true),
                      settings.outputWidth, settings.outputHeight)
        }
        let output = try await writer!.writer.write(original.original)
        Self.tagLinearBT2020(output.buffer)
        return output
    }

    private static func pack(_ rgba: [Float], width: Int, height: Int) throws -> MLXPixelBuffer {
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
        tagLinearBT2020(buffer)
        return MLXPixelBuffer(buffer)
    }

    private static func tagLinearBT2020(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_Linear, .shouldPropagate)
    }
}

/// Hardware HEVC Main10 compression of one segment, fed by the GPU PQ exporter.
final class HEVCEncoder: @unchecked Sendable {
    /// Whether this Mac opens a hardware Main10 session with the production properties.
    static let isAvailable = (try? HEVCEncoder(width: 256, height: 144, frameCount: 1)) != nil

    private let session: VTCompressionSession
    private let pool: CVPixelBufferPool
    private let exporter: PQExporter
    private let outputs = EncoderOutputs()
    private var format: CMFormatDescription?
    private var submitted = 0

    /// Every property below is fixed by `HDRCacheHEVC.storagePolicy`. No mastering or
    /// content-light metadata: transformed output must not claim the source's maxima.
    init(width: Int, height: Int, frameCount: Int) throws {
        exporter = try PQExporter.shared.get()
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                    kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                    kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { throw FrameEngineError.invalid("Hardware HEVC encoder unavailable: \(status)") }
        session = created
        let rates = HDRCacheHEVC.bitRates(width: width, height: height)
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel),
            (kVTCompressionPropertyKey_RealTime, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, frameCount as CFNumber),
            (kVTCompressionPropertyKey_AverageBitRate, rates.average as CFNumber),
            (kVTCompressionPropertyKey_DataRateLimits, [rates.peak / 8, 1] as CFArray),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_2020),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_2020),
        ]
        for (key, value) in properties {
            status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                VTCompressionSessionInvalidate(session)
                throw FrameEngineError.invalid("HEVC encoder rejected \(key): \(status)")
            }
        }
        status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr, let pool = VTCompressionSessionGetPixelBufferPool(session) else {
            VTCompressionSessionInvalidate(session)
            throw FrameEngineError.invalid("HEVC encoder has no source pool: \(status)")
        }
        self.pool = pool
    }

    deinit { VTCompressionSessionInvalidate(session) }

    /// Exports the frame into a pooled P010 buffer and submits it. Returns the samples that have
    /// completed so far, each paired in order with its exact rational timing.
    func encode(_ frame: MLXPixelBuffer, timing: HDRCacheFrameTiming) async throws -> [HDRCacheHEVCSample] {
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess, let destination = created else {
            throw FrameEngineError.invalid("HEVC encoder pool is exhausted")
        }
        try await exporter.export(frame.buffer, into: destination)
        CVBufferSetAttachment(destination, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(destination, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_TopLeft, .shouldPropagate)
        outputs.submit(timing)
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: destination,
            presentationTimeStamp: CMTime(timing.presentationTime), duration: CMTime(timing.duration),
            frameProperties: submitted == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil,
            infoFlagsOut: nil) { [outputs] status, flags, sample in outputs.complete(status, flags, sample) }
        guard status == noErr else { throw FrameEngineError.invalid("HEVC encode failed: \(status)") }
        submitted += 1
        return try drain()
    }

    /// Flushes the session. Every submitted frame must have produced exactly one sample.
    func finish() throws -> [HDRCacheHEVCSample] {
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else { throw FrameEngineError.invalid("HEVC encoder flush failed: \(status)") }
        let samples = try drain()
        guard outputs.pending == 0 else { throw FrameEngineError.invalid("HEVC encoder dropped frames") }
        return samples
    }

    func invalidate() { VTCompressionSessionInvalidate(session) }

    private func drain() throws -> [HDRCacheHEVCSample] {
        try outputs.take().map { timing, sample in
            guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(timing.presentationTime)) == 0,
                  let sampleFormat = CMSampleBufferGetFormatDescription(sample),
                  let block = CMSampleBufferGetDataBuffer(sample) else {
                throw FrameEngineError.invalid("HEVC encoder reordered or lost a frame")
            }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw FrameEngineError.invalid("Cannot read HEVC sample: \(status)") }
            if let format {
                guard CMFormatDescriptionEqual(format, otherFormatDescription: sampleFormat) else {
                    throw FrameEngineError.invalid("HEVC parameter sets changed within a segment")
                }
                return HDRCacheHEVCSample(timing: timing, data: data)
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            guard attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true else {
                throw FrameEngineError.invalid("First HEVC sample of a segment is not a sync sample")
            }
            format = sampleFormat
            return HDRCacheHEVCSample(timing: timing, data: try Self.parameterSets(sampleFormat) + data)
        }
    }

    /// VPS, SPS and PPS as 4-byte length-prefixed NAL units, in that order.
    private static func parameterSets(_ format: CMFormatDescription) throws -> Data {
        var count = 0, headerLength: Int32 = 0
        var status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        guard status == noErr, headerLength == 4 else { throw FrameEngineError.invalid("HEVC samples must use 4-byte NAL lengths") }
        var sets: [UInt8: Data] = [:]
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?, size = 0
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer, size >= 2 else { throw FrameEngineError.invalid("Invalid HEVC parameter set") }
            let type = (pointer[0] >> 1) & 0x3f
            guard sets[type] == nil else { throw FrameEngineError.invalid("Repeated HEVC parameter set type \(type)") }
            sets[type] = withUnsafeBytes(of: UInt32(size).bigEndian) { Data($0) } + Data(bytes: pointer, count: size)
        }
        guard let vps = sets[32], let sps = sets[33], let pps = sets[34] else {
            throw FrameEngineError.invalid("HEVC format lacks VPS, SPS or PPS")
        }
        return vps + sps + pps
    }
}

/// Compression results arrive on a VideoToolbox thread; the encoder drains them in order.
private final class EncoderOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var timings: [HDRCacheFrameTiming] = []
    private var completed: [(HDRCacheFrameTiming, CMSampleBuffer)] = []
    private var failure: String?

    var pending: Int { lock.withLock { timings.count } }

    func submit(_ timing: HDRCacheFrameTiming) { lock.withLock { timings.append(timing) } }

    func complete(_ status: OSStatus, _ flags: VTEncodeInfoFlags, _ sample: CMSampleBuffer?) {
        lock.withLock {
            guard failure == nil else { return }
            guard status == noErr, let sample, !flags.contains(.frameDropped), !timings.isEmpty else {
                failure = "HEVC encoder failed or dropped a frame: \(status)"
                return
            }
            completed.append((timings.removeFirst(), sample))
        }
    }

    func take() throws -> [(HDRCacheFrameTiming, CMSampleBuffer)] {
        try lock.withLock {
            if let failure { throw FrameEngineError.invalid(failure) }
            defer { completed.removeAll() }
            return completed
        }
    }
}

/// One VideoToolbox decompression session. Decoding is synchronous and the stream has no
/// reordering, so every submitted sample completes before `decode` returns.
private final class HEVCDecoder: @unchecked Sendable {
    let session: VTDecompressionSession
    var format: CMVideoFormatDescription

    init(_ format: CMVideoFormatDescription) throws {
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                    kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else { throw FrameEngineError.invalid("Cannot create HEVC decoder: \(status)") }
        session = created
        self.format = format
    }

    deinit { VTDecompressionSessionInvalidate(session) }

    func accepts(_ format: CMVideoFormatDescription) -> Bool {
        VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format)
    }

    /// The format description built from frame 0's parameter sets, and the offset of the
    /// picture data that follows them.
    static func format(firstSample data: Data) throws -> (description: CMVideoFormatDescription, pictureOffset: Int) {
        try data.withUnsafeBytes { bytes in
            guard let units = HDRCacheHEVCSample.nalUnits(bytes), units.count > 3 else {
                throw HDRCacheError.corruptSegment("HEVC frame 0 lacks parameter sets")
            }
            let sets = Array(units.prefix(3))
            let base = bytes.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let pointers = sets.map { base + $0.lowerBound }, sizes = sets.map(\.count)
            var format: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: 3,
                parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4,
                extensions: nil, formatDescriptionOut: &format)
            guard status == noErr, let format else { throw HDRCacheError.corruptSegment("Invalid HEVC parameter sets: \(status)") }
            return (format, sets[2].upperBound)
        }
    }

    /// Decodes every sample in order and returns the last picture. Earlier samples only
    /// rebuild reference state after a mid-segment entry.
    func decode(_ samples: [HDRCacheHEVCSample]) throws -> CVPixelBuffer {
        final class Output: @unchecked Sendable { var image: CVPixelBuffer?; var status: OSStatus = noErr }
        let output = Output()
        for (offset, sample) in samples.enumerated() {
            let last = offset == samples.count - 1
            let buffer = try sampleBuffer(sample)
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer,
                flags: last ? [] : [._DoNotOutputFrame], infoFlagsOut: nil) { status, _, image, _, _ in
                if status != noErr { output.status = status }
                if last { output.image = image }
            }
            guard status == noErr, output.status == noErr else {
                throw HDRCacheError.corruptSegment("HEVC decode failed: \(status), \(output.status)")
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard let image = output.image else { throw HDRCacheError.corruptSegment("HEVC decoder produced no picture") }
        return image
    }

    private func sampleBuffer(_ sample: HDRCacheHEVCSample) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: sample.data.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: sample.data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw FrameEngineError.invalid("Cannot allocate HEVC sample: \(status)") }
        status = sample.data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: $0.count)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(sample.timing.duration),
            presentationTimeStamp: CMTime(sample.timing.presentationTime), decodeTimeStamp: .invalid)
        var size = sample.data.count
        var buffer: CMSampleBuffer?
        if status == noErr {
            status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
                sampleBufferOut: &buffer)
        }
        guard status == noErr, let buffer else { throw FrameEngineError.invalid("Cannot wrap HEVC sample: \(status)") }
        return buffer
    }
}

/// RGBA16F linear nits to P010 video-range ST 2084 BT.2020 NCL with top-left chroma. One GPU
/// thread per 2x2 block; the block's chroma is its top-left pixel's, which the importer's
/// top-left bilinear reconstruction returns exactly at even positions.
final class PQExporter: @unchecked Sendable {
    static let shared = Result { try PQExporter() }
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let table: any MTLBuffer

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw FrameEngineError.invalid("Metal is unavailable")
        }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: Self.shader, options: options)
        guard let function = library.makeFunction(name: "exportPQ"),
              let table = HDRCacheHEVC.pqTable.withUnsafeBytes({
                  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
              }) else { throw FrameEngineError.invalid("Cannot build the PQ exporter") }
        self.device = device; self.queue = queue; self.table = table
        pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Throws `invalidFrame` when any channel is NaN or infinity or any alpha is not exactly 1.
    func export(_ source: CVPixelBuffer, into destination: CVPixelBuffer) async throws {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_64RGBAHalf,
              CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetWidth(destination) == width, CVPixelBufferGetHeight(destination) == height,
              width % 2 == 0, height % 2 == 0,
              let input = CVPixelBufferGetIOSurface(source)?.takeUnretainedValue(),
              let output = CVPixelBufferGetIOSurface(destination)?.takeUnretainedValue() else {
            throw HDRCacheError.invalidFrame("PQ export needs matching RGBA16F and P010 IOSurfaces with even geometry")
        }
        let outputBase = IOSurfaceGetBaseAddress(output)
        guard let sourceBuffer = device.makeBuffer(bytesNoCopy: IOSurfaceGetBaseAddress(input), length: IOSurfaceGetAllocSize(input),
                                                   options: .storageModeShared, deallocator: nil),
              let outputBuffer = device.makeBuffer(bytesNoCopy: outputBase, length: IOSurfaceGetAllocSize(output),
                                                   options: .storageModeShared, deallocator: nil),
              let invalid = device.makeBuffer(length: 4, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw FrameEngineError.invalid("Cannot bind PQ export buffers")
        }
        invalid.contents().storeBytes(of: 0, as: UInt32.self)
        var layout = SIMD4<UInt32>(UInt32(width), UInt32(height), UInt32(IOSurfaceGetBytesPerRow(input) / 2),
                                   UInt32(IOSurfaceGetBytesPerRowOfPlane(output, 0) / 2))
        var chromaRow = UInt32(IOSurfaceGetBytesPerRowOfPlane(output, 1) / 2)
        command.label = "Prepared HEVC PQ export"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(sourceBuffer, offset: 0, index: 0)
        encoder.setBuffer(table, offset: 0, index: 1)
        encoder.setBuffer(outputBuffer, offset: outputBase.distance(to: IOSurfaceGetBaseAddressOfPlane(output, 0)), index: 2)
        encoder.setBuffer(outputBuffer, offset: outputBase.distance(to: IOSurfaceGetBaseAddressOfPlane(output, 1)), index: 3)
        encoder.setBuffer(invalid, offset: 0, index: 4)
        encoder.setBytes(&layout, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 5)
        encoder.setBytes(&chromaRow, length: 4, index: 6)
        encoder.dispatchThreads(MTLSize(width: width / 2, height: height / 2, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        let owners = ExportOwners(source: MLXPixelBuffer(source), destination: MLXPixelBuffer(destination),
                                  buffers: [sourceBuffer, outputBuffer])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            command.addCompletedHandler { [owners] completed in
                withExtendedLifetime(owners) {
                    if let error = completed.error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            command.commit()
        }
        guard invalid.contents().load(as: UInt32.self) == 0 else {
            throw HDRCacheError.invalidFrame("HEVC storage rejects NaN, infinity and alpha other than 1")
        }
    }

    private final class ExportOwners: @unchecked Sendable {
        let source: MLXPixelBuffer, destination: MLXPixelBuffer, buffers: [any MTLBuffer]
        init(source: MLXPixelBuffer, destination: MLXPixelBuffer, buffers: [any MTLBuffer]) {
            self.source = source; self.destination = destination; self.buffers = buffers
        }
    }

    private static let shader = #"""
        #include <metal_stdlib>
        using namespace metal;
        kernel void exportPQ(device const ushort *source [[buffer(0)]], device const float *pq [[buffer(1)]],
                             device ushort *luma [[buffer(2)]], device ushort *chroma [[buffer(3)]],
                             device atomic_uint *invalid [[buffer(4)]], constant uint4 &layout [[buffer(5)]],
                             constant uint &chromaRow [[buffer(6)]], uint2 block [[thread_position_in_grid]]) {
          if (block.x * 2 >= layout.x || block.y * 2 >= layout.y) return;
          bool bad = false;
          float3 topLeft = 0.0f;
          float topLeftY = 0.0f;
          for (uint dy = 0; dy < 2; ++dy) {
            for (uint dx = 0; dx < 2; ++dx) {
              uint x = block.x * 2 + dx, y = block.y * 2 + dy;
              device const ushort *pixel = source + y * layout.z + x * 4;
              float3 e = float3(pq[pixel[0]], pq[pixel[1]], pq[pixel[2]]);
              bad = bad || any(e < 0.0f) || pixel[3] != 0x3c00;
              float yPrime = 0.2627f * e.r + 0.6780f * e.g + 0.0593f * e.b;
              luma[y * layout.w + x] = ushort((64 + int(rint(876.0f * yPrime))) << 6);
              if (dx == 0 && dy == 0) { topLeft = e; topLeftY = yPrime; }
            }
          }
          float cb = (topLeft.b - topLeftY) / 1.8814f, cr = (topLeft.r - topLeftY) / 1.4746f;
          chroma[block.y * chromaRow + block.x * 2] = ushort((512 + int(rint(896.0f * cb))) << 6);
          chroma[block.y * chromaRow + block.x * 2 + 1] = ushort((512 + int(rint(896.0f * cr))) << 6);
          if (bad) atomic_store_explicit(invalid, 1u, memory_order_relaxed);
        }
        """#
}

private extension CMTime {
    init(_ time: HDRCacheTime) { self.init(value: time.value, timescale: time.timescale) }
}
