import Foundation
import Metal
import QuartzCore

public struct MeasurementConfiguration: Codable, Sendable {
    public var adapter: String
    public var source: String
    public var sourceWidth, sourceHeight, processingWidth, processingHeight, displayWidth, displayHeight: Int
    public var sourceFPS: Double
    public var modelVersion, implementationRevision, settingsJSON: String
    public var warmupFrames: Int
    public var displayConfiguration, powerConfiguration: String
    public init(adapter: String, source: String, sourceWidth: Int, sourceHeight: Int,
                processingWidth: Int, processingHeight: Int, displayWidth: Int, displayHeight: Int,
                sourceFPS: Double, modelVersion: String, implementationRevision: String,
                settingsJSON: String, warmupFrames: Int = 3,
                displayConfiguration: String = "unrecorded", powerConfiguration: String = "unrecorded") {
        self.adapter = adapter; self.source = source; self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        self.processingWidth = processingWidth; self.processingHeight = processingHeight
        self.displayWidth = displayWidth; self.displayHeight = displayHeight; self.sourceFPS = sourceFPS
        self.modelVersion = modelVersion; self.implementationRevision = implementationRevision; self.settingsJSON = settingsJSON
        self.warmupFrames = max(0, warmupFrames); self.displayConfiguration = displayConfiguration
        self.powerConfiguration = powerConfiguration
    }
}

public struct FrameMeasurement: Codable, Sendable {
    public let generation, frameID: UInt64
    public let ptsValue: Int64
    public let ptsTimescale: Int32
    public let submittedHostSeconds, workerStartHostSeconds, completedHostSeconds: Double
    public let gpuStagesSeconds: [String: Double]
    public var completedStageWallSeconds: [String: Double] = [:]
    public var processResidentBytes: UInt64 = 0
    public var allocatorBytes: [String: UInt64] = [:]
    public let occupiedSlots: Int
    public let retainedBytes: UInt64
    public let deadlineHostSeconds: Double?
    public var presentedHostSeconds: Double?
    public var avOffsetSeconds: Double?
    public var gpuCopies, cpuReadbacks, cpuWaits: Int?
    public var dropped = false
    public var presentations = 0
    public var warmup = false
}

public struct TimingDistribution: Codable, Sendable {
    public let count: Int
    public let minimum, p50, p95, p99, maximum: Double
    init?(_ values: [Double]) {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        count = sorted.count; minimum = sorted[0]; maximum = sorted[count - 1]
        func percentile(_ p: Double) -> Double {
            let index = Double(sorted.count - 1) * p
            let low = Int(index), high = min(low + 1, sorted.count - 1)
            return sorted[low] + (sorted[high] - sorted[low]) * (index - Double(low))
        }
        p50 = percentile(0.5); p95 = percentile(0.95); p99 = percentile(0.99)
    }
}

public struct FrameMeasurementReport: Codable, Sendable {
    public let schemaVersion: Int
    public let configuration: MeasurementConfiguration
    public let device, osVersion: String
    public let physicalMemoryBytes: UInt64
    public let targetHardware: Bool
    public let measurementScope: String
    public let completedTotal, retainedSamples, warmedSamples: Int
    public let completedThroughputFPS: Double?
    public let cpuSubmissionSeconds: TimingDistribution?
    public let queueSeconds, completedWorkSeconds, endToEndSeconds: TimingDistribution?
    public let completedCadenceSeconds, presentationOffsetSeconds, avOffsetSeconds: TimingDistribution?
    public let gpuStageSeconds: [String: TimingDistribution]
    public let completedStageWallSeconds: [String: TimingDistribution]
    public let peakSampledResidentBytes: UInt64?
    public let maximumAllocatorBytes: [String: UInt64]
    public let deadlineMisses, drops, duplicatePresentations: Int
    public let maximumQueueSlots: Int
    public let peakRetainedBytes: UInt64
    public let gpuCopies, cpuReadbacks, cpuWaits: Int?
    public let seekLatencySeconds: TimingDistribution?
    public let energyJoules, energyPerCompletedFrameJoules: Double?
    public let unavailableMetrics: [String]
    public let frames: [FrameMeasurement]
}

/// The same host-clock boundaries are used by every adapter. GPU stages must be
/// supplied after GPU completion; enqueue timings are recorded separately. The
/// tail is bounded and reports its sample count instead of implying a whole-run
/// percentile when the run exceeded capacity.
public final class FrameMeasurementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    public let configuration: MeasurementConfiguration
    private let maximumSamples: Int
    private var frames: [FrameMeasurement] = []
    private var nextFrameIndex = 0
    private var submissionSeconds: [Double] = []
    private var nextSubmissionIndex = 0
    private var seekSeconds: [Double] = []
    private var nextSeekIndex = 0
    private var completedTotal = 0
    private var warmupGeneration: UInt64?
    private var completedInGeneration = 0
    private var energy: Double?
    public init(configuration: MeasurementConfiguration, maximumSamples: Int = 36_000) {
        self.configuration = configuration; self.maximumSamples = max(2, maximumSamples)
    }
    public func recordSubmission(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        lock.withLock {
            if submissionSeconds.count == maximumSamples {
                submissionSeconds[nextSubmissionIndex] = seconds
                nextSubmissionIndex = (nextSubmissionIndex + 1) % maximumSamples
            } else { submissionSeconds.append(seconds) }
        }
    }
    public func recordCompletion(_ frame: FrameMeasurement) {
        lock.withLock {
            var sample = frame
            if warmupGeneration != frame.generation { warmupGeneration = frame.generation; completedInGeneration = 0 }
            sample.warmup = completedInGeneration < configuration.warmupFrames
            completedInGeneration += 1
            completedTotal += 1
            if frames.count == maximumSamples {
                frames[nextFrameIndex] = sample
                nextFrameIndex = (nextFrameIndex + 1) % maximumSamples
            } else { frames.append(sample) }
        }
    }
    /// Audio offset is video PTS minus the adapter's audio clock at presentation.
    /// An adapter must call this on actual presentation, including duplicate redraws.
    public func recordPresentation(generation: UInt64, frameID: UInt64, hostSeconds: Double,
                                   avOffsetSeconds: Double? = nil) {
        guard hostSeconds.isFinite, hostSeconds > 0 else { return }
        lock.withLock {
            guard let i = frames.lastIndex(where: { $0.generation == generation && $0.frameID == frameID }) else { return }
            if frames[i].presentedHostSeconds == nil { frames[i].presentedHostSeconds = hostSeconds }
            frames[i].presentations += 1
            frames[i].avOffsetSeconds = avOffsetSeconds
        }
    }
    public func recordDrop(generation: UInt64, frameID: UInt64) {
        lock.withLock {
            if let i = frames.lastIndex(where: { $0.generation == generation && $0.frameID == frameID }) { frames[i].dropped = true }
        }
    }
    public func recordTransfers(generation: UInt64, frameID: UInt64, gpuCopies: Int, cpuReadbacks: Int, cpuWaits: Int) {
        lock.withLock {
            if let i = frames.lastIndex(where: { $0.generation == generation && $0.frameID == frameID }) {
                frames[i].gpuCopies = gpuCopies; frames[i].cpuReadbacks = cpuReadbacks; frames[i].cpuWaits = cpuWaits
            }
        }
    }
    public func recordSeek(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        lock.withLock {
            if seekSeconds.count == maximumSamples {
                seekSeconds[nextSeekIndex] = seconds
                nextSeekIndex = (nextSeekIndex + 1) % maximumSamples
            } else { seekSeconds.append(seconds) }
        }
    }
    /// Supply measured energy over the retained warmed interval, excluding startup.
    public func recordEnergy(joules: Double) {
        if joules.isFinite && joules >= 0 { lock.withLock { energy = joules } }
    }
    public func report() -> FrameMeasurementReport {
        lock.withLock {
            let chronological = nextFrameIndex == 0 ? frames : Array(frames[nextFrameIndex...] + frames[..<nextFrameIndex])
            let warm = chronological.filter { !$0.warmup }
            let completed = warm.map(\.completedHostSeconds)
            let cadence = zip(completed, completed.dropFirst()).map { $1 - $0 }
            let gpuNames = Set(warm.flatMap { $0.gpuStagesSeconds.keys })
            let gpu = Dictionary(uniqueKeysWithValues: gpuNames.compactMap { name -> (String, TimingDistribution)? in
                TimingDistribution(warm.compactMap { $0.gpuStagesSeconds[name] }).map { (name, $0) }
            })
            let wallNames = Set(warm.flatMap { $0.completedStageWallSeconds.keys })
            let wall = Dictionary(uniqueKeysWithValues: wallNames.compactMap { name -> (String, TimingDistribution)? in
                TimingDistribution(warm.compactMap { $0.completedStageWallSeconds[name] }).map { (name, $0) }
            })
            let allocatorNames = Set(warm.flatMap { $0.allocatorBytes.keys })
            let allocator = Dictionary(uniqueKeysWithValues: allocatorNames.map { name in
                (name, warm.compactMap { $0.allocatorBytes[name] }.max() ?? 0)
            })
            func sum(_ key: KeyPath<FrameMeasurement, Int?>) -> Int? {
                guard !warm.isEmpty, warm.allSatisfy({ $0[keyPath: key] != nil }) else { return nil }
                return warm.reduce(0) { $0 + ($1[keyPath: key] ?? 0) }
            }
            var unavailable: [String] = []
            if gpu.isEmpty { unavailable.append("GPU stage completion intervals") }
            if warm.allSatisfy({ $0.presentedHostSeconds == nil }) { unavailable.append("presentation timing, drops and duplicates") }
            if warm.allSatisfy({ $0.avOffsetSeconds == nil }) { unavailable.append("audio/video offset") }
            if sum(\.gpuCopies) == nil { unavailable.append("GPU copy count") }
            if sum(\.cpuReadbacks) == nil { unavailable.append("CPU readback count") }
            if sum(\.cpuWaits) == nil { unavailable.append("CPU wait count") }
            if seekSeconds.isEmpty { unavailable.append("seek latency") }
            if energy == nil { unavailable.append("power and energy") }
            if warm.allSatisfy({ $0.processResidentBytes == 0 }) { unavailable.append("process resident memory") }
            if allocator.isEmpty { unavailable.append("MLX allocator memory") }
            if configuration.modelVersion != "original" { unavailable.append("isolated neural/proxy GPU intervals; completed wall stages are separate") }
            let device = MTLCreateSystemDefaultDevice()?.name ?? "unavailable"
            let interval = (completed.last ?? 0) - (completed.first ?? 0)
            return FrameMeasurementReport(schemaVersion: 1, configuration: configuration,
                device: device, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                targetHardware: device.contains("M5 Max"),
                measurementScope: frames.count < completedTotal ? "bounded tail of completed frames" : "all completed frames",
                completedTotal: completedTotal, retainedSamples: frames.count, warmedSamples: warm.count,
                completedThroughputFPS: completed.count > 1 && interval > 0 ? Double(completed.count - 1) / interval : nil,
                cpuSubmissionSeconds: TimingDistribution(submissionSeconds),
                queueSeconds: TimingDistribution(warm.map { $0.workerStartHostSeconds - $0.submittedHostSeconds }),
                completedWorkSeconds: TimingDistribution(warm.map { $0.completedHostSeconds - $0.workerStartHostSeconds }),
                endToEndSeconds: TimingDistribution(warm.map { $0.completedHostSeconds - $0.submittedHostSeconds }),
                completedCadenceSeconds: TimingDistribution(cadence),
                presentationOffsetSeconds: TimingDistribution(warm.compactMap { frame in
                    frame.presentedHostSeconds.flatMap { host in frame.deadlineHostSeconds.map { host - $0 } }
                }), avOffsetSeconds: TimingDistribution(warm.compactMap(\.avOffsetSeconds)), gpuStageSeconds: gpu,
                completedStageWallSeconds: wall, peakSampledResidentBytes: warm.map(\.processResidentBytes).filter { $0 > 0 }.max(),
                maximumAllocatorBytes: allocator,
                deadlineMisses: warm.filter { f in f.deadlineHostSeconds.map { (f.presentedHostSeconds ?? f.completedHostSeconds) > $0 } ?? false }.count,
                drops: warm.filter(\.dropped).count,
                duplicatePresentations: warm.reduce(0) { $0 + max(0, $1.presentations - 1) },
                maximumQueueSlots: warm.map(\.occupiedSlots).max() ?? 0,
                peakRetainedBytes: warm.map(\.retainedBytes).max() ?? 0,
                gpuCopies: sum(\.gpuCopies), cpuReadbacks: sum(\.cpuReadbacks), cpuWaits: sum(\.cpuWaits),
                seekLatencySeconds: TimingDistribution(seekSeconds), energyJoules: energy,
                energyPerCompletedFrameJoules: warm.isEmpty ? nil : energy.map { $0 / Double(warm.count) },
                unavailableMetrics: unavailable, frames: chronological)
        }
    }
    public func write(to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report()).write(to: url, options: .atomic)
    }
}
