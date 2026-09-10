import CMpv
import CoreMedia
import Darwin
import Foundation

// CPU-only clock/mailbox regression. The synthetic snapshots exercise consumer
// logic; they do not qualify a native audio clock, AVKit presentation or sleep.
@main
struct PiPClockChecks {
    static func snapshot(media: Double, rate: Double, epoch: UInt64 = 1,
                         generation: UInt64 = 1, revision: UInt64 = 1,
                         supported: Bool = true, valid: Bool = true,
                         ticks: UInt64 = mach_absolute_time()) -> NativePiPSnapshot {
        var value = mpv_hdr_snapshot()
        value.host_ticks = ticks; value.clock_valid = valid ? 1 : 0
        value.supported = supported ? 1 : 0; value.media_seconds = media; value.rate = rate
        value.stream_epoch = epoch; value.generation = generation; value.revision = revision
        return NativePiPSnapshot(state: value)
    }

    @MainActor static func main() async throws {
        let clock = NativePiPCoreClock()!
        clock.update(snapshot(media: 10, rate: 0))
        assert(abs(clock.currentMediaSeconds - 10) < 0.000001)
        clock.update(snapshot(media: 12, rate: 1))
        assert(CMTimebaseGetRate(clock.timebase) == 1)
        let beforeStale = clock.currentMediaSeconds
        clock.update(snapshot(media: 999, rate: 0, ticks: 1))
        assert(CMTimebaseGetRate(clock.timebase) == 1)
        assert(abs(clock.currentMediaSeconds - beforeStale) < 0.1)

        clock.update(snapshot(media: 3.5, rate: 0, epoch: 2, generation: 2))
        assert(abs(clock.currentMediaSeconds - 3.5) < 0.000001)
        clock.update(snapshot(media: 4, rate: 1, epoch: 2, generation: 2, supported: false))
        assert(CMTimebaseGetRate(clock.timebase) == 0)
        assert(abs(clock.currentMediaSeconds - 4) < 0.000001)
        clock.update(snapshot(media: .nan, rate: 1, valid: false))
        assert(CMTimebaseGetRate(clock.timebase) == 0 && clock.currentMediaSeconds.isFinite)

        var delivered: [UInt64] = []
        let mailbox = NativePiPMailbox(clock: clock) { value in delivered.append(value.state.revision) }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for index in 1...2_000 {
                mailbox.submit(snapshot(media: Double(index), rate: index == 2_000 ? 0 : 1,
                                        epoch: 3, generation: 3, revision: UInt64(index)))
            }
            finished.signal()
        }
        // Deliberately block this main actor: the worker must deliver the hold
        // directly to CoreMedia while coalescing its main-thread callback.
        assert(finished.wait(timeout: .now() + 5) == .success)
        assert(delivered.isEmpty)
        assert(CMTimebaseGetRate(clock.timebase) == 0)
        assert(abs(clock.currentMediaSeconds - 2_000) < 0.000001)
        for _ in 0..<100 where delivered.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        assert(delivered == [2_000])

        mailbox.submit(snapshot(media: 3_000, rate: 0, revision: 3_000))
        mailbox.close()
        clock.close()
        let closedTime = clock.currentMediaSeconds
        mailbox.submit(snapshot(media: 4_000, rate: 1, revision: 4_000))
        try await Task.sleep(for: .milliseconds(20))
        assert(delivered == [2_000])
        assert(CMTimebaseGetRate(clock.timebase) == 0 && clock.currentMediaSeconds == closedTime)

        // Deterministic synthetic receipt times distinguish a worker delivery
        // gap from the gap between valid native samples, without sleeping or
        // relying on scheduler jitter. Invalid/duplicate/stale samples cannot
        // invent a new native clock observation or move its watermark backward.
        var units = mach_timebase_info_data_t()
        mach_timebase_info(&units)
        func ticks(_ seconds: Double) -> UInt64 {
            UInt64((seconds * 1_000_000_000 * Double(units.denom) / Double(units.numer)).rounded())
        }
        let base = mach_absolute_time() - ticks(2)
        let gaps = NativePiPCoreClock()!
        gaps.update(snapshot(media: 1, rate: 0, ticks: base), receiptHostTicks: base)
        gaps.update(snapshot(media: .nan, rate: 0, valid: false, ticks: base + ticks(0.01)), receiptHostTicks: base + ticks(0.01))
        gaps.update(snapshot(media: 1.5, rate: 0, ticks: base + ticks(0.51)), receiptHostTicks: base + ticks(0.51))
        gaps.update(snapshot(media: 1.5, rate: 0, ticks: base + ticks(0.51)), receiptHostTicks: base + ticks(0.52))
        gaps.update(snapshot(media: 999, rate: 1, ticks: base + ticks(0.005)), receiptHostTicks: base + ticks(0.005))
        gaps.update(snapshot(media: 1.53, rate: 0, ticks: base + ticks(0.53)), receiptHostTicks: base + ticks(0.53))
        let measured = gaps.state
        assert(abs((measured["maximumInterSnapshotReceiptGapSeconds"] as! Double) - 0.5) < 0.000001)
        assert(abs((measured["maximumValidSnapshotHostGapSeconds"] as! Double) - 0.51) < 0.000001)
        assert(measured["receivedSnapshots"] as? Int == 6 && measured["distinctValidHostSamples"] as? Int == 3)
        let gapEvents = measured["snapshotGaps"] as! [[String: Any]]
        assert(gapEvents.count == 1 && gapEvents[0]["validHostSample"] as? Bool == true)
        assert(CMTimebaseGetRate(gaps.timebase) == 0 && abs(gaps.currentMediaSeconds - 1.53) < 0.000001)
        gaps.close()
        gaps.update(snapshot(media: 999, rate: 1), receiptHostTicks: base + ticks(1.9))
        assert(gaps.state["receivedSnapshots"] as? Int == 6)

        // Keep diagnostic storage bounded while continuing to measure maxima
        // after the detailed event buffer fills.
        let bounded = NativePiPCoreClock()!
        let boundedBase = mach_absolute_time() - ticks(120)
        for index in 0...105 {
            let stamp = boundedBase + ticks(Double(index))
            bounded.update(snapshot(media: Double(index), rate: 0, ticks: stamp), receiptHostTicks: stamp)
        }
        let last = boundedBase + ticks(107)
        bounded.update(snapshot(media: 107, rate: 0, ticks: last), receiptHostTicks: last)
        assert((bounded.state["snapshotGaps"] as! [[String: Any]]).count == 100)
        assert(abs((bounded.state["maximumInterSnapshotReceiptGapSeconds"] as! Double) - 2) < 0.000001)
        assert(abs((bounded.state["maximumValidSnapshotHostGapSeconds"] as! Double) - 2) < 0.000001)
        bounded.close()
        print("9 PiP clock/mailbox/gap checks passed; CPU logic only, no AVKit or physical A/V qualification")
    }
}
