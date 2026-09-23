import CryptoKit
import Darwin
import Foundation

public enum HDRCacheError: Error, Equatable {
    case invalidIdentity(String)
    case invalidFrame(String)
    case corruptSegment(String)
    case capacityExceeded
    case alreadyWriting
    case unavailable
    case cacheInUse
}

/// Canonical, exact media time. Equivalent fractions produce the same cache key.
public struct HDRCacheTime: Codable, Hashable, Comparable, Sendable {
    public let value: Int64
    public let timescale: Int32

    public init(value: Int64, timescale: Int32) throws {
        guard timescale > 0 else { throw HDRCacheError.invalidIdentity("Nonpositive timescale") }
        var a = value.magnitude
        var b = UInt64(timescale)
        while b != 0 { (a, b) = (b, a % b) }
        let divisor = Int64(a)
        self.value = value / divisor
        self.timescale = timescale / Int32(divisor)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(value: values.decode(Int64.self, forKey: .value),
                      timescale: values.decode(Int32.self, forKey: .timescale))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let a = lhs.value.multipliedFullWidth(by: Int64(rhs.timescale))
        let b = rhs.value.multipliedFullWidth(by: Int64(lhs.timescale))
        return a.high == b.high ? a.low < b.low : a.high < b.high
    }

    public func adding(_ other: Self) throws -> Self {
        var a = timescale
        var b = other.timescale
        while b != 0 { (a, b) = (b, a % b) }
        let leftFactor = Int64(other.timescale / a)
        let rightFactor = Int64(timescale / a)
        let scale = Int64(timescale) * leftFactor
        let left = value.multipliedReportingOverflow(by: leftFactor)
        let right = other.value.multipliedReportingOverflow(by: rightFactor)
        let sum = left.partialValue.addingReportingOverflow(right.partialValue)
        guard !left.overflow, !right.overflow, !sum.overflow, scale <= Int32.max else {
            throw HDRCacheError.invalidFrame("Timestamp arithmetic overflow")
        }
        return try Self(value: sum.partialValue, timescale: Int32(scale))
    }
}

public struct HDRCacheRange: Codable, Hashable, Sendable {
    public let start: HDRCacheTime
    public let end: HDRCacheTime

    public init(start: HDRCacheTime, end: HDRCacheTime) throws {
        guard start < end else { throw HDRCacheError.invalidIdentity("Empty or reversed range") }
        self.start = start
        self.end = end
    }
}

public struct HDRCacheSource: Codable, Hashable, Sendable {
    public var contentSHA256: String
    public var byteCount: Int64
    public var streamIndex: Int
    /// Decoder, orientation/crop and stream interpretation changes belong here.
    public var interpretation: [String: String]

    public init(contentSHA256: String, byteCount: Int64, streamIndex: Int,
                interpretation: [String: String] = [:]) {
        self.contentSHA256 = contentSHA256
        self.byteCount = byteCount
        self.streamIndex = streamIndex
        self.interpretation = interpretation
    }

    /// Hash the content, not just its URL or mtime. Streaming keeps RAM bounded.
    public static func fingerprint(url: URL, streamIndex: Int,
                                   interpretation: [String: String] = [:]) throws -> Self {
        let url = url.resolvingSymlinksInPath()
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var length: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
            length += Int64(data.count)
        }
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize,
              before.contentModificationDate == after.contentModificationDate,
              Int64(after.fileSize ?? -1) == length else {
            throw HDRCacheError.invalidIdentity("Source changed while being fingerprinted")
        }
        return Self(contentSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                    byteCount: length, streamIndex: streamIndex, interpretation: interpretation)
    }
}

public struct HDRCacheSettings: Codable, Hashable, Sendable {
    public var modelSHA256: String
    public var implementationVersion: String
    public var processingWidth: Int
    public var processingHeight: Int
    public var outputWidth: Int
    public var outputHeight: Int
    /// Include source interpretation, proxy, reconstruction, reference white and display mapping policy.
    public var colourPolicy: [String: String]
    /// Include guide generation policy, dimensions and content hashes of any external guides.
    public var guides: [String: String]
    public var effects: [String: Double]
    /// Execution/precision/quality options that can change pixels must be recorded here.
    public var execution: [String: String]

    public init(modelSHA256: String, implementationVersion: String,
                processingWidth: Int, processingHeight: Int, outputWidth: Int, outputHeight: Int,
                colourPolicy: [String: String], guides: [String: String] = [:],
                effects: [String: Double] = [:], execution: [String: String] = [:]) {
        self.modelSHA256 = modelSHA256
        self.implementationVersion = implementationVersion
        self.processingWidth = processingWidth
        self.processingHeight = processingHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.colourPolicy = colourPolicy
        self.guides = guides
        self.effects = effects
        self.execution = execution
    }
}

/// Every segment resets temporal history at this timestamp, then processes all input frames
/// from it in order. Preroll results before range.start are discarded, never cached as output.
public struct HDRCachePreroll: Codable, Hashable, Sendable {
    public var start: HDRCacheTime
    public var policyVersion: String
    public var randomSeed: UInt64

    public init(start: HDRCacheTime, policyVersion: String, randomSeed: UInt64 = 0) {
        self.start = start
        self.policyVersion = policyVersion
        self.randomSeed = randomSeed
    }
}

public struct HDRCacheIdentity: Codable, Hashable, Sendable {
    public var source: HDRCacheSource
    public var range: HDRCacheRange
    public var settings: HDRCacheSettings
    public var preroll: HDRCachePreroll
    /// Exact ordered PTS/duration inventory. Nil retains legacy contiguous timing.
    public var timingInventorySHA256: String?

    public init(source: HDRCacheSource, range: HDRCacheRange,
                settings: HDRCacheSettings, preroll: HDRCachePreroll, timingInventorySHA256: String? = nil) {
        self.source = source
        self.range = range
        self.settings = settings
        self.preroll = preroll
        self.timingInventorySHA256 = timingInventorySHA256
    }

    public func key() throws -> String {
        try validate()
        return cacheDigest(try cacheJSON(self))
    }

    fileprivate func validate() throws {
        func isHash(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard isHash(source.contentSHA256), isHash(settings.modelSHA256),
              timingInventorySHA256 == nil || isHash(timingInventorySHA256!), source.byteCount >= 0,
              source.streamIndex >= 0, !settings.implementationVersion.isEmpty,
              !settings.colourPolicy.isEmpty, !preroll.policyVersion.isEmpty,
              range.start < range.end, preroll.start <= range.start,
              settings.processingWidth > 0, settings.processingHeight > 0,
              settings.effects.values.allSatisfy(\.isFinite) else {
            throw HDRCacheError.invalidIdentity("Missing or invalid processing identity")
        }
        _ = try frameByteCount
    }

    fileprivate var frameByteCount: Int {
        get throws {
            let pixels = settings.outputWidth.multipliedReportingOverflow(by: settings.outputHeight)
            let bytes = pixels.partialValue.multipliedReportingOverflow(by: 16)
            guard settings.outputWidth > 0, settings.outputHeight > 0,
                  !pixels.overflow, !bytes.overflow else {
                throw HDRCacheError.invalidIdentity("Invalid output geometry")
            }
            return bytes.partialValue
        }
    }
}

public struct HDRCacheFrameTiming: Codable, Hashable, Sendable {
    public let presentationTime: HDRCacheTime
    public let duration: HDRCacheTime

    public init(presentationTime: HDRCacheTime, duration: HDRCacheTime) throws {
        guard duration.value > 0 else { throw HDRCacheError.invalidFrame("Nonpositive duration") }
        self.presentationTime = presentationTime
        self.duration = duration
    }

    public var end: HDRCacheTime { get throws { try presentationTime.adding(duration) } }

    /// The array length, order and canonical rational values all affect identity.
    public static func inventoryDigest(_ frames: [Self]) throws -> String {
        guard !frames.isEmpty else { throw HDRCacheError.invalidFrame("Empty timing inventory") }
        for (index, frame) in frames.enumerated() {
            guard frame.duration.value > 0,
                  index == 0 || frames[index - 1].presentationTime < frame.presentationTime else {
                throw HDRCacheError.invalidFrame("Timing inventory must contain strictly increasing PTS and positive durations")
            }
            _ = try frame.end
        }
        return cacheDigest(try cacheJSON(frames))
    }
}

/// Interleaved, little-endian Float32 RGBA. RGB is absolute cd/m² in linear BT.2020.
/// Negative RGB and values above SDR reference white are preserved. Alpha is straight, 0...1.
public struct HDRCacheFloatFrame: Sendable {
    public let timing: HDRCacheFrameTiming
    public let rgba: [Float]

    public init(timing: HDRCacheFrameTiming, rgba: [Float]) {
        self.timing = timing
        self.rgba = rgba
    }
}

/// One HEVC access unit as 4-byte big-endian length-prefixed NAL units. Frame 0 of a
/// segment begins with its VPS, SPS and PPS and holds an IRAP picture, so every segment
/// decodes on its own.
public struct HDRCacheHEVCSample: Sendable {
    public let timing: HDRCacheFrameTiming
    public let data: Data

    public init(timing: HDRCacheFrameTiming, data: Data) {
        self.timing = timing
        self.data = data
    }

    /// Byte ranges of each NAL unit, header included, or nil unless the length prefixes tile
    /// the buffer exactly and every unit holds at least its two-byte header.
    static func nalUnits(_ bytes: UnsafeRawBufferPointer) -> [Range<Int>]? {
        var units: [Range<Int>] = [], offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 4 else { return nil }
            let length = bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard length >= 2, length <= bytes.count - offset else { return nil }
            units.append(offset..<(offset + length))
            offset += length
        }
        return units
    }

    static func nalType(_ bytes: UnsafeRawBufferPointer, _ unit: Range<Int>) -> UInt8 { (bytes[unit.lowerBound] >> 1) & 0x3f }

    /// Every NAL header has forbidden_zero_bit 0 and at least one unit is VCL (types 0...31).
    /// The first sample starts with VPS, SPS and PPS (32, 33, 34) and holds an IRAP (16...21).
    static func validFraming(_ bytes: UnsafeRawBufferPointer, isFirst: Bool) -> Bool {
        guard let units = nalUnits(bytes), !units.isEmpty,
              units.allSatisfy({ bytes[$0.lowerBound] & 0x80 == 0 }) else { return false }
        let types = units.map { nalType(bytes, $0) }
        guard types.contains(where: { $0 < 32 }) else { return false }
        return !isFirst || (types.starts(with: [32, 33, 34]) && types.contains(where: { (16...21).contains($0) }))
    }
}

/// How a segment's frame files are encoded. It is a pure function of the identity's
/// `colourPolicy["storage"]`, so the format is part of the cache key.
enum HDRCacheStorage: Equatable, Sendable {
    /// `HDRSegmentCache.storagePolicy`, or no storage entry.
    case float32
    /// `HDRCacheHEVC.storagePolicy`.
    case hevc

    init(_ identity: HDRCacheIdentity) throws {
        switch identity.settings.colourPolicy["storage"] {
        case nil, HDRSegmentCache.storagePolicy?:
            self = .float32
        case HDRCacheHEVC.storagePolicy?:
            // 4:2:0 needs even geometry. Any hardware size limit is the encoder's to report,
            // so planning-only identities of any even size stay valid.
            guard identity.settings.outputWidth % 2 == 0, identity.settings.outputHeight % 2 == 0 else {
                throw HDRCacheError.invalidIdentity("HEVC storage requires even output width and height")
            }
            self = .hevc
        default:
            throw HDRCacheError.invalidIdentity("Unknown storage policy")
        }
    }

    var policy: String {
        switch self {
        case .float32: HDRSegmentCache.storagePolicy
        case .hevc: HDRCacheHEVC.storagePolicy
        }
    }

    func fileName(_ frameIndex: Int) -> String {
        switch self {
        case .float32: String(format: "%08d.rgba32f", frameIndex)
        case .hevc: String(format: "%08d.hevc", frameIndex)
        }
    }

    /// Float32: exactly one frame of valid floats. HEVC: at most that many bytes, exactly framed.
    func accepts(_ payload: UnsafeRawBufferPointer, frameIndex: Int, frameByteCount: Int) -> Bool {
        switch self {
        case .float32: payload.count == frameByteCount && HDRCachePixels.valid(payload)
        case .hevc: payload.count <= frameByteCount && HDRCacheHEVCSample.validFraming(payload, isFirst: frameIndex == 0)
        }
    }
}

public struct HDRCacheFrameRecord: Codable, Sendable {
    public let timing: HDRCacheFrameTiming
    public let fileName: String
    public let sha256: String
    public let byteCount: Int
}

public struct HDRCacheManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let storagePolicy: String
    public let key: String
    public let identity: HDRCacheIdentity
    public let frames: [HDRCacheFrameRecord]
}

public struct HDRCacheWrite: Hashable, Sendable { fileprivate let id: UUID }
public struct HDRCacheLease: Sendable {
    let id: UUID
    public let manifest: HDRCacheManifest
}

public struct HDRCacheCompletedSegment: Sendable {
    public let key: String
    public let range: HDRCacheRange
    public let preroll: HDRCachePreroll
    public let frameCount: Int
}

public struct HDRCacheUsage: Sendable {
    public let byteCount: Int64
    public let capacityBytes: Int64
    public let completedSegments: Int
    public let stagedSegments: Int
    public let activeReaders: Int
}

/// One process owns a cache directory at a time. All mutations serialize through this actor.
/// Staging and completed files share one logical byte budget; writes fail when pinned readers
/// prevent eviction. Release each lease when finished. Incomplete staging is discarded on restart.
public actor HDRSegmentCache {
    public static let storagePolicy = "rgba-f32le-linear-bt2020-absolute-nits-straight-alpha-v1"
    private let root: URL
    private let capacityBytes: Int64
    private let maximumManifestBytes = 16 * 1_048_576
    private let lockFD: Int32
    private let fm = FileManager.default
    private struct Entry {
        var manifest: HDRCacheManifest
        var lastAccess: Date
        /// Payloads plus manifest, as validated.
        let bytes: Int64
    }
    private struct Stage {
        let identity: HDRCacheIdentity
        let storage: HDRCacheStorage
        let expectedFrameCount: Int
        let directory: URL
        var frames: [HDRCacheFrameRecord]
        var manifestBytes: Int64 = 0
        var bytes: Int64 { frames.reduce(manifestBytes) { $0 + Int64($1.byteCount) } }
    }
    private var entries: [String: Entry] = [:]
    private var stages: [UUID: Stage] = [:]
    private var readers: [UUID: String] = [:]
    private var recovered = false

    public init(directory: URL, capacityBytes: Int64) throws {
        guard capacityBytes > 0 else { throw HDRCacheError.capacityExceeded }
        root = directory.standardizedFileURL
        self.capacityBytes = capacityBytes
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lockFD = Darwin.open(directory.appendingPathComponent("cache.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { throw HDRCacheError.unavailable }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD)
            throw HDRCacheError.cacheInUse
        }
    }

    deinit { flock(lockFD, LOCK_UN); Darwin.close(lockFD) }

    public static func open(directory: URL, capacityBytes: Int64) async throws -> HDRSegmentCache {
        let cache = try HDRSegmentCache(directory: directory, capacityBytes: capacityBytes)
        try await cache.recover()
        return cache
    }

    /// Rebuild the index from validated committed manifests; no separate index transaction
    /// can accidentally publish a partial segment after a crash.
    public func recover() throws {
        guard stages.isEmpty, readers.isEmpty else { throw HDRCacheError.cacheInUse }
        recovered = false
        entries.removeAll()
        try fm.createDirectory(at: completedDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: stagingDirectory.path) { try fm.removeItem(at: stagingDirectory) }
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        for directory in try fm.contentsOfDirectory(at: completedDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            do {
                let (manifest, bytes) = try validate(directory: directory)
                let date = try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
                entries[manifest.key] = Entry(manifest: manifest, lastAccess: date, bytes: bytes)
            } catch {
                try fm.removeItem(at: directory)
            }
        }
        try makeRoom(for: 0)
        recovered = true
    }

    public func begin(identity: HDRCacheIdentity, expectedFrameCount: Int) throws -> HDRCacheWrite {
        guard recovered else { throw HDRCacheError.unavailable }
        let key = try identity.key()
        let storage = try HDRCacheStorage(identity)
        guard expectedFrameCount > 0, expectedFrameCount <= maximumManifestBytes / 128 else {
            throw HDRCacheError.invalidFrame("Invalid frame count")
        }
        guard !stages.values.contains(where: { (try? $0.identity.key()) == key }) else {
            throw HDRCacheError.alreadyWriting
        }
        guard entries[key] == nil else { throw HDRCacheError.alreadyWriting }
        let token = HDRCacheWrite(id: UUID())
        let directory = stagingDirectory.appendingPathComponent(token.id.uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        stages[token.id] = Stage(identity: identity, storage: storage, expectedFrameCount: expectedFrameCount,
                                 directory: directory, frames: [])
        return token
    }

    public func append(_ frame: HDRCacheFloatFrame, to token: HDRCacheWrite) throws {
        let data = frame.rgba.withUnsafeBufferPointer { buffer in
            Data(buffer: UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
        }
        try append(data, timing: frame.timing, as: .float32, to: token)
    }

    /// Same timing, capacity, fsync and record rules as the Float32 append.
    public func append(_ sample: HDRCacheHEVCSample, to token: HDRCacheWrite) throws {
        try append(sample.data, timing: sample.timing, as: .hevc, to: token)
    }

    private func append(_ data: Data, timing: HDRCacheFrameTiming, as storage: HDRCacheStorage, to token: HDRCacheWrite) throws {
        guard var stage = stages[token.id] else { throw HDRCacheError.unavailable }
        guard stage.storage == storage else { throw HDRCacheError.invalidFrame("Frame format differs from the identity's storage") }
        guard stage.frames.count < stage.expectedFrameCount else { throw HDRCacheError.invalidFrame("Too many frames") }
        let timingValid: Bool
        if stage.identity.timingInventorySHA256 != nil {
            timingValid = timing.presentationTime < stage.identity.range.end &&
                (stage.frames.last.map { $0.timing.presentationTime < timing.presentationTime }
                    ?? (timing.presentationTime == stage.identity.range.start))
        } else {
            let expectedStart = try stage.frames.last?.timing.end ?? stage.identity.range.start
            timingValid = try timing.presentationTime == expectedStart && timing.end <= stage.identity.range.end
        }
        let frameByteCount = try stage.identity.frameByteCount, frameIndex = stage.frames.count
        guard timing.duration.value > 0, timingValid,
              data.withUnsafeBytes({ storage.accepts($0, frameIndex: frameIndex, frameByteCount: frameByteCount) }) else {
            throw HDRCacheError.invalidFrame("Pixels, alpha, or exact rational timing are invalid")
        }
        let fileName = storage.fileName(frameIndex)
        let record = HDRCacheFrameRecord(timing: timing, fileName: fileName,
                                        sha256: cacheDigest(data), byteCount: data.count)
        // No atomic-write temporary duplicate: this directory is already unpublished staging.
        try makeRoom(for: Int64(data.count))
        let destination = stage.directory.appendingPathComponent(fileName)
        do {
            try data.write(to: destination)
            try synchronize(destination)
            stage.frames.append(record)
            stages[token.id] = stage
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }

    @discardableResult
    public func publish(_ token: HDRCacheWrite) throws -> HDRCacheManifest {
        guard var stage = stages[token.id] else { throw HDRCacheError.unavailable }
        guard stage.frames.count == stage.expectedFrameCount else {
            throw HDRCacheError.invalidFrame("Segment is incomplete")
        }
        try validateTiming(stage.frames.map(\.timing), identity: stage.identity)
        let manifest = HDRCacheManifest(schemaVersion: stage.identity.timingInventorySHA256 == nil ? 1 : 2, storagePolicy: stage.storage.policy,
                                        key: try stage.identity.key(), identity: stage.identity, frames: stage.frames)
        let metadata = try cacheJSON(manifest)
        guard metadata.count <= maximumManifestBytes else { throw HDRCacheError.capacityExceeded }
        let manifestURL = stage.directory.appendingPathComponent("manifest.json")
        // A previous failed publication may already have a manifest; account only for its replacement.
        try makeRoom(for: max(0, Int64(metadata.count) - stage.manifestBytes))
        stage.manifestBytes = Int64(metadata.count)
        stages[token.id] = stage
        try metadata.write(to: manifestURL)
        try synchronize(manifestURL)
        _ = try validate(directory: stage.directory, expectedKey: manifest.key)
        try synchronizeDirectory(stage.directory)
        let destination = completedDirectory.appendingPathComponent(manifest.key, isDirectory: true)
        try fm.moveItem(at: stage.directory, to: destination)
        try synchronizeDirectory(completedDirectory)
        entries[manifest.key] = Entry(manifest: manifest, lastAccess: Date(), bytes: stage.bytes)
        stages.removeValue(forKey: token.id)
        return manifest
    }

    public func cancel(_ token: HDRCacheWrite) throws {
        guard let stage = stages[token.id] else { return }
        try fm.removeItem(at: stage.directory)
        stages.removeValue(forKey: token.id)
    }

    /// Validates every payload before exposing the segment, then pins it against eviction.
    public func acquire(identity: HDRCacheIdentity) throws -> HDRCacheLease? {
        guard recovered else { throw HDRCacheError.unavailable }
        let key = try identity.key()
        guard var entry = entries[key] else { return nil }
        do { _ = try validate(directory: completedDirectory.appendingPathComponent(key)) }
        catch {
            // An existing reader still owns its lease; reads will report corruption, never stale pixels.
            entries.removeValue(forKey: key)
            if !readers.values.contains(key) { try? fm.removeItem(at: completedDirectory.appendingPathComponent(key)) }
            throw error
        }
        entry.lastAccess = Date()
        entries[key] = entry
        try fm.setAttributes([.modificationDate: entry.lastAccess], ofItemAtPath: completedDirectory.appendingPathComponent(key).path)
        let id = UUID()
        readers[id] = key
        return HDRCacheLease(id: id, manifest: entry.manifest)
    }

    /// One checksum-verified frame of a Float32 lease; throws `.unavailable` for an HEVC lease.
    public func read(_ lease: HDRCacheLease, frameIndex: Int) throws -> HDRCacheFloatFrame {
        let (record, data) = try readPayload(lease, frameIndex: frameIndex, as: .float32)
        return HDRCacheFloatFrame(timing: record.timing, rgba: try HDRCachePixels.decode(data))
    }

    /// One checksum-verified sample of an HEVC lease; throws `.unavailable` for a Float32 lease.
    public func readSample(_ lease: HDRCacheLease, frameIndex: Int) throws -> HDRCacheHEVCSample {
        let (record, data) = try readPayload(lease, frameIndex: frameIndex, as: .hevc)
        return HDRCacheHEVCSample(timing: record.timing, data: data)
    }

    private func readPayload(_ lease: HDRCacheLease, frameIndex: Int,
                             as storage: HDRCacheStorage) throws -> (HDRCacheFrameRecord, Data) {
        guard readers[lease.id] == lease.manifest.key, lease.manifest.frames.indices.contains(frameIndex),
              try HDRCacheStorage(lease.manifest.identity) == storage else {
            throw HDRCacheError.unavailable
        }
        let record = lease.manifest.frames[frameIndex]
        return (record, try readVerified(record, from: completedDirectory.appendingPathComponent(lease.manifest.key)))
    }

    public func release(_ lease: HDRCacheLease) {
        guard let key = readers.removeValue(forKey: lease.id) else { return }
        if entries[key] == nil, !readers.values.contains(key) {
            try? fm.removeItem(at: completedDirectory.appendingPathComponent(key))
        }
    }

    /// Resumption uses only fully validated segments. The requested preroll for each range must
    /// also match before reuse; completedRanges alone is progress information, not an identity lookup.
    public func completedRanges(source: HDRCacheSource, settings: HDRCacheSettings) throws -> [HDRCacheCompletedSegment] {
        guard recovered else { throw HDRCacheError.unavailable }
        var result: [HDRCacheCompletedSegment] = []
        for (key, entry) in entries where entry.manifest.identity.source == source && entry.manifest.identity.settings == settings {
            _ = try validate(directory: completedDirectory.appendingPathComponent(key))
            result.append(HDRCacheCompletedSegment(key: key, range: entry.manifest.identity.range,
                                                  preroll: entry.manifest.identity.preroll, frameCount: entry.manifest.frames.count))
        }
        return result.sorted { $0.range.start < $1.range.start }
    }

    /// Progress-only snapshot of committed entries, reflecting LRU eviction.
    /// This does not read payloads; acquire/read remain the validated playback
    /// boundary and must never be replaced by trusting this UI inventory.
    public func indexedCompletedRanges(source: HDRCacheSource, settings: HDRCacheSettings) -> [HDRCacheCompletedSegment] {
        entries.compactMap { key, entry in
            guard entry.manifest.identity.source == source, entry.manifest.identity.settings == settings else { return nil }
            return HDRCacheCompletedSegment(key: key, range: entry.manifest.identity.range,
                preroll: entry.manifest.identity.preroll, frameCount: entry.manifest.frames.count)
        }.sorted { $0.range.start < $1.range.start }
    }

    public func usage() throws -> HDRCacheUsage {
        HDRCacheUsage(byteCount: logicalBytes, capacityBytes: capacityBytes,
                      completedSegments: entries.count, stagedSegments: stages.count, activeReaders: readers.count)
    }

    private var completedDirectory: URL { root.appendingPathComponent("segments", isDirectory: true) }
    private var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }

    /// Derived from records this actor owns, so accounting costs no directory walk.
    private var logicalBytes: Int64 {
        entries.values.reduce(0) { $0 + $1.bytes } + stages.values.reduce(0) { $0 + $1.bytes }
    }

    private func makeRoom(for additionalBytes: Int64) throws {
        guard additionalBytes <= capacityBytes else { throw HDRCacheError.capacityExceeded }
        var bytes = logicalBytes
        let pinned = Set(readers.values)
        for (key, entry) in entries.sorted(by: { $0.value.lastAccess < $1.value.lastAccess }) where !pinned.contains(key) {
            if bytes <= capacityBytes - additionalBytes { break }
            try fm.removeItem(at: completedDirectory.appendingPathComponent(key))
            entries.removeValue(forKey: key)
            bytes -= entry.bytes
        }
        guard bytes <= capacityBytes - additionalBytes else { throw HDRCacheError.capacityExceeded }
    }

    /// Returns the manifest and the segment's logical bytes: payloads plus manifest.
    private func validate(directory: URL, expectedKey: String? = nil) throws -> (HDRCacheManifest, Int64) {
        let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else {
            throw HDRCacheError.corruptSegment("Invalid segment directory")
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard size.isSymbolicLink != true, let count = size.fileSize, count <= maximumManifestBytes else {
            throw HDRCacheError.corruptSegment("Oversized or linked manifest")
        }
        let manifest = try JSONDecoder().decode(HDRCacheManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.identity.validate()
        let storage = try HDRCacheStorage(manifest.identity)
        guard manifest.schemaVersion == (manifest.identity.timingInventorySHA256 == nil ? 1 : 2), manifest.storagePolicy == storage.policy,
              manifest.key == (try manifest.identity.key()), manifest.key == (expectedKey ?? directory.lastPathComponent),
              !manifest.frames.isEmpty else { throw HDRCacheError.corruptSegment("Invalid manifest identity") }
        try validateTiming(manifest.frames.map(\.timing), identity: manifest.identity)
        let frameBytes = try manifest.identity.frameByteCount
        for (index, frame) in manifest.frames.enumerated() {
            guard frame.fileName == storage.fileName(index), frame.byteCount <= frameBytes else {
                throw HDRCacheError.corruptSegment("Invalid frame inventory or timing")
            }
            let payload = try readVerified(frame, from: directory)
            guard payload.withUnsafeBytes({ storage.accepts($0, frameIndex: index, frameByteCount: frameBytes) }) else {
                throw HDRCacheError.corruptSegment("Invalid frame payload")
            }
        }
        let names = Set(try fm.contentsOfDirectory(atPath: directory.path))
        guard names == Set(manifest.frames.map(\.fileName) + ["manifest.json"]) else {
            throw HDRCacheError.corruptSegment("Unexpected payload files")
        }
        return (manifest, manifest.frames.reduce(Int64(count)) { $0 + Int64($1.byteCount) })
    }

    private func readVerified(_ record: HDRCacheFrameRecord, from directory: URL) throws -> Data {
        let url = directory.appendingPathComponent(record.fileName)
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              attributes.fileSize == record.byteCount, record.byteCount > 0,
              Int64(record.byteCount) <= capacityBytes else { throw HDRCacheError.corruptSegment("Payload size mismatch") }
        let data = try Data(contentsOf: url)
        guard cacheDigest(data) == record.sha256 else { throw HDRCacheError.corruptSegment("Payload checksum mismatch") }
        return data
    }
}

private func validateTiming(_ timings: [HDRCacheFrameTiming], identity: HDRCacheIdentity) throws {
    guard timings.first?.presentationTime == identity.range.start else {
        throw HDRCacheError.corruptSegment("Missing first frame")
    }
    if let expected = identity.timingInventorySHA256 {
        guard try HDRCacheFrameTiming.inventoryDigest(timings) == expected,
              timings.allSatisfy({ $0.presentationTime < identity.range.end }) else {
            throw HDRCacheError.corruptSegment("Exact timing inventory is incomplete or changed")
        }
    } else {
        var next = identity.range.start
        for timing in timings {
            guard timing.duration.value > 0, timing.presentationTime == next else {
                throw HDRCacheError.corruptSegment("Noncontiguous legacy timing")
            }
            next = try timing.end
        }
        guard next == identity.range.end else { throw HDRCacheError.corruptSegment("Incomplete range") }
    }
}

private func cacheJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func cacheDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func synchronize(_ url: URL) throws {
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.synchronize()
}

private func synchronizeDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw HDRCacheError.unavailable }
    defer { Darwin.close(descriptor) }
    guard fsync(descriptor) == 0 else { throw HDRCacheError.unavailable }
}
