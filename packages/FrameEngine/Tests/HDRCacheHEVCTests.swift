import Foundation
@testable import FrameEngine
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
