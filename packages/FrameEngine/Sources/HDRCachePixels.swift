import Accelerate
import CFrameEngine
import Foundation

/// CPU cache serialization and presentation conversion. Keeping the bulk work in
/// memcpy/vImage avoids per-component Swift collection overhead in debug players.
enum HDRCachePixels {
    static func valid(_ bytes: UnsafeRawBufferPointer) -> Bool {
        hdr_cache_validate_rgba32f_le(bytes.baseAddress, bytes.count)
    }

    static func decode(_ data: Data) throws -> [Float] {
        try data.withUnsafeBytes { bytes in
            guard valid(bytes) else { throw HDRCacheError.corruptSegment("Invalid float payload") }
            // Every supported macOS architecture is little-endian. Copy rather
            // than bind Data's potentially unaligned storage to Float.
            return Array<Float>(unsafeUninitializedCapacity: bytes.count / MemoryLayout<Float>.size) { output, count in
                UnsafeMutableRawBufferPointer(output).copyMemory(from: bytes)
                count = output.count
            }
        }
    }

    static func pack(_ rgba: [Float], width: Int, height: Int,
                     to address: UnsafeMutableRawPointer, rowBytes: Int) throws {
        let pixels = width.multipliedReportingOverflow(by: height)
        let components = pixels.partialValue.multipliedReportingOverflow(by: 4)
        let row = width.multipliedReportingOverflow(by: 16)
        let storage = rowBytes.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !pixels.overflow, !components.overflow, !row.overflow, !storage.overflow,
              rowBytes >= row.partialValue / 2, rgba.count == components.partialValue else {
            throw HDRCacheError.invalidFrame("Prepared payload geometry mismatch")
        }
        let result = rgba.withUnsafeBufferPointer { values in
            // vImage explicitly supports interleaved formats by multiplying the
            // plane width by the channel count. Destination stride is preserved.
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: values.baseAddress!),
                height: vImagePixelCount(height), width: vImagePixelCount(width * 4), rowBytes: row.partialValue)
            var destination = vImage_Buffer(data: address,
                height: vImagePixelCount(height), width: vImagePixelCount(width * 4), rowBytes: rowBytes)
            return vImageConvert_PlanarFtoPlanar16F(&source, &destination, vImage_Flags(kvImageDoNotTile))
        }
        guard result == kvImageNoError,
              hdr_cache_validate_rgba16f(address, width, height, rowBytes) else {
            throw HDRCacheError.invalidFrame("Prepared float cannot be represented in RGBA16F")
        }
    }
}
