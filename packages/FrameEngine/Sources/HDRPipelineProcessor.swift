import CFrameEngine
import CoreMedia
import CoreVideo
import DLSSMedia
import DLSSMLX
import Foundation
import Metal

/// Immutable session settings, copied at the C boundary. Resource construction
/// takes place on the worker's first frame, including model loading/compilation.
public struct HDRPipelineConfiguration: Sendable {
    public var modelURL: URL?
    public var modelVersion: String
    public var processingWidth, processingHeight: Int
    public var strength, colourStrength, maximumLuminanceRatio: Float
    public var referenceWhiteNits: Float
    public init(modelURL: URL? = nil, modelVersion: String = "original",
                processingWidth: Int = 320, processingHeight: Int = 192,
                strength: Float = 0, colourStrength: Float = 1, maximumLuminanceRatio: Float = 2,
                referenceWhiteNits: Float = 203) {
        self.modelURL = modelURL; self.modelVersion = modelVersion
        self.processingWidth = processingWidth; self.processingHeight = processingHeight
        self.strength = strength; self.colourStrength = colourStrength; self.maximumLuminanceRatio = maximumLuminanceRatio
        self.referenceWhiteNits = referenceWhiteNits
    }
}

/// Real shared path: decoder planes -> retained linear BT.2020 original -> sRGB
/// proxy -> persistent NR -> HDR reconstruction -> completed RGBA16F nit output.
/// Presentation/display mapping is intentionally downstream of this boundary.
public actor HDRPipelineProcessor: FrameProcessor {
    private let configuration: HDRPipelineConfiguration
    private var importer: MLXHDRImporter?
    private var processor: NativeHDRProcessor?
    private var modelReservation: HDRModelReservation?
    private var writer: MLXPixelBufferWriter?
    private var writerDimensions: (Int, Int)?
    private var queue: (any MTLCommandQueue)?
    public init(configuration: HDRPipelineConfiguration = .init()) {
        self.configuration = configuration
    }
    deinit {
        // Drop the actual model before returning process-wide admission credit.
        processor = nil
        modelReservation = nil
    }
    public func resetHistory() async { await processor?.reset() }

    public func process(_ frame: EngineInput) async throws -> ProcessedFrame {
        try HDRRuntimeResources.shared.prepareAllocator()
        let descriptor = frame.descriptor
        if let event = frame.readyEvent {
            if queue == nil { queue = MTLCreateSystemDefaultDevice()?.makeCommandQueue() }
            guard let command = queue?.makeCommandBuffer() else { throw FrameEngineError.invalid("Metal unavailable") }
            command.label = "HDR input producer dependency"
            command.encodeWaitForEvent(event, value: descriptor.ready_value)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                command.addCompletedHandler { [frame] completed in
                    withExtendedLifetime(frame) {
                        if let error = completed.error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                command.commit()
            }
        }
        var metadata = try Self.metadata(descriptor)
        metadata.color.referenceWhiteNits = configuration.referenceWhiteNits
        let original: MLXHDRFrame
        if descriptor.pixel_format == kCVPixelFormatType_64RGBAHalf {
            guard descriptor.colour.transfer == FE_LINEAR.rawValue,
                  descriptor.colour.primaries == FE_BT2020.rawValue,
                  descriptor.colour.matrix == FE_RGB.rawValue,
                  descriptor.colour.range == FE_FULL_RANGE.rawValue else {
                throw FrameEngineError.invalid("Float input must be linear BT.2020 RGB in absolute nits")
            }
            original = MLXHDRFrame(original: try MLXVideoFrame(pixelBuffer: MLXPixelBuffer(frame.pixelBuffer)),
                                   metadata: metadata, sourcePixelBuffer: MLXPixelBuffer(frame.pixelBuffer))
        } else {
            if importer == nil { importer = try MLXHDRImporter() }
            original = try await importer!.importFrame(pixelBuffer: MLXPixelBuffer(frame.pixelBuffer), metadata: metadata)
        }
        if processor == nil {
            let reservation = try HDRRuntimeResources.shared.reserve(configuration: configuration)
            processor = try NativeHDRProcessor(configuration: .init(modelURL: configuration.strength > 0 ? configuration.modelURL : nil,
                processingWidth: configuration.processingWidth, processingHeight: configuration.processingHeight,
                strength: configuration.strength, colorStrength: configuration.colourStrength,
                maximumLuminanceRatio: configuration.maximumLuminanceRatio))
            modelReservation = reservation
        }
        let result = try await processor!.process(original)
        let dimensions = (result.enhanced.width, result.enhanced.height)
        if writerDimensions?.0 != dimensions.0 || writerDimensions?.1 != dimensions.1 {
            writer = try MLXPixelBufferWriter(width: dimensions.0, height: dimensions.1, halfOutput: true)
            writerDimensions = dimensions
        }
        let output = try await writer!.write(result.enhanced)
        var colour = descriptor.colour
        colour.reference_white_nits = Double(configuration.referenceWhiteNits)
        colour.primaries = FE_BT2020.rawValue; colour.transfer = FE_LINEAR.rawValue
        colour.matrix = FE_RGB.rawValue; colour.range = FE_FULL_RANGE.rawValue; colour.chroma_location = 0
        // Source mastering/CLL tags are preserved in source_colour; transformed
        // output must not falsely advertise unchanged mastering/content maxima.
        colour.mastering_xy = (0, 0, 0, 0, 0, 0, 0, 0)
        colour.mastering_min_nits = 0; colour.mastering_max_nits = 0; colour.max_cll = 0; colour.max_fall = 0
        CVBufferSetAttachment(output.buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(output.buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_Linear, .shouldPropagate)
        var gpuSeconds: [String: Double] = [:]
        if let seconds = original.importGPUSeconds { gpuSeconds["planar_import"] = seconds }
        if let seconds = output.gpuDurationSeconds { gpuSeconds["rgba16f_pack"] = seconds }
        let memory = MLXRuntimeDiagnostics.memorySnapshot()
        let resources = HDRRuntimeResources.shared.snapshot()
        return ProcessedFrame(buffer: output.buffer, colour: colour, gpuSeconds: gpuSeconds,
            completedStageWallSeconds: ["proxy": result.timings.proxySeconds, "motion": result.timings.motionSeconds,
                "inference": result.timings.inferenceSeconds, "reconstruction": result.timings.reconstructionSeconds],
            allocatorBytes: ["mlx_active": memory.activeBytes, "mlx_cache": memory.cacheBytes,
                             "mlx_peak_active": memory.peakActiveBytes,
                             "resident_model_payload": resources.residentModelPayloadBytes,
                             "runtime_mlx_cache_policy": resources.policy.mlxCacheBytes],
            contentKind: result.usedModel ? .enhanced : .original)
    }

    private static func metadata(_ frame: fe_frame) throws -> MLXHDRFrameMetadata {
        let colour = frame.colour
        let transfer: MLXHDRColorMetadata.Transfer
        switch colour.transfer {
        case FE_LINEAR.rawValue: transfer = .linear
        case FE_SRGB.rawValue: transfer = .sRGB
        case FE_BT709.rawValue: transfer = .bt1886
        case FE_PQ.rawValue: transfer = .pq
        case FE_HLG.rawValue: transfer = .hlg
        default: throw FrameEngineError.invalid("Unknown source transfer")
        }
        let primaries: MLXHDRColorMetadata.Primaries
        switch colour.primaries {
        case FE_BT2020.rawValue: primaries = .bt2020
        case FE_BT709_PRIMARIES.rawValue: primaries = .bt709
        case FE_DISPLAY_P3.rawValue: primaries = .displayP3
        default: throw FrameEngineError.invalid("Unknown source primaries")
        }
        let matrix: MLXHDRColorMetadata.Matrix
        switch colour.matrix {
        case FE_RGB.rawValue, FE_YUV709.rawValue: matrix = .bt709
        case FE_YUV2020.rawValue: matrix = .bt2020
        case FE_YUV601.rawValue: matrix = .bt601
        default: throw FrameEngineError.invalid("Unknown YUV matrix")
        }
        guard let chroma = MLXHDRColorMetadata.ChromaLocation(rawValue: colour.chroma_location),
              colour.range == FE_FULL_RANGE.rawValue || colour.range == FE_VIDEO_RANGE.rawValue,
              colour.reference_white_nits.isFinite, colour.reference_white_nits > 0,
              colour.hlg_peak_nits.isFinite, (400...2000).contains(colour.hlg_peak_nits) else {
            throw FrameEngineError.invalid("Invalid range, chroma siting or luminance units")
        }
        return MLXHDRFrameMetadata(time: CMTime(value: frame.pts.value, timescale: frame.pts.timescale),
            duration: CMTime(value: frame.duration.value, timescale: frame.duration.timescale),
            sourceID: String(frame.source_id), streamID: frame.stream_id, frameIndex: frame.frame_id,
            generation: frame.generation,
            crop: CGRect(x: frame.geometry.crop_x, y: frame.geometry.crop_y,
                         width: frame.geometry.crop_width, height: frame.geometry.crop_height),
            transform: CGAffineTransform(rotationAngle: frame.geometry.rotation_degrees * .pi / 180),
            pixelAspectRatio: Double(frame.geometry.pixel_aspect_num) / Double(frame.geometry.pixel_aspect_den),
            color: .init(transfer: transfer, primaries: primaries, matrix: matrix,
                fullRange: colour.range == FE_FULL_RANGE.rawValue, chromaLocation: chroma,
                referenceWhiteNits: Float(colour.reference_white_nits), hlgPeakNits: Float(colour.hlg_peak_nits)))
    }
}
