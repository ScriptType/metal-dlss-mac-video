import AppKit
import IOKit
import IOKit.pwr_mgt
import CMpv

private final class LifecycleLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "HDRPlayer.lifecycle-log")
    private let handle: FileHandle
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }
    func append(_ data: Data) { queue.async { try? self.handle.write(contentsOf: data) } }
    func close(completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async {
            try? self.handle.synchronize()
            try? self.handle.close()
            DispatchQueue.main.async { completion() }
        }
    }
}

/// Opt-in observation only. Never requests sleep, posts synthetic notifications,
/// changes an OS preference, or treats workspace messages as physical proof.
@MainActor
final class PlayerLifecycleDiagnostics {
    private let writer: LifecycleLogWriter
    private let snapshot: () -> [String: Any]
    private var observers: [NSObjectProtocol] = []
    private var powerPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var kernelSleepPending = false
    private var physicalCycles = 0
    private var nextPeriodic = Date.distantPast
    private var captureFrequentlyUntil = Date.distantPast
    private var periodicCount = 0
    private var eventCount = 0
    private var finished = false

    init?(path: String?, snapshot: @escaping () -> [String: Any]) {
        guard let path, !path.isEmpty else { return nil }
        do { writer = try LifecycleLogWriter(url: URL(fileURLWithPath: path)) }
        catch { fputs("Cannot open lifecycle diagnostic: \(error.localizedDescription)\n", stderr); return nil }
        self.snapshot = snapshot
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                let eventName = event.name.rawValue
                MainActor.assumeIsolated { self?.record(eventName, origin: "NSWorkspace") }
            })
        }
        powerPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notificationPort,
            { context, _, message, argument in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<PlayerLifecycleDiagnostics>.fromOpaque(context).takeUnretainedValue()
                        .powerMessage(message, argument: argument)
                }
            }, &notifier)
        if powerPort != 0, let notificationPort, let runLoopSource = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        record("diagnostic-start", origin: "recorder", extra: ["iokitPowerObserverAvailable": powerPort != 0,
            "voiceOverEnabled": NSWorkspace.shared.isVoiceOverEnabled, "physicalSleepWakeObserved": false,
            "limits": "At most 5000 periodic states and 500 explicit events; no physical cycle is inferred from synthetic/workspace-only events."])
    }

    private func powerMessage(_ message: UInt32, argument: UnsafeMutableRawPointer?) {
        // Acknowledge immediately. The diagnostic never vetoes or delays sleep.
        if message == hdr_player_power_can_sleep() || message == hdr_player_power_will_sleep() {
            IOAllowPowerChange(powerPort, Int(bitPattern: argument))
        }
        switch message {
        case hdr_player_power_can_sleep(): record("can-system-sleep", origin: "IOKit")
        case hdr_player_power_will_sleep():
            kernelSleepPending = true; record("system-will-sleep", origin: "IOKit")
        case hdr_player_power_will_not_sleep():
            kernelSleepPending = false; record("system-will-not-sleep", origin: "IOKit")
        case hdr_player_power_has_powered_on():
            if kernelSleepPending { physicalCycles += 1 }
            kernelSleepPending = false; record("system-has-powered-on", origin: "IOKit")
        default: break
        }
    }

    func recordState() {
        guard !finished, periodicCount < 5000 else { return }
        let now = Date()
        guard now >= nextPeriodic else { return }
        nextPeriodic = now.addingTimeInterval(now < captureFrequentlyUntil ? 0.1 : 1)
        periodicCount += 1
        write("state", origin: "native-property-poll", extra: [:])
    }

    func record(_ name: String, origin: String = "app-hook", extra: [String: Any] = [:]) {
        guard !finished, eventCount < 500 else { return }
        eventCount += 1
        captureFrequentlyUntil = Date().addingTimeInterval(3)
        nextPeriodic = .distantPast
        write(name, origin: origin, extra: extra)
    }

    private func write(_ name: String, origin: String, extra: [String: Any]) {
        let current = snapshot()
        let native = current["nativeEnhancement"] as? [String: Any] ?? [:]
        var state: [String: Any] = [:]
        for key in ["source", "paused", "requestedPause", "playing", "position", "duration", "loading", "fullscreen", "display", "error"] {
            if let value = current[key] { state[key] = value }
        }
        let selected = (current["tracks"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "video" && $0["selected"] as? Bool == true }
        state["videoTrackID"] = selected?["id"] ?? NSNull()
        state["exactDisplayedPTSAvailable"] = native["displayed-source-pts"] is NSNumber &&
            ((native["displayed-timebase-num"] as? NSNumber)?.int64Value ?? 0) > 0 &&
            ((native["displayed-timebase-den"] as? NSNumber)?.int64Value ?? 0) > 0
        for key in ["displayed-source-pts", "displayed-timebase-num", "displayed-timebase-den", "displayed-generation", "generation",
                    "displayed-content-kind", "policy", "pending-frames", "submitted-frames", "completed-frames", "buffering", "native-color-path"] {
            if let value = native[key] { state[key] = value }
        }
        let row: [String: Any] = ["version": 1, "event": name, "origin": origin,
            "timestamp": ISO8601DateFormatter().string(from: Date()), "uptimeSeconds": ProcessInfo.processInfo.systemUptime,
            "kernelSleepWakeCycles": physicalCycles, "physicalSleepWakeObserved": physicalCycles > 0,
            "state": state, "details": extra]
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(0x0A); writer.append(data)
    }

    func finish(extra: [String: Any] = [:], completion: @escaping @MainActor @Sendable () -> Void) {
        guard !finished else { completion(); return }
        var final = extra
        final["periodicStatesRecorded"] = periodicCount
        final["explicitEventsRecorded"] = eventCount
        // Always retain the final summary, even after the bounded event budget.
        write("diagnostic-finish", origin: "recorder", extra: final)
        finished = true
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let notificationPort {
            if let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if powerPort != 0 { IOServiceClose(powerPort) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil; powerPort = 0
        writer.close(completion: completion)
    }
}
