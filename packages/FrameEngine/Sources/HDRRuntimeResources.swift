import DLSSMLX
import Foundation

/// Process-wide admission limits supplement each session's frame budget.
/// Model bytes count the immutable Safetensors payload, not transient inference
/// allocations. MLX cache reclamation follows the allocator's next-allocation
/// policy; these values are not an operating-system resident-memory hard cap.
public struct HDRRuntimeResourcePolicy: Codable, Sendable, Equatable {
    public var maximumResidentModels: Int = 2
    public var maximumResidentModelBytes: UInt64 = 1024 * 1024 * 1024
    public var maximumProcessingPixels: UInt64 = 512 * 288
    public var mlxCacheBytes: UInt64 = 256 * 1024 * 1024
    public init() {}
}

public struct HDRRuntimeResourceSnapshot: Codable, Sendable {
    public let policy: HDRRuntimeResourcePolicy
    public let residentModels: Int
    public let residentModelPayloadBytes: UInt64
    public let peakResidentModels: Int
    public let peakResidentModelPayloadBytes: UInt64
}

/// A reservation stays with its processor, including asynchronous teardown.
/// Failed construction returns capacity through ARC; live contexts are never
/// evicted from underneath temporal processing or presentation.
final class HDRModelReservation: @unchecked Sendable {
    private let owner: HDRRuntimeResources
    private let bytes: UInt64
    init(owner: HDRRuntimeResources, bytes: UInt64) { self.owner = owner; self.bytes = bytes }
    deinit { owner.release(bytes: bytes) }
}

public final class HDRRuntimeResources: @unchecked Sendable {
    public static let shared = HDRRuntimeResources()
    private let lock = NSLock()
    private var policy = HDRRuntimeResourcePolicy()
    private var models = 0
    private var bytes: UInt64 = 0
    private var peakModels = 0
    private var peakBytes: UInt64 = 0
    private var cacheConfigured = false

    public init() {}

    /// Original-only processing still allocates MLX arrays for import and pack.
    /// Apply the default cache policy before those allocations, independently
    /// of whether the session will reserve a neural model.
    func prepareAllocator() throws {
        try lock.withLock {
            if !cacheConfigured {
                try MLXRuntimeDiagnostics.setCacheLimitBytes(policy.mlxCacheBytes)
                cacheConfigured = true
            }
        }
    }

    /// Configure before creating neural sessions. Reconfiguration while any
    /// neural processor retains a model is rejected without changing limits.
    public func configure(_ requested: HDRRuntimeResourcePolicy) throws {
        guard (1...16).contains(requested.maximumResidentModels), requested.maximumResidentModelBytes > 0,
              (1...UInt64(16384 * 16384)).contains(requested.maximumProcessingPixels),
              requested.mlxCacheBytes <= UInt64(Int.max) else {
            throw FrameEngineError.invalid("Invalid model residency, processing size or MLX cache policy")
        }
        try lock.withLock {
            guard models == 0 else { throw FrameEngineError.invalid("Drain and destroy neural sessions before changing runtime limits") }
            try MLXRuntimeDiagnostics.setCacheLimitBytes(requested.mlxCacheBytes)
            policy = requested; cacheConfigured = true
            peakModels = 0; peakBytes = 0
        }
    }

    func reserve(configuration: HDRPipelineConfiguration) throws -> HDRModelReservation? {
        guard configuration.strength > 0, let model = configuration.modelURL else { return nil }
        guard configuration.processingWidth > 0, configuration.processingHeight > 0 else {
            throw FrameEngineError.invalid("Invalid neural processing dimensions")
        }
        let pixels = UInt64(configuration.processingWidth).multipliedReportingOverflow(by: UInt64(configuration.processingHeight))
        guard !pixels.overflow else { throw FrameEngineError.invalid("Neural processing dimensions overflow") }
        let weights = model.hasDirectoryPath || (try? model.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            ? model.appendingPathComponent("weights.safetensors") : model
        let values = try weights.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw FrameEngineError.invalid("Neural model must have a nonempty regular weights file")
        }
        return try reserve(payloadBytes: UInt64(size), processingPixels: pixels.partialValue)
    }

    func reserve(payloadBytes: UInt64, processingPixels: UInt64) throws -> HDRModelReservation {
        try lock.withLock {
            guard processingPixels > 0, processingPixels <= policy.maximumProcessingPixels else {
                throw FrameEngineError.invalid("Neural processing size exceeds the configured runtime limit")
            }
            guard payloadBytes > 0, models < policy.maximumResidentModels,
                  payloadBytes <= policy.maximumResidentModelBytes,
                  bytes <= policy.maximumResidentModelBytes - payloadBytes else {
                throw FrameEngineError.invalid("Neural model residency is full; finish or cancel another processing session")
            }
            if !cacheConfigured {
                try MLXRuntimeDiagnostics.setCacheLimitBytes(policy.mlxCacheBytes)
                cacheConfigured = true
            }
            models += 1; bytes += payloadBytes
            peakModels = max(peakModels, models); peakBytes = max(peakBytes, bytes)
            return HDRModelReservation(owner: self, bytes: payloadBytes)
        }
    }

    fileprivate func release(bytes released: UInt64) {
        lock.withLock { models -= 1; bytes -= released }
    }

    public func snapshot() -> HDRRuntimeResourceSnapshot {
        lock.withLock {
            HDRRuntimeResourceSnapshot(policy: policy, residentModels: models, residentModelPayloadBytes: bytes,
                peakResidentModels: peakModels, peakResidentModelPayloadBytes: peakBytes)
        }
    }
}
