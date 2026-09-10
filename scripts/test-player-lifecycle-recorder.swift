// CPU-only recorder format/limit/flush check. The snapshot below is test data;
// no media is opened and no sleep/wake notification is posted or requested.
import AppKit

@main
struct LifecycleRecorderChecks {
    @MainActor static func main() {
        let path = CommandLine.arguments.dropFirst().first ?? "/tmp/player-lifecycle-recorder-check.jsonl"
        var state: [String: Any] = ["source": "/diagnostic/no-media-opened", "paused": true, "playing": false,
            "requestedPause": NSNull(), "position": 0, "unrelatedPrivateProperty": "must-not-be-recorded",
            "nativeEnhancement": ["displayed-source-pts": Int64(1234567890),
                "displayed-timebase-num": 1, "displayed-timebase-den": 48000]]
        guard let recorder = PlayerLifecycleDiagnostics(path: path, snapshot: { state }) else {
            fatalError("Could not create diagnostic recorder")
        }
        recorder.recordState()
        state["nativeEnhancement"] = ["displayed-source-pts": 42, "displayed-timebase-num": 1, "displayed-timebase-den": 0]
        recorder.record("invalid-timebase-format-check", origin: "CPU-regression")
        for _ in 0..<510 { recorder.record("bounded-format-check", origin: "CPU-regression") }
        recorder.finish(extra: ["testDataOnly": true]) {
            do {
                let text = try String(contentsOfFile: path, encoding: .utf8)
                let rows = try text.split(separator: "\n").map {
                    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
                }
                precondition(rows.first?["event"] as? String == "diagnostic-start")
                let initial = rows.first?["state"] as! [String: Any]
                precondition(initial["exactDisplayedPTSAvailable"] as? Bool == true)
                precondition((initial["displayed-source-pts"] as? NSNumber)?.int64Value == 1234567890)
                precondition(initial["unrelatedPrivateProperty"] == nil)
                let invalid = rows.first { $0["event"] as? String == "invalid-timebase-format-check" }!["state"] as! [String: Any]
                precondition(invalid["exactDisplayedPTSAvailable"] as? Bool == false)
                let last = rows.last!
                precondition(last["event"] as? String == "diagnostic-finish")
                let details = last["details"] as! [String: Any]
                precondition(details["explicitEventsRecorded"] as? Int == 500)
                precondition(details["periodicStatesRecorded"] as? Int == 1)
                precondition(last["physicalSleepWakeObserved"] as? Bool == false)
                let startDetails = rows.first?["details"] as! [String: Any]
                print("Recorder format, valid/invalid rational timing, field limits, event bound and final flush passed; IOKit observer registered: \(startDetails["iokitPowerObserverAvailable"] ?? false). No physical sleep or playback was tested.")
                exit(0)
            } catch { fatalError("Recorder check failed: \(error)") }
        }
        RunLoop.main.run()
    }
}
