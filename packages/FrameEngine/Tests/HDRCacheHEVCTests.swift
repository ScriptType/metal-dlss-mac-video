import CoreVideo
import DLSSMLX
import Foundation
@testable import FrameEngine
import Metal
import Testing

/// ST 2084 EOTF written from the standard, independent of how the encoder table is built.
private func pqNits(_ signal: Double) -> Double {
    let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
    let p = pow(signal, 1 / m2)
    return 10_000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
}

private func nal(_ type: UInt8, _ payload: [UInt8] = [0x01, 0xaf]) -> [UInt8] {
    let unit = [type << 1, 0x01] + payload
    return withUnsafeBytes(of: UInt32(unit.count).bigEndian, Array.init) + unit
}

private func framed(_ bytes: [UInt8], isFirst: Bool) -> Bool {
    bytes.withUnsafeBytes { HDRCacheHEVCSample.validFraming($0, isFirst: isFirst) }
}

private let firstSample = nal(32) + nal(33) + nal(34) + nal(39) + nal(19)
private let laterSample = nal(1)

@Test func hevcPQTableIsExactAndEncodesTheClipPolicy() {
    let table = HDRCacheHEVC.pqTable
    func signal(_ nits: Float16) -> Float { table[Int(nits.bitPattern)] }
    #expect(table.count == 65_536)
    // Reference points from BT.2100 / BT.2408: 100 nits 0.5081, 203 nits 0.5806, 1,000 nits 0.7518.
    #expect(abs(signal(100) - 0.5081) < 1e-4)
    #expect(abs(signal(203) - 0.5806) < 1e-4)
    #expect(abs(signal(1_000) - 0.7518) < 1e-4)
    #expect(signal(10_000) == 1)
    var worstRelativeError = 0.0, previous: Float = -1
    for bits in UInt16(0)...0x7bff {
        let nits = Float16(bitPattern: bits)
        #expect(table[Int(bits)] >= previous)
        previous = table[Int(bits)]
        guard nits <= 10_000 else { continue }
        let decoded = pqNits(Double(table[Int(bits)]))
        worstRelativeError = max(worstRelativeError, abs(decoded - Double(nits)) / max(Double(nits), 1e-3))
    }
    #expect(worstRelativeError < 1e-4)
    for negative: Float16 in [-0.0, -0.25, -65_504] { #expect(signal(negative) == signal(0)) }
    for above: Float16 in [10_008, 65_504] { #expect(signal(above) == 1) }
    for invalid: Float16 in [.nan, .signalingNaN, .infinity, -.infinity] { #expect(signal(invalid) == -1) }
}

@Test func hevcSampleFramingRejectsTruncatedMisframedAndParameterlessSamples() {
    #expect(framed(firstSample, isFirst: true))
    #expect(framed(firstSample, isFirst: false))
    #expect(framed(laterSample, isFirst: false))
    #expect(!framed(laterSample, isFirst: true), "first sample without parameter sets")
    #expect(!framed(nal(32) + nal(33) + nal(34) + nal(1), isFirst: true), "first sample without an IRAP picture")
    #expect(!framed(nal(33) + nal(32) + nal(34) + nal(19), isFirst: true), "parameter sets out of order")
    #expect(!framed(Array(firstSample.dropLast()), isFirst: true), "truncated unit")
    #expect(!framed(firstSample + [0, 0], isFirst: true), "trailing bytes")
    #expect(!framed([0, 0, 0, 0] + laterSample, isFirst: false), "zero-length unit")
    #expect(!framed([0, 0, 0, 1, 0x02] + laterSample, isFirst: false), "unit shorter than its header")
    #expect(!framed(nal(39), isFirst: false), "no VCL unit")
    var forbidden = laterSample; forbidden[4] |= 0x80
    #expect(!framed(forbidden, isFirst: false), "forbidden_zero_bit set")
    #expect(!framed([], isFirst: false))
}

private func isolationIdentity(storage: String) throws -> HDRCacheIdentity {
    HDRCacheIdentity(source: .init(contentSHA256: String(repeating: "a", count: 64), byteCount: 100, streamIndex: 0),
        range: try .init(start: .init(value: 0, timescale: 24), end: .init(value: 2, timescale: 24)),
        settings: .init(modelSHA256: String(repeating: "b", count: 64), implementationVersion: "hevc-isolation-test-v1",
            processingWidth: 8, processingHeight: 8, outputWidth: 8, outputHeight: 8, colourPolicy: ["storage": storage]),
        preroll: .init(start: try .init(value: 0, timescale: 24), policyVersion: "reset-v1"))
}

private func isolationTiming(_ index: Int) throws -> HDRCacheFrameTiming {
    try .init(presentationTime: .init(value: Int64(index), timescale: 24), duration: .init(value: 1, timescale: 24))
}

private let isolationPixels: [Float] = (0..<64).flatMap { pixel -> [Float] in [pixel % 2 == 0 ? -0.25 : 1_000, 203, 0.0001, 1] }

@Test func float32EntriesAreIgnoredByHEVCIdentitiesAndNeverDecodedAsHEVC() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-hevc-isolation-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try await HDRSegmentCache.open(directory: directory, capacityBytes: 1_048_576)
    let float32 = try isolationIdentity(storage: HDRSegmentCache.storagePolicy)
    let hevc = try isolationIdentity(storage: HDRCacheHEVC.storagePolicy)
    let writer = try await cache.begin(identity: float32, expectedFrameCount: 2)
    for index in 0..<2 {
        try await cache.append(HDRCacheFloatFrame(timing: isolationTiming(index), rgba: isolationPixels), to: writer)
    }
    let float32Manifest = try await cache.publish(writer)

    #expect(try hevc.key() != float32.key())
    #expect(try await cache.acquire(identity: hevc) == nil)
    #expect(await cache.indexedCompletedRanges(source: hevc.source, settings: hevc.settings).isEmpty)
    let lease = try #require(try await cache.acquire(identity: float32))
    #expect(try await cache.read(lease, frameIndex: 0).rgba.map(\.bitPattern) == isolationPixels.map(\.bitPattern))
    await #expect(throws: HDRCacheError.unavailable) { try await cache.readSample(lease, frameIndex: 0) }
    await cache.release(lease)

    var unknown = float32; unknown.settings.colourPolicy["storage"] = "rgba-f16-v1"
    await #expect(throws: HDRCacheError.invalidIdentity("Unknown storage policy")) {
        try await cache.begin(identity: unknown, expectedFrameCount: 2)
    }
    var odd = hevc; odd.settings.outputWidth = 7
    await #expect(throws: HDRCacheError.self) { try await cache.begin(identity: odd, expectedFrameCount: 2) }

    // A well-framed HEVC entry is the control: it passes the same validation the forgery fails.
    var control = hevc; control.settings.guides["variant"] = "framed-control"
    let hevcWriter = try await cache.begin(identity: control, expectedFrameCount: 2)
    await #expect(throws: HDRCacheError.self) {
        try await cache.append(HDRCacheFloatFrame(timing: isolationTiming(0), rgba: isolationPixels), to: hevcWriter)
    }
    await #expect(throws: HDRCacheError.self) {
        try await cache.append(HDRCacheHEVCSample(timing: isolationTiming(0), data: isolationPixels.withUnsafeBytes { Data($0) }), to: hevcWriter)
    }
    try await cache.append(HDRCacheHEVCSample(timing: isolationTiming(0), data: Data(firstSample)), to: hevcWriter)
    try await cache.append(HDRCacheHEVCSample(timing: isolationTiming(1), data: Data(laterSample)), to: hevcWriter)
    let controlManifest = try await cache.publish(hevcWriter)
    #expect(controlManifest.storagePolicy == HDRCacheHEVC.storagePolicy)
    #expect(controlManifest.frames.map(\.fileName) == ["00000000.hevc", "00000001.hevc"])

    // Forge an HEVC entry from the Float32 payloads: HEVC names, key, policy and manifest, with
    // matching checksums and sizes, so only the NAL framing of the actual bytes can reject it.
    let forgedKey = try hevc.key()
    let forged = directory.appendingPathComponent("segments/\(forgedKey)")
    try FileManager.default.createDirectory(at: forged, withIntermediateDirectories: true)
    let records = try float32Manifest.frames.enumerated().map { index, record in
        let name = String(format: "%08d.hevc", index)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("segments/\(float32Manifest.key)/\(record.fileName)"),
                                         to: forged.appendingPathComponent(name))
        return HDRCacheFrameRecord(timing: record.timing, fileName: name, sha256: record.sha256, byteCount: record.byteCount)
    }
    try JSONEncoder().encode(HDRCacheManifest(schemaVersion: 1, storagePolicy: HDRCacheHEVC.storagePolicy,
                                              key: forgedKey, identity: hevc, frames: records))
        .write(to: forged.appendingPathComponent("manifest.json"))
    try await cache.recover()
    #expect(!FileManager.default.fileExists(atPath: forged.path))
    #expect(try await cache.acquire(identity: hevc) == nil)

    let controlLease = try #require(try await cache.acquire(identity: control))
    #expect(try await cache.readSample(controlLease, frameIndex: 0).data == Data(firstSample))
    await #expect(throws: HDRCacheError.unavailable) { try await cache.read(controlLease, frameIndex: 0) }
    await cache.release(controlLease)
    let survivor = try #require(try await cache.acquire(identity: float32))
    #expect(try await cache.read(survivor, frameIndex: 1).rgba == isolationPixels)
    await cache.release(survivor)
}

/// ST 2084 inverse EOTF of absolute nits clipped to 0...10,000, in Double.
private func pqSignal(_ nits: Double) -> Double {
    let y = pow(min(max(nits, 0), 10_000) / 10_000, 0.1593017578125)
    return pow((0.8359375 + 18.8515625 * y) / (1 + 18.6875 * y), 78.84375)
}

private func halfBuffer(width: Int, height: Int, _ pixel: (Int, Int) -> SIMD4<Float>) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_64RGBAHalf,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &created)
    let buffer = try #require(status == kCVReturnSuccess ? created : nil)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try #require(CVPixelBufferGetBaseAddress(buffer)), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<height {
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
        for x in 0..<width {
            let value = pixel(x, y)
            for channel in 0..<4 { row[x * 4 + channel] = Float16(value[channel]) }
        }
    }
    return buffer
}

private func halfPixels(_ buffer: CVPixelBuffer) -> [Float16] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!, rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    return (0..<height).flatMap { y in
        Array(UnsafeBufferPointer(start: base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self), count: width * 4))
    }
}

private let gpuEncoderAvailable = MTLCreateSystemDefaultDevice() != nil && HEVCEncoder.isAvailable

@Test(.enabled(if: gpuEncoderAvailable, "Requires Metal and a hardware HEVC Main10 encoder"))
func hevcExporterWritesNearestCodesAndTopLeftChroma() async throws {
    let pixels: [[SIMD4<Float>]] = [
        [[100, 1_000, 10, 1], [0.5, 203, 4_000, 1], [-5, 20_000, 50, 1], [10_000, 0, 1, 1]],
        [[1, 2, 3, 1], [600, 300, 150, 1], [-0.0, 0.01, 9_000, 1], [42, 42, 42, 1]],
    ]
    let source = try halfBuffer(width: 4, height: 2) { x, y in pixels[y][x] }
    var created: CVPixelBuffer?
    #expect(CVPixelBufferCreate(kCFAllocatorDefault, 4, 2, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &created) == kCVReturnSuccess)
    let destination = try #require(created)
    let exporter = try PQExporter.shared.get()
    try await exporter.export(source, into: destination)

    func signals(_ pixel: SIMD4<Float>) -> (y: Double, r: Double, b: Double) {
        let r = pqSignal(Double(Float16(pixel.x))), g = pqSignal(Double(Float16(pixel.y))), b = pqSignal(Double(Float16(pixel.z)))
        return (0.2627 * r + 0.6780 * g + 0.0593 * b, r, b)
    }
    CVPixelBufferLockBaseAddress(destination, .readOnly)
    let luma = CVPixelBufferGetBaseAddressOfPlane(destination, 0)!, lumaRow = CVPixelBufferGetBytesPerRowOfPlane(destination, 0)
    let chroma = CVPixelBufferGetBaseAddressOfPlane(destination, 1)!
    for y in 0..<2 {
        for x in 0..<4 {
            let stored = luma.load(fromByteOffset: y * lumaRow + x * 2, as: UInt16.self)
            #expect(stored & 0x3f == 0)
            #expect(abs(Double(stored >> 6) - (64 + 876 * signals(pixels[y][x]).y)) <= 0.51, "luma at \(x),\(y)")
        }
    }
    for block in 0..<2 {
        let topLeft = signals(pixels[0][block * 2])
        let cb = chroma.load(fromByteOffset: block * 4, as: UInt16.self), cr = chroma.load(fromByteOffset: block * 4 + 2, as: UInt16.self)
        #expect(abs(Double(cb >> 6) - (512 + 896 * (topLeft.b - topLeft.y) / 1.8814)) <= 0.51, "Cb of block \(block)")
        #expect(abs(Double(cr >> 6) - (512 + 896 * (topLeft.r - topLeft.y) / 1.4746)) <= 0.51, "Cr of block \(block)")
    }
    CVPixelBufferUnlockBaseAddress(destination, .readOnly)

    for invalid: SIMD4<Float> in [[1, 1, 1, 0.5], [.nan, 1, 1, 1], [1, .infinity, 1, 1]] {
        let rejected = try halfBuffer(width: 4, height: 2) { x, y in x == 3 && y == 1 ? invalid : pixels[y][x] }
        await #expect(throws: HDRCacheError.self) { try await exporter.export(rejected, into: destination) }
    }
}

@Test(.enabled(if: gpuEncoderAvailable, "Requires Metal and a hardware HEVC Main10 encoder"))
func hevcSegmentRoundTripsVFRTimingAndEntersMidSegment() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-hevc-roundtrip-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try await HDRSegmentCache.open(directory: directory, capacityBytes: 64 * 1_048_576)
    let starts: [Int64] = [0, 40, 73, 120, 150, 199, 240, 290, 333, 380, 420, 470]
    let timings = try starts.indices.map { index in
        try HDRCacheFrameTiming(presentationTime: .init(value: starts[index], timescale: 1_000),
            duration: .init(value: (index + 1 < starts.count ? starts[index + 1] : 520) - starts[index], timescale: 1_000))
    }
    let identity = HDRCacheIdentity(source: .init(contentSHA256: String(repeating: "a", count: 64), byteCount: 100, streamIndex: 0),
        range: try .init(start: timings[0].presentationTime, end: .init(value: 520, timescale: 1_000)),
        settings: .init(modelSHA256: String(repeating: "b", count: 64), implementationVersion: "hevc-roundtrip-test-v1",
            processingWidth: 32, processingHeight: 24, outputWidth: 320, outputHeight: 192,
            colourPolicy: ["storage": HDRCacheHEVC.storagePolicy]),
        preroll: .init(start: timings[0].presentationTime, policyVersion: "reset-v1"),
        timingInventorySHA256: try HDRCacheFrameTiming.inventoryDigest(timings))
    // A colour ramp that moves every frame and is linear in PQ signal, the domain the codec and
    // 4:2:0 chroma work in, so bilinear chroma reconstruction is exact away from the edges.
    func input(_ frame: Int) -> (Int, Int) -> SIMD4<Float> {
        { x, y in
            [Float(pqNits(0.1 + 0.6 * Double(x) / 320)), Float(pqNits(0.2 + 0.5 * Double(y) / 192 + 0.01 * Double(frame))),
             Float(pqNits(0.3 + 0.3 * Double(x + y) / 512 + 0.005 * Double(frame))), 1]
        }
    }
    let writer = try await HDRCacheSegmentWriter.begin(cache, identity: identity, frameCount: timings.count)
    for (index, timing) in timings.enumerated() {
        try await writer.append(MLXPixelBuffer(halfBuffer(width: 320, height: 192, input(index))), timing: timing)
    }
    let manifest = try await writer.publish()
    #expect(manifest.frames.map(\.timing) == timings)
    #expect(manifest.frames.map(\.fileName) == timings.indices.map { String(format: "%08d.hevc", $0) })

    let lease = try #require(try await cache.acquire(identity: identity))
    var irapFrames: [Int] = []
    for index in timings.indices {
        let sample = try await cache.readSample(lease, frameIndex: index)
        let types = sample.data.withUnsafeBytes { bytes in
            HDRCacheHEVCSample.nalUnits(bytes)!.map { HDRCacheHEVCSample.nalType(bytes, $0) }
        }
        if types.contains(where: { (16...21).contains($0) }) { irapFrames.append(index) }
        if index == 0 {
            #expect(Array(types.prefix(3)) == [32, 33, 34])
            // SPS profile_tier_level: general_profile_idc is the low five bits of the unit's fourth byte.
            let sps = sample.data.withUnsafeBytes { HDRCacheHEVCSample.nalUnits($0)![1] }
            #expect(sample.data[sps.lowerBound + 3] & 0x1f == 2, "Main 10 profile")
        }
    }
    #expect(irapFrames.first == 0, "IDR at segment start")

    let sequential = HDRCacheFrameReader()
    var decoded: [[Float16]] = []
    var worst: Float = 0
    for index in timings.indices {
        let output = try await sequential.frame(index, of: lease, in: cache)
        #expect(CVPixelBufferGetPixelFormatType(output.buffer) == kCVPixelFormatType_64RGBAHalf)
        let pixels = halfPixels(output.buffer)
        decoded.append(pixels)
        let expected = input(index)
        for y in stride(from: 0, to: 192, by: 3) {
            for x in 0..<320 {
                let reference = expected(x, y)
                for channel in 0..<3 {
                    let error = abs(Float(pixels[(y * 320 + x) * 4 + channel]) - Float(Float16(reference[channel])))
                    worst = max(worst, error / max(Float(Float16(reference[channel])), 10))
                }
                #expect(pixels[(y * 320 + x) * 4 + 3] == 1)
            }
        }
    }
    // Per channel, counting absolute error below 10 nits against 10 nits. Measured 6.28 % worst;
    // 4:2:0 and 10-bit PQ alone reach 3.6 %. A wrong matrix or swapped chroma channels
    // errs by tens of percent.
    #expect(worst <= 0.10, "worst relative channel error \(worst)")

    let cold = HDRCacheFrameReader()
    #expect(halfPixels(try await cold.frame(9, of: lease, in: cache).buffer) == decoded[9], "cold mid-segment entry")
    await cache.release(lease)
    let second = try #require(try await cache.acquire(identity: identity))
    #expect(halfPixels(try await sequential.frame(5, of: second, in: cache).buffer) == decoded[5], "new lease restarts at the IDR")
    #expect(halfPixels(try await sequential.frame(6, of: second, in: cache).buffer) == decoded[6])
    await cache.release(second)

    var shifted = identity; shifted.settings.guides["variant"] = "shifted-ramp"
    let shiftedWriter = try await HDRCacheSegmentWriter.begin(cache, identity: shifted, frameCount: timings.count)
    for (index, timing) in timings.enumerated() {
        try await shiftedWriter.append(MLXPixelBuffer(halfBuffer(width: 320, height: 192, input(index + 20))), timing: timing)
    }
    try await shiftedWriter.publish()
    let other = try #require(try await cache.acquire(identity: shifted))
    let otherFrame = halfPixels(try await HDRCacheFrameReader().frame(7, of: other, in: cache).buffer)
    #expect(otherFrame != decoded[7])
    #expect(halfPixels(try await sequential.frame(7, of: other, in: cache).buffer) == otherFrame,
            "another segment decodes from its own IDR, not from this reader's position")
    await cache.release(other)
}
