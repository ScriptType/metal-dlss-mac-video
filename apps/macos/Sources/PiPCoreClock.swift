import CoreMedia
import Darwin
import Foundation

/// CoreMedia clock updates follow every native-worker snapshot, even while an
/// AppKit animation blocks the main-thread frame/UI mailbox. No audio is owned.
final class NativePiPCoreClock: @unchecked Sendable {
    let timebase: CMTimebase
    private let lock = NSLock()
    private var closed = false
    private var rate: Double?
    private var epoch: UInt64 = 0, generation: UInt64 = 0, hostTicks: UInt64 = 0
    private var updates = 0, holdUpdates = 0
    private var maxCorrection = 0.0, maxSteadyCorrection = 0.0, maxHostAge = 0.0
    private var corrections: [[String: Any]] = []
    private var lastReceiptTicks: UInt64 = 0
    private var receivedSnapshots = 0, distinctValidHostSamples = 0
    private var maxReceiptGap = 0.0, maxValidHostGap = 0.0
    private var snapshotGaps: [[String: Any]] = []
    init?() {
        var result: CMTimebase?
        guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &result) == noErr, let result else { return nil }
        timebase = result; CMTimebaseSetRate(result, rate: 0)
    }
    func update(_ snapshot: NativePiPSnapshot, receiptHostTicks: UInt64 = mach_absolute_time()) {
        let native = snapshot.state
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        // Receipt cadence and native clock sampling cadence are distinct from
        // the age of a newly received sample. A blocked worker can resume with
        // a fresh sample after a long interval with no updates at all.
        receivedSnapshots += 1
        let receiptGap = Self.secondsBetween(lastReceiptTicks, receiptHostTicks)
        if receiptHostTicks > lastReceiptTicks { lastReceiptTicks = receiptHostTicks }
        if let receiptGap { maxReceiptGap = max(maxReceiptGap, receiptGap) }
        let validHost = native.host_ticks > 0 && native.host_ticks >= hostTicks && native.clock_valid != 0 &&
            native.media_seconds.isFinite && native.rate.isFinite && native.rate >= 0
        let validHostGap = validHost ? Self.secondsBetween(hostTicks, native.host_ticks) : nil
        if validHost && native.host_ticks > hostTicks { distinctValidHostSamples += 1 }
        if let validHostGap { maxValidHostGap = max(maxValidHostGap, validHostGap) }
        // This threshold limits diagnostic detail; it is not a playback target
        // or a trigger for changing the timebase. Maxima include all intervals.
        if ((receiptGap ?? 0) > 0.050 || (validHostGap ?? 0) > 0.050), snapshotGaps.count < 100 {
            snapshotGaps.append([
                "receiptGapSeconds": receiptGap.map { $0 as Any } ?? NSNull(),
                "validHostGapSeconds": validHostGap.map { $0 as Any } ?? NSNull(),
                "receiptHostTicks": receiptHostTicks, "nativeHostTicks": native.host_ticks,
                "validHostSample": validHost, "supported": native.supported,
                "corePaused": native.core_paused, "userPaused": native.user_paused, "buffering": native.buffering,
                "rateBefore": rate.map { $0 as Any } ?? NSNull(),
                "reportedRate": native.rate.isFinite ? native.rate as Any : NSNull(),
                "revision": native.revision, "epoch": native.stream_epoch, "generation": native.generation,
            ])
        }
        // An older delivery cannot pause or re-anchor a newer clock sample.
        if native.host_ticks > 0 && native.host_ticks < hostTicks { return }
        guard native.host_ticks > 0, native.clock_valid != 0,
              native.media_seconds.isFinite, native.rate.isFinite, native.rate >= 0 else {
            CMTimebaseSetRate(timebase, rate: 0); rate = nil; return
        }
        let changed = native.stream_epoch != epoch || native.generation != generation
        epoch = native.stream_epoch; generation = native.generation; hostTicks = native.host_ticks
        let effectiveRate = native.supported != 0 ? native.rate : 0
        let host = CMClockMakeHostTimeFromSystemUnits(native.host_ticks)
        let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), host))
        let predicted = native.media_seconds + age * effectiveRate
        let old = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
        let correction = abs(old - predicted)
        if age.isFinite { maxHostAge = max(maxHostAge, age) }
        if !changed, let rate, correction.isFinite {
            maxCorrection = max(maxCorrection, correction)
            if rate == effectiveRate { maxSteadyCorrection = max(maxSteadyCorrection, correction) }
            if correction > 0.020 && corrections.count < 100 {
                corrections.append(["seconds": correction, "oldMediaSeconds": old, "nativeMediaSeconds": native.media_seconds,
                    "hostAgeSeconds": age, "rateBefore": rate, "rateAfter": effectiveRate,
                    "clockSource": native.clock_source, "userPaused": native.user_paused, "buffering": native.buffering,
                    "revision": native.revision, "epoch": epoch, "generation": generation,
                    "sourcePTS": ["value": native.source_pts.value, "timescale": native.source_pts.timescale]])
            }
        }
        if changed || rate != effectiveRate || correction > 0.002 {
            CMTimebaseSetRateAndAnchorTime(timebase, rate: effectiveRate,
                anchorTime: CMTime(seconds: native.media_seconds, preferredTimescale: 1_000_000_000), immediateSourceTime: host)
        }
        rate = effectiveRate; updates += 1
        if effectiveRate == 0 { holdUpdates += 1 }
    }
    private static func secondsBetween(_ earlier: UInt64, _ later: UInt64) -> Double? {
        guard earlier > 0, later >= earlier else { return nil }
        return CMTimeGetSeconds(CMTimeSubtract(CMClockMakeHostTimeFromSystemUnits(later),
                                             CMClockMakeHostTimeFromSystemUnits(earlier)))
    }
    func close() { lock.lock(); closed = true; CMTimebaseSetRate(timebase, rate: 0); rate = 0; lock.unlock() }
    var currentMediaSeconds: Double { lock.lock(); defer { lock.unlock() }; return CMTimeGetSeconds(CMTimebaseGetTime(timebase)) }
    var state: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["rate": rate ?? 0, "updates": updates, "holdUpdates": holdUpdates,
            "maximumAnchorCorrectionSeconds": maxCorrection, "maximumSteadyCorrectionSeconds": maxSteadyCorrection,
            "maximumSnapshotAgeSeconds": maxHostAge, "corrections": corrections,
            "receivedSnapshots": receivedSnapshots, "distinctValidHostSamples": distinctValidHostSamples,
            "maximumInterSnapshotReceiptGapSeconds": maxReceiptGap,
            "maximumValidSnapshotHostGapSeconds": maxValidHostGap,
            "snapshotGaps": snapshotGaps,
            "snapshotGapDetailThresholdSeconds": 0.050, "snapshotGapDetailLimit": 100,
            "snapshotGapScope": "Completed receipt intervals and distinct valid native-host intervals; excludes the currently open interval since the last receipt. No physical presentation or automatic clock policy.",
            "scope": "Core timebase anchoring; not AVKit physical presentation or acoustic synchronization"]
    }
}
