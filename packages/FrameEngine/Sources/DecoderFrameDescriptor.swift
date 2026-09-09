import CFrameEngine
import CoreVideo
import DLSSMLX
import Foundation

/// Converts the native decoder's metadata into the same descriptor used by the
/// C adapters. The caller retains the pixel buffer through submit's return.
public enum DecoderFrameDescriptor {
    public static func make(pixelBuffer: CVPixelBuffer, metadata: MLXHDRFrameMetadata,
                            sourceID: UInt64, generation: UInt64) -> fe_frame {
        var frame = fe_frame()
        frame.struct_size = UInt32(MemoryLayout<fe_frame>.size); frame.abi_version = UInt32(FE_ABI_VERSION)
        frame.source_id = sourceID; frame.stream_id = metadata.streamID
        frame.frame_id = metadata.frameIndex; frame.generation = generation
        frame.pts = fe_time(value: metadata.time.value, timescale: metadata.time.timescale)
        frame.duration = fe_time(value: metadata.duration.value, timescale: metadata.duration.timescale)
        frame.geometry.width = UInt32(CVPixelBufferGetWidth(pixelBuffer))
        frame.geometry.height = UInt32(CVPixelBufferGetHeight(pixelBuffer))
        frame.geometry.crop_x = metadata.crop.origin.x; frame.geometry.crop_y = metadata.crop.origin.y
        frame.geometry.crop_width = metadata.crop.width; frame.geometry.crop_height = metadata.crop.height
        frame.geometry.rotation_degrees = atan2(metadata.transform.b, metadata.transform.a) * 180 / .pi
        let aspect = metadata.pixelAspectRatio
        if aspect.isFinite, aspect > 0, aspect <= 1000 {
            frame.geometry.pixel_aspect_num = UInt32((aspect * 1_000_000).rounded())
            frame.geometry.pixel_aspect_den = 1_000_000
        }
        frame.pixel_buffer = Unmanaged.passUnretained(pixelBuffer).toOpaque()
        frame.pixel_format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        frame.plane_count = UInt32(CVPixelBufferGetPlaneCount(pixelBuffer))
        func plane(_ i: Int) -> fe_plane {
            guard i < frame.plane_count else { return fe_plane() }
            return fe_plane(width: UInt32(CVPixelBufferGetWidthOfPlane(pixelBuffer, i)),
                height: UInt32(CVPixelBufferGetHeightOfPlane(pixelBuffer, i)),
                bytes_per_row: UInt32(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, i)), offset: 0)
        }
        frame.planes = (plane(0), plane(1), plane(2))
        switch metadata.color.transfer {
        case .linear: frame.colour.transfer = FE_LINEAR.rawValue
        case .sRGB: frame.colour.transfer = FE_SRGB.rawValue
        case .bt1886: frame.colour.transfer = FE_BT709.rawValue
        case .pq: frame.colour.transfer = FE_PQ.rawValue
        case .hlg: frame.colour.transfer = FE_HLG.rawValue
        }
        switch metadata.color.primaries {
        case .bt2020: frame.colour.primaries = FE_BT2020.rawValue
        case .bt709: frame.colour.primaries = FE_BT709_PRIMARIES.rawValue
        case .displayP3: frame.colour.primaries = FE_DISPLAY_P3.rawValue
        }
        switch metadata.color.matrix {
        case .bt2020: frame.colour.matrix = FE_YUV2020.rawValue
        case .bt709: frame.colour.matrix = FE_YUV709.rawValue
        case .bt601: frame.colour.matrix = FE_YUV601.rawValue
        }
        frame.colour.range = metadata.color.fullRange ? FE_FULL_RANGE.rawValue : FE_VIDEO_RANGE.rawValue
        frame.colour.chroma_location = metadata.color.chromaLocation.rawValue
        frame.colour.reference_white_nits = Double(metadata.color.referenceWhiteNits)
        frame.colour.hlg_peak_nits = Double(metadata.color.hlgPeakNits)
        // ST 2086 and content-light payloads are big-endian integers, as specified
        // by CoreVideo's corresponding attachment keys.
        if let data = metadata.color.masteringDisplay, data.count == 24 {
            func word(_ i: Int) -> Double { Double(UInt16(data[i]) << 8 | UInt16(data[i + 1])) / 50_000 }
            func luminance(_ i: Int) -> Double {
                Double(UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])) / 10_000
            }
            frame.colour.mastering_xy = (word(0), word(2), word(4), word(6), word(8), word(10), word(12), word(14))
            frame.colour.mastering_max_nits = luminance(16); frame.colour.mastering_min_nits = luminance(20)
        }
        if let data = metadata.color.contentLightLevel, data.count == 4 {
            frame.colour.max_cll = Double(UInt16(data[0]) << 8 | UInt16(data[1]))
            frame.colour.max_fall = Double(UInt16(data[2]) << 8 | UInt16(data[3]))
        }
        frame.source_colour = frame.colour
        return frame
    }
}
