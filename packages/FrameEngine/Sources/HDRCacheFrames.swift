import Foundation

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
}
