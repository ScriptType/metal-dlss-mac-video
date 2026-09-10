import CFrameEngine
import Foundation
@testable import FrameEngine
import Testing

@Test func cachedFloatBulkCopyPreservesBitsAndAcceptsUnalignedBytes() throws {
    let values: [Float] = [-0.0, -Float.leastNonzeroMagnitude, .greatestFiniteMagnitude, -0.0,
                           -65_504, .leastNormalMagnitude, 10_000, 1]
    let data = values.withUnsafeBytes { Data($0) }
    #expect(try HDRCachePixels.decode(data).map(\.bitPattern) == values.map(\.bitPattern))
    var unaligned = Data([0xff]); unaligned.append(data)
    unaligned.withUnsafeBytes { raw in
        let bytes = UnsafeRawBufferPointer(rebasing: raw[1...])
        #expect(HDRCachePixels.valid(bytes))
    }
    #expect(throws: HDRCacheError.self) { try HDRCachePixels.decode(Data()) }
    #expect(throws: HDRCacheError.self) { try HDRCachePixels.decode(data.dropLast()) }
}

@Test func cachedFloatValidationRejectsEveryNonfiniteChannelAndInvalidAlpha() throws {
    let invalid: [Float] = [.infinity, -.infinity, .nan,
        Float(bitPattern: 0x7f800001), Float(bitPattern: 0xff800001)]
    for channel in 0..<4 {
        for value in invalid {
            var rgba: [Float] = [-1, 203, 10_000, 1]; rgba[channel] = value
            #expect(throws: HDRCacheError.self) {
                try HDRCachePixels.decode(rgba.withUnsafeBytes { Data($0) })
            }
        }
    }
    for alpha: Float in [-Float.leastNonzeroMagnitude, Float(1).nextUp, -1, 2] {
        let rgba: [Float] = [-1, 203, 10_000, alpha]
        #expect(throws: HDRCacheError.self) { try HDRCachePixels.decode(rgba.withUnsafeBytes { Data($0) }) }
    }
}

@Test func cachedHalfPackingMatchesScalarForEveryFiniteHalfAndRoundingBoundaries() throws {
    var rgb = (UInt32(0)...UInt32(UInt16.max)).compactMap { bits -> Float? in
        let value = Float16(bitPattern: UInt16(bits))
        return value.isFinite ? Float(value) : nil
    }
    // Midpoints and their nearest Float32 neighbours exercise ties, subnormal
    // underflow, normal transitions, negative rounding and the largest finite half.
    for bits: UInt16 in [0, 1, 2, 0x03fe, 0x03ff, 0x0400, 0x3555, 0x3bff, 0x3c00, 0x63ff, 0x7bfe] {
        let midpoint = (Float(Float16(bitPattern: bits)) + Float(Float16(bitPattern: bits + 1))) / 2
        for value in [midpoint.nextDown, midpoint, midpoint.nextUp] { rgb += [value, -value] }
    }
    rgb += [65_519, -65_519, Float.leastNonzeroMagnitude, -Float.leastNonzeroMagnitude]
    var rgba: [Float] = []
    for value in rgb { rgba += [value, -value, 203, 1] }
    let width = 17
    while rgba.count % (width * 4) != 0 { rgba += [0, -0.0, 1_000, 0.5] }
    let height = rgba.count / (width * 4), rowBytes = width * 8 + 32
    var packed = Data(repeating: 0xa5, count: height * rowBytes)
    try packed.withUnsafeMutableBytes {
        try HDRCachePixels.pack(rgba, width: width, height: height, to: $0.baseAddress!, rowBytes: rowBytes)
    }
    packed.withUnsafeBytes { raw in
        for y in 0..<height {
            let actual = (0..<(width * 4)).map { raw.loadUnaligned(fromByteOffset: y * rowBytes + $0 * 2, as: UInt16.self) }
            let expected = rgba[(y * width * 4)..<((y + 1) * width * 4)].map { Float16($0).bitPattern }
            #expect(actual == expected)
            #expect(raw[(y * rowBytes + width * 8)..<((y + 1) * rowBytes)].allSatisfy { $0 == 0xa5 })
        }
    }
}

@Test func cachedHalfPackingRejectsOverflowNonfiniteAndInvalidGeometry() throws {
    var packed = Data(count: 32)
    for value: Float in [65_520, -65_520, .greatestFiniteMagnitude, .infinity, -.infinity, .nan] {
        #expect(throws: HDRCacheError.self) {
            try packed.withUnsafeMutableBytes {
                try HDRCachePixels.pack([value, 0, 0, 1], width: 1, height: 1, to: $0.baseAddress!, rowBytes: 8)
            }
        }
    }
    for (width, height, stride) in [(0, 1, 8), (1, 0, 8), (2, 1, 8), (Int.max, 2, 8), (1, 1, 7)] {
        #expect(throws: HDRCacheError.self) {
            try packed.withUnsafeMutableBytes {
                try HDRCachePixels.pack([0, 0, 0, 1], width: width, height: height, to: $0.baseAddress!, rowBytes: stride)
            }
        }
    }
}
