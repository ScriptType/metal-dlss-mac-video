import AppKit
import CryptoKit
import QuartzCore
import WebKit

@MainActor
final class PlayerSmokeCheck {
    let webView: WKWebView
    let window: NSWindow
    let video: NSView
    let reportURL: URL
    let state: () -> [String: Any]
    private var checks: [String] = []
    private var snapshots: [[String: Any]] = []

    init(webView: WKWebView, window: NSWindow, video: NSView, reportURL: URL, state: @escaping () -> [String: Any]) {
        self.webView = webView; self.window = window; self.video = video; self.reportURL = reportURL; self.state = state
    }
    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private func script(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript("JSON.stringify((()=>{\(source)})())") { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value as? String ?? "null") }
            }
        }
    }
    private func wait(_ label: String, seconds: Double = 8, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline { throw Failure(message: "Timed out: " + label) }
            try await Task.sleep(for: .milliseconds(100))
        }
        checks.append(label)
        snapshots.append(["check": label, "state": state()])
    }
    private func change(_ id: String, value: String, event: String = "change") async throws {
        _ = try await script("const e=document.getElementById('\(id)');e.value='\(value)';e.dispatchEvent(new Event('\(event)',{bubbles:true}));return true;")
    }
    private func click(_ id: String) async throws { _ = try await script("document.getElementById('\(id)').click();return true;") }
    /// The DOM renders one dispatch after the native state it reflects.
    private func waitForDOM(_ label: String, _ expression: String, equals expected: String, seconds: Double = 8) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        var actual = try await script("return \(expression);")
        while actual != expected {
            if Date() >= deadline { throw Failure(message: "Timed out: \(label); DOM returned \(actual)") }
            try await Task.sleep(for: .milliseconds(100))
            actual = try await script("return \(expression);")
        }
        checks.append(label)
    }
    private func processing() -> [String: Any] { state()["processing"] as? [String: Any] ?? [:] }
    private func number(_ key: String) -> Double { (state()[key] as? NSNumber)?.doubleValue ?? 0 }
    private func selected(_ type: String, id: Int) -> Bool {
        (state()["tracks"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == type && $0["id"] as? Int == id && $0["selected"] as? Bool == true }
    }
    private func runDolbyVision() async throws {
        let environment = ProcessInfo.processInfo.environment
        let legacyProfile = environment["HDRPLAYER_DV_PROFILE"] ?? "8.4"
        let fixture = environment["HDRPLAYER_DV_FIXTURE"] ?? (legacyProfile == "5" ? "fate-profile5" : "fate-profile84")
        guard ["fate-profile84", "fate-profile5", "apple-profile5"].contains(fixture),
              environment["HDRPLAYER_DV_PROFILE"] == nil || ["8.4", "5"].contains(legacyProfile) else {
            throw Failure(message: "Unsupported diagnostic Dolby fixture")
        }
        let profile = fixture == "fate-profile84" ? 8 : 5, compatibility = fixture == "fate-profile84" ? 4 : 0
        let requested = profile == 8 ? "8.4" : "5"
        let seekSeconds = profile == 5 ? 0.125 : 0.7
        let expectedBytes: Int
        let expectedSHA: String
        switch fixture {
        case "apple-profile5":
            expectedBytes = 42855591
            expectedSHA = "69bbb93355cb91d69eefe7f24f6525e61670aa3ae25bbfb4a546a19a0358e110"
        case "fate-profile5":
            expectedBytes = 4182
            expectedSHA = "11fe599fd77e31e26fbf855bae1cd9931df9f261a0a7b1dce9fad9b236677c4b"
        default:
            expectedBytes = 3621742
            expectedSHA = "aaa9289a9755eaebd9962204f24a6acf8a19ff104657a3a79b6b1fa672993721"
        }
        func native() -> [String: Any] { state()["nativeEnhancement"] as? [String: Any] ?? [:] }
        try await wait("decoded Dolby Vision metadata reaches the native surface", seconds: 20) {
            !self.video.subviews.isEmpty && !self.webView.isLoading &&
            native()["source-dolby-vision"] as? Bool == true &&
            native()["displayed-dolby-vision-metadata"] as? Bool == true
        }
        guard let path = state()["source"] as? String,
              let bytes = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber,
              bytes.intValue == expectedBytes else { throw Failure(message: "Diagnostic Dolby source does not match the pinned fixture size") }
        let actualSHA = try await Task.detached(priority: .utility) {
            let payload = try Data(contentsOf: URL(fileURLWithPath: path))
            return SHA256.hash(data: payload).map({ String(format: "%02x", $0) }).joined()
        }.value
        guard actualSHA == expectedSHA else {
            throw Failure(message: "Diagnostic Dolby source does not match the pinned SHA-256")
        }
        let track = (state()["tracks"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "video" && $0["selected"] as? Bool == true }
        guard track?["dolby-vision-profile"] as? Int == profile && track?["dolby-vision-compatibility-id"] as? Int == compatibility else {
            throw Failure(message: "Selected native stream does not match the pinned Dolby profile/compatibility")
        }
        checks.append("pinned \(fixture) Profile \(requested) stream retains compatibility ID \(compatibility)")
        let disabled = try await script("return ['enhancement','strength','colorStrength','quality','mode'].every(id=>document.getElementById(id).disabled)")
        guard disabled == "true", (state()["capabilities"] as? [String: Any])?["prepared"] as? Bool == false else {
            throw Failure(message: "Unqualified Dolby Vision enhancement controls are available")
        }
        checks.append("neural quality, effect and Prepared controls are disabled")
        _ = try await script("window.webkit.messageHandlers.player.postMessage({command:'enhancement',value:true});return true")
        try await Task.sleep(for: .milliseconds(300))
        guard (state()["processing"] as? [String: Any])?["enabled"] as? Bool == false,
              native()["submitted-frames"] as? Int == 0, native()["policy"] as? String == "bypass",
              native()["buffering"] as? Bool == false, native()["native-color-path"] as? String == "native-dolby-vision" else {
            throw Failure(message: "Dolby Vision entered neural processing or left its native metadata path")
        }
        checks.append("direct enhancement request cannot admit a Dolby Vision frame")
        if state()["paused"] as? Bool != true { try await click("play") }
        try await wait("Dolby Vision pauses through native controls") { self.state()["paused"] as? Bool == true }
        if fixture == "apple-profile5" {
            try await runAppleDolbySeeks(sourceSHA: expectedSHA)
            guard state()["error"] == nil else { throw Failure(message: state()["error"] as? String ?? "Dolby Vision playback error") }
            checks.append("representative native transport has no playback error; no colour qualification inferred")
            return
        }
        guard seekSeconds > 0 && seekSeconds < number("duration") else { throw Failure(message: "Dolby fixture seek lies outside its actual duration") }
        try await change("timeline", value: String(seekSeconds))
        try await wait("Dolby Vision seeks while retaining native metadata") {
            let pts = (native()["displayed-source-pts"] as? NSNumber)?.doubleValue ?? -1
            let numerator = (native()["displayed-timebase-num"] as? NSNumber)?.doubleValue ?? 0
            let denominator = (native()["displayed-timebase-den"] as? NSNumber)?.doubleValue ?? 0
            let sourceAtTarget = denominator > 0 && abs(pts * numerator / denominator - seekSeconds) < (profile == 5 ? 1e-9 : 0.045)
            return abs(self.number("position") - seekSeconds) < 0.045 && sourceAtTarget &&
                native()["displayed-dolby-vision-metadata"] as? Bool == true &&
                native()["native-color-path"] as? String == "native-dolby-vision" && native()["submitted-frames"] as? Int == 0
        }
        guard state()["error"] == nil else { throw Failure(message: state()["error"] as? String ?? "Dolby Vision playback error") }
        checks.append("native metadata path has no playback error; no colour qualification inferred")
    }
    private struct DolbySeekInventory: Decodable {
        struct Frame: Decodable, Equatable { let pts: Int64; let duration: Int64 }
        let fixtureID: String
        let sourceSHA256: String
        let timebaseNumerator: Int64
        let timebaseDenominator: Int64
        let formatStartSeconds: String
        let frames: [Frame]
        let targets: [Frame]
    }
    private func runAppleDolbySeeks(sourceSHA: String) async throws {
        guard let path = ProcessInfo.processInfo.environment["HDRPLAYER_DV_INVENTORY"],
              let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber,
              size.intValue > 0 && size.intValue < 1_048_576 else {
            throw Failure(message: "Apple diagnostic requires a bounded exact source inventory from test-dovi-passthrough.py")
        }
        let inventory = try JSONDecoder().decode(DolbySeekInventory.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard inventory.fixtureID == "apple-profile5", inventory.sourceSHA256 == sourceSHA,
              inventory.timebaseNumerator == 1, inventory.timebaseDenominator == 24000,
              inventory.frames.count == 2360, inventory.frames.first?.pts == 240000,
              inventory.frames.allSatisfy({ $0.duration > 0 }), inventory.targets.count == 3,
              zip(inventory.frames, inventory.frames.dropFirst()).allSatisfy({ $0.pts < $1.pts }),
              inventory.targets.allSatisfy({ inventory.frames.contains($0) }),
              let expectedStart = Double(inventory.formatStartSeconds), expectedStart.isFinite,
              let nativeStart = state()["nativeDemuxerStartTime"] as? Double, nativeStart.isFinite,
              let rebased = state()["nativeRebaseStartTime"] as? Bool else {
            throw Failure(message: "Apple inventory or native demuxer/rebase timing does not match the pinned source")
        }
        let offset = rebased ? -nativeStart : 0
        let offsetTicks = offset * Double(inventory.timebaseDenominator)
        guard offsetTicks.isFinite, abs(offsetTicks - offsetTicks.rounded()) < 1e-6,
              offsetTicks > Double(Int64.min), offsetTicks < Double(Int64.max) else {
            throw Failure(message: "Native demuxer offset is not exact in the pinned source timebase")
        }
        let exactOffsetTicks = Int64(offsetTicks.rounded())
        func native() -> [String: Any] { state()["nativeEnhancement"] as? [String: Any] ?? [:] }
        func sourcePTS() -> Int64? {
            guard let pts = (native()["displayed-source-pts"] as? NSNumber)?.int64Value,
                  let num = (native()["displayed-timebase-num"] as? NSNumber)?.int64Value,
                  let den = (native()["displayed-timebase-den"] as? NSNumber)?.int64Value,
                  num == inventory.timebaseNumerator, den == inventory.timebaseDenominator else { return nil }
            // demux_set_ts_offset runs before decoding; keep original file
            // inventory PTS separate from the raw exact decoder timestamp.
            let original = pts.subtractingReportingOverflow(exactOffsetTicks)
            return original.overflow ? nil : original.partialValue
        }
        guard let initialSourcePTS = sourcePTS(), inventory.frames.contains(where: { $0.pts == initialSourcePTS }),
              abs(Double(initialSourcePTS) / Double(inventory.timebaseDenominator) + offset - number("position")) < 1e-6 else {
            throw Failure(message: "Observed native offset does not match the held exact source/player pair")
        }
        snapshots.append(["check": "observed native source-to-player mapping", "sourceToPlayerOffsetSeconds": offset,
                          "nativeDemuxerStartTime": nativeStart, "nativeRebaseStartTime": rebased,
                          "ffprobeFormatStartSeconds": expectedStart, "initialSourcePTS": initialSourcePTS,
                          "initialNativeDecoderPTS": initialSourcePTS + exactOffsetTicks,
                          "nativeDecoderOffsetTicks": exactOffsetTicks,
                          "initialPlayerSeconds": number("position"), "sourceTimebaseDenominator": inventory.timebaseDenominator])
        checks.append("native demuxer start and rebase offset match a held exact source/player pair")
        if state()["muted"] as? Bool != true { try await click("mute") }
        for target in inventory.targets {
            let sourceSeconds = Double(target.pts) / Double(inventory.timebaseDenominator)
            let playerSeconds = sourceSeconds + offset
            guard playerSeconds > 0 && playerSeconds < number("duration") else { throw Failure(message: "Mapped representative seek exceeds the native player range") }
            // Read the real range value before state updates can replace it.
            // Its 1ms step may round this rational source-to-player mapping.
            let effectiveValue = try await script("const e=document.getElementById('timeline');e.value='\(playerSeconds)';const v=Number(e.value);e.dispatchEvent(new Event('change',{bubbles:true}));return v;")
            guard let effectiveSeconds = Double(effectiveValue), effectiveSeconds.isFinite,
                  abs(effectiveSeconds - playerSeconds) <= 0.001 else {
                throw Failure(message: "DOM seek value changed beyond the timeline's millisecond precision")
            }
            try await wait("Apple native displayed source PTS equals \(target.pts)/\(inventory.timebaseDenominator)", seconds: 15) {
                sourcePTS() == target.pts && self.state()["paused"] as? Bool == true &&
                native()["displayed-dolby-vision-metadata"] as? Bool == true &&
                native()["native-color-path"] as? String == "native-dolby-vision" &&
                native()["submitted-frames"] as? Int == 0 && native()["buffering"] as? Bool == false
            }
            snapshots.append(["check": "exact mapped representative seek", "requestedPlayerSeconds": playerSeconds,
                              "effectiveDOMPlayerSeconds": effectiveSeconds, "domRoundingSeconds": effectiveSeconds - playerSeconds,
                              "expectedSourcePTS": target.pts, "sourceDuration": target.duration, "state": state()])
            try await click("play")
            try await wait("representative native playback begins") { self.state()["paused"] as? Bool == false }
            var observed = Set<Int64>()
            var samples: [[String: Any]] = []
            let sampleStart = ProcessInfo.processInfo.systemUptime
            func recordSamples() {
                snapshots.append(["check": "representative playback observation window", "samples": samples,
                    "distinctOriginalPTSCount": observed.count, "sourcePTS": observed.sorted(),
                    "elapsedSeconds": ProcessInfo.processInfo.systemUptime - sampleStart])
            }
            for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(100))
                let currentPTS = sourcePTS()
                samples.append(["elapsedSeconds": ProcessInfo.processInfo.systemUptime - sampleStart,
                    "originalSourcePTS": currentPTS.map { $0 as Any } ?? NSNull(),
                    "nativeDecoderPTS": native()["displayed-source-pts"] ?? NSNull(),
                    "source": state()["source"] ?? NSNull(), "position": number("position"),
                    "paused": state()["paused"] ?? NSNull(), "buffering": native()["buffering"] ?? NSNull(),
                    "appActive": NSApp.isActive, "windowOnActiveSpace": window.isOnActiveSpace,
                    "windowOcclusionVisible": window.occlusionState.contains(.visible),
                    "windowVisible": window.isVisible, "windowMinimized": window.isMiniaturized])
                guard let pts = currentPTS, inventory.frames.contains(where: { $0.pts == pts }),
                      native()["displayed-dolby-vision-metadata"] as? Bool == true,
                      native()["native-color-path"] as? String == "native-dolby-vision",
                      native()["submitted-frames"] as? Int == 0, native()["buffering"] as? Bool == false else {
                    recordSamples()
                    throw Failure(message: "Representative native Dolby transport lost source identity/metadata or admitted neural work")
                }
                observed.insert(pts)
            }
            recordSamples()
            guard observed.count >= 6 else { throw Failure(message: "Representative native frames did not progress") }
            snapshots.append(["check": "representative native PTS progression", "sourcePTS": observed.sorted(), "state": state()])
            checks.append("representative native frames progress with metadata and zero neural submissions")
            try await click("play")
            try await wait("representative playback pauses") { self.state()["paused"] as? Bool == true }
        }
        let nearEnd = inventory.frames[inventory.frames.count - 13]
        let nearEndPlayer = Double(nearEnd.pts) / Double(inventory.timebaseDenominator) + offset
        let nativeDuration = number("duration")
        let rangeJSON = try await script("const e=document.getElementById('timeline');e.value='\(nearEndPlayer)';const r={maximum:Number(e.max),effective:Number(e.value)};e.dispatchEvent(new Event('change',{bubbles:true}));return r;")
        guard let rangeData = rangeJSON.data(using: .utf8),
              let range = try JSONSerialization.jsonObject(with: rangeData) as? [String: Double],
              let effective = range["effective"], let maximum = range["maximum"] else {
            throw Failure(message: "Cannot inspect the actual near-end DOM seek range")
        }
        try await Task.sleep(for: .seconds(1))
        snapshots.append(["check": "near-end actual DOM seek", "desiredPlayerSeconds": nearEndPlayer,
                          "nativeDurationSeconds": nativeDuration, "effectiveDOMPlayerSeconds": effective,
                          "domMaximumSeconds": maximum, "expectedSourcePTS": nearEnd.pts, "state": state()])
        if abs(effective - nearEndPlayer) <= 0.001 && maximum >= nearEndPlayer {
            try await wait("actual DOM seek selects the exact near-end source PTS", seconds: 15) {
                sourcePTS() == nearEnd.pts && native()["displayed-dolby-vision-metadata"] as? Bool == true &&
                    native()["submitted-frames"] as? Int == 0
            }
        }
        // Also exercise the existing native command bridge directly. This
        // separates a DOM range limit from the core's actual seek capability.
        _ = try await script("window.webkit.messageHandlers.player.postMessage({command:'seek',value:\(nearEndPlayer)});return true")
        try await wait("direct native bridge reaches the exact near-end source PTS", seconds: 15) {
            sourcePTS() == nearEnd.pts && native()["displayed-dolby-vision-metadata"] as? Bool == true &&
                native()["submitted-frames"] as? Int == 0
        }
        snapshots.append(["check": "near-end direct bridge result", "desiredPlayerSeconds": nearEndPlayer,
                          "expectedSourcePTS": nearEnd.pts, "state": state()])
        guard abs(effective - nearEndPlayer) <= 0.001 && maximum >= nearEndPlayer else {
            throw Failure(message: "Native duration/DOM maximum \(maximum)s clips source near-end \(nearEndPlayer)s, although the direct native bridge selects its exact source PTS")
        }
        checks.append("actual DOM timeline covers the inventoried near-end source frame")
    }
    private func runPreferences(write: Bool) async throws {
        try await wait("empty player and controls initialized", seconds: 20) { self.state()["initialized"] as? Bool == true && !self.webView.isLoading }
        if !EnhancementMode.developerModesEnabled {
            try await waitForDOM("controls render the empty player's native state", "!document.getElementById('quality').disabled", equals: "true")
            let empty = try await script("const m=document.getElementById('mode');return {options:m.options.length,modeDisabled:m.disabled,enhancementDisabled:document.getElementById('enhancement').disabled};")
            guard let data = empty.data(using: .utf8), let controls = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  controls["options"] as? Int == 0, controls["modeDisabled"] as? Bool == true, controls["enhancementDisabled"] as? Bool == true else {
                throw Failure(message: "Empty ordinary player offers a mode or an enabled enhancement switch: \(empty)")
            }
            checks.append("empty ordinary player offers no mode and disables the enhancement switch")
        }
        if write {
            try await change("volume", value: "37", event: "input")
            if state()["muted"] as? Bool != true { try await click("mute") }
            try await click("settings-open")
            try await change("quality", value: "160x96")
            try await change("subtitleBrightness", value: "0.6")
            try await change("subtitleScale", value: "1.2")
            try await change("subtitleDelay", value: "0.3")
            try await click("settings-close")
            try await change("cacheCapacityGiB", value: "2")
        }
        try await wait(write ? "selected preferences applied through controls" : "selected preferences restored by a new process") {
            let processing = self.state()["processing"] as? [String: Any] ?? [:]
            let prepared = self.state()["prepared"] as? [String: Any] ?? [:]
            return abs(self.number("volume") - 37) < 0.001 && self.state()["muted"] as? Bool == true &&
                abs(self.number("subtitleScale") - 1.2) < 0.001 && abs(self.number("subtitleDelay") - 0.3) < 0.001 &&
                abs((processing["subtitleBrightness"] as? Double ?? 0) - 0.6) < 0.001 &&
                processing["width"] as? Int == 160 && processing["height"] as? Int == 96 &&
                prepared["capacityBytes"] as? Int64 == 2_147_483_648
        }
        guard state()["error"] == nil else { throw Failure(message: state()["error"] as? String ?? "Preference error") }
        checks.append("preference changes work without opening media")
    }
    private func runPrepared() async throws {
        func progress() -> [String: Any] { state()["prepared"] as? [String: Any] ?? [:] }
        func native() -> [String: Any] { state()["nativeEnhancement"] as? [String: Any] ?? [:] }
        try await wait("Prepared capability available for local MP4", seconds: 20) {
            self.number("duration") > 0 && (self.state()["capabilities"] as? [String: Any])?["prepared"] as? Bool == true
        }
        if state()["paused"] as? Bool != true { try await click("play") }
        try await wait("Prepared test paused") { self.state()["paused"] as? Bool == true }
        try await change("mode", value: "prepared")
        try await wait("filter-owned Prepared context ready", seconds: 20) { progress()["configurationState"] as? String == "ready" }
        try await change("timeline", value: "0.1")
        try await wait("unprepared miss visibly remains original") {
            native()["displayed-content-kind"] as? String == "original" && (progress()["cacheMisses"] as? Int ?? 0) > 0
        }
        try await click("prepare-open")
        let oldConfiguration = number("configurationID")
        try await change("cacheCapacityGiB", value: "1")
        try await wait("capacity rebuild drains previous cache owner", seconds: 20) {
            self.number("configurationID") > oldConfiguration && progress()["configurationState"] as? String == "ready" && self.state()["error"] == nil
        }
        try await click("prepare-start")
        try await wait("preparation advances while UI remains active", seconds: 20) {
            progress()["jobState"] as? String == "preparing" && (progress()["processedFrames"] as? Int ?? 0) > 0
        }
        try await click("prepare-cancel")
        try await wait("preparation cancels", seconds: 20) { progress()["jobState"] as? String == "cancelled" }
        try await click("prepare-start")
        try await wait("preparation resumes to committed completion", seconds: 60) {
            progress()["jobState"] as? String == "complete" && (progress()["availableRanges"] as? [[String: Any]] ?? []).count > 0
        }
        guard try await script("return document.querySelectorAll('#prepared-ranges button').length > 0;") == "true" else {
            throw Failure(message: "Committed Prepared ranges are missing from the dialog")
        }
        _ = try await script("document.querySelector('#prepared-ranges button').click();return true;")
        try await wait("coverage button seeks to a prepared enhanced frame", seconds: 20) {
            native()["displayed-content-kind"] as? String == "prepared-enhanced" && (progress()["cacheHits"] as? Int ?? 0) > 0
        }
        try await click("prepare-open")
        try await click("prepare-start")
        try await wait("completed preparation reuses segments without model work", seconds: 20) {
            let total = progress()["totalSegments"] as? Int ?? 0
            return progress()["jobState"] as? String == "complete" && total > 0 && progress()["reusedSegments"] as? Int == total && progress()["processedFrames"] as? Int == 0
        }
        try await click("prepare-close")
        guard state()["error"] == nil, progress()["error"] == nil else { throw Failure(message: "Prepared playback reported an error") }
        guard let layer = video.subviews.first?.layer as? CAMetalLayer, layer.pixelFormat == .rgba16Float,
              layer.wantsExtendedDynamicRangeContent else { throw Failure(message: "Prepared enhanced output is not float EDR") }
        checks.append("Prepared neural cache output uses float EDR with no playback error")
    }
    private func runPreparedPlayback() async throws {
        guard !EnhancementMode.developerModesEnabled else {
            throw Failure(message: "prepared-playback checks ordinary playback; unset HDRPLAYER_DEVELOPER_MODES")
        }
        func native() -> [String: Any] { state()["nativeEnhancement"] as? [String: Any] ?? [:] }
        func progress() -> [String: Any] { state()["prepared"] as? [String: Any] ?? [:] }
        try await wait("source opened with Prepared as the only mode", seconds: 20) {
            !self.webView.isLoading && self.number("duration") > 0 && self.processing()["availableModes"] as? [String] == ["prepared"]
        }
        if state()["paused"] as? Bool != true { try await click("play") }
        try await wait("paused before enabling Prepared") { self.state()["paused"] as? Bool == true }
        try await waitForDOM("enhancement switch is enabled for Prepared", "document.getElementById('enhancement').disabled", equals: "false")
        try await click("enhancement")
        try await wait("Prepared context ready with enhancement on", seconds: 30) {
            self.processing()["enabled"] as? Bool == true && self.processing()["mode"] as? String == "prepared" &&
                native()["policy"] as? String == "prepared" && progress()["configurationState"] as? String == "ready"
        }
        guard (progress()["availableRanges"] as? [[String: Any]] ?? []).isEmpty else {
            throw Failure(message: "The source already has prepared ranges, so playback would not show original frames")
        }
        checks.append("source has no prepared ranges, so playback shows original frames")
        try await click("prepare-open")
        try await waitForDOM("preparation can start", "document.getElementById('prepare-start').disabled", equals: "false")
        try await click("prepare-start")
        try await wait("preparation running", seconds: 20) { progress()["jobState"] as? String == "preparing" }
        try await click("prepare-close")
        // The window starts once playback is seen advancing, which excludes the one-time preview wait.
        let start = number("position")
        try await click("play")
        try await wait("original playback advances while preparing", seconds: 20) {
            self.state()["paused"] as? Bool == false && self.number("position") > start + 0.2
        }
        var samples: [[String: Any]] = []
        let begin = ProcessInfo.processInfo.systemUptime
        while true {
            let elapsed = ProcessInfo.processInfo.systemUptime - begin
            samples.append(["elapsedSeconds": elapsed, "position": number("position"),
                "buffering": native()["buffering"] ?? NSNull(), "bufferCount": native()["buffer-count"] ?? NSNull(),
                "frameDrops": state()["frameDrops"] ?? NSNull(), "decoderDrops": state()["decoderDrops"] ?? NSNull(),
                "displayedContentKind": native()["displayed-content-kind"] ?? NSNull(),
                "jobState": progress()["jobState"] ?? NSNull(), "enabled": processing()["enabled"] ?? NSNull(),
                "error": state()["error"] ?? NSNull()])
            if elapsed >= 12 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        func value(_ sample: [String: Any], _ key: String) -> Double { (sample[key] as? NSNumber)?.doubleValue ?? .nan }
        let first = samples[0], last = samples[samples.count - 1]
        let window = value(last, "elapsedSeconds") - value(first, "elapsedSeconds")
        let ratio = (value(last, "position") - value(first, "position")) / window
        let bufferCountBefore = value(first, "bufferCount")
        snapshots.append(["check": "original playback while preparing", "samples": samples])
        snapshots.append(["check": "original playback rate while preparing", "source": state()["source"] ?? NSNull(),
            "windowSeconds": window, "sampleCount": samples.count, "positionPerWallSecond": ratio,
            "bufferCountBefore": bufferCountBefore, "bufferCountAfter": value(last, "bufferCount"),
            "frameDropsDelta": value(last, "frameDrops") - value(first, "frameDrops"),
            "decoderDropsDelta": value(last, "decoderDrops") - value(first, "decoderDrops"),
            "contentKinds": Set(samples.compactMap { $0["displayedContentKind"] as? String }).sorted()])
        guard samples.allSatisfy({ $0["jobState"] as? String == "preparing" }) else {
            throw Failure(message: "Preparation left the preparing state during the window")
        }
        guard samples.allSatisfy({ $0["buffering"] as? Bool == false }),
              samples.allSatisfy({ value($0, "bufferCount") <= bufferCountBefore }) else {
            throw Failure(message: "Playback paused its clocks for enhancement while preparing")
        }
        guard samples.allSatisfy({ $0["enabled"] as? Bool == true }) else {
            throw Failure(message: "Enhancement turned off during the window")
        }
        guard (0.97...1.03).contains(ratio) else {
            throw Failure(message: "Position advanced \(ratio) s per wall second while preparing")
        }
        checks.append("original plays at source rate for \(Int(window)) s while preparing, without buffering")
        try await click("play")
        try await wait("paused after the window") { self.state()["paused"] as? Bool == true }
    }
    private func runControls() async throws {
        try await wait("media metadata and native view loaded", seconds: 20) {
            self.number("duration") > 0 && (self.state()["tracks"] as? [[String: Any]] ?? []).count >= 4 && !self.video.subviews.isEmpty
        }
        let dom = try await script("return {audio:document.getElementById('audio').options.length,subtitles:document.getElementById('sub').options.length,chapters:document.getElementById('chapter').options.length,modeDisabled:document.getElementById('mode').disabled,canvas:document.querySelectorAll('canvas,video').length};")
        guard let data = dom.data(using: .utf8), let contents = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              contents["audio"] as? Int == 2, contents["subtitles"] as? Int == 2, contents["chapters"] as? Int == 2,
              contents["canvas"] as? Int == 0 else { throw Failure(message: "Controls did not reflect fixture tracks/chapters: \(dom)") }
        checks.append("WK controls reflect native tracks and chapters; no web video surface")
        if state()["paused"] as? Bool != true { try await click("play") }
        try await wait("pause via DOM") { self.state()["paused"] as? Bool == true }
        _ = try await script("const e=document.getElementById('volume');for(let i=0;i<1000;i++){e.value=String(i%101);e.dispatchEvent(new Event('input',{bubbles:true}));}e.value='37';e.dispatchEvent(new Event('input',{bubbles:true}));return true;")
        try await wait("latest volume survives 1000 queued input events") { abs(self.number("volume") - 37) < 0.01 }
        try await click("mute")
        try await wait("mute via DOM") { self.state()["muted"] as? Bool == true }
        try await change("audio", value: "2")
        try await wait("alternate audio selected") { self.selected("audio", id: 2) }
        try await change("sub", value: "1")
        try await wait("native subtitle selected") { self.selected("sub", id: 1) }
        try await change("chapter", value: "1")
        try await wait("chapter seek") { self.number("chapter") == 1 && self.number("position") >= 1.45 }
        try await click("settings-open")
        guard try await script("return document.getElementById('settings').open;") == "true" else { throw Failure(message: "Settings dialog failed to open") }
        try await change("subtitleBrightness", value: "0.6")
        try await change("subtitleScale", value: "1.2")
        try await change("subtitleDelay", value: "0.3")
        try await wait("subtitle scale and delay applied natively") { abs(self.number("subtitleScale") - 1.2) < 0.01 && abs(self.number("subtitleDelay") - 0.3) < 0.01 }
        try await wait("subtitle brightness is opaque neutral gray in native mpv state") {
            (self.state()["nativeSubtitleColor"] as? String)?.uppercased() == "#FF999999"
        }
        try await click("settings-close")
        try await change("timeline", value: "0.7")
        try await wait("exact paused timeline seek") { abs(self.number("position") - 0.7) < 0.05 && self.state()["paused"] as? Bool == true }
        let beforeStep = number("position")
        _ = try await script("document.querySelector('[data-command=frameStep][data-value=\"1\"]').click();return true;")
        try await wait("frame step advances one frame while paused") { self.number("position") > beforeStep + 0.02 && self.number("position") < beforeStep + 0.05 && self.state()["paused"] as? Bool == true }
        window.setContentSize(NSSize(width: 800, height: 620))
        try await wait("embedded native view resizes") { abs((self.video.subviews.first?.bounds.width ?? 0) - 800) < 1 }
        try await click("fullscreen")
        try await wait("fullscreen via DOM") { self.state()["fullscreen"] as? Bool == true }
        try await click("fullscreen")
        try await wait("exit fullscreen via DOM") { self.state()["fullscreen"] as? Bool == false }
        if EnhancementMode.developerModesEnabled { try await runDeveloperEnhancement() }
        else { try await runOrdinaryEnhancement() }
        guard state()["error"] == nil else { throw Failure(message: state()["error"] as? String ?? "Unknown playback error") }
        checks.append("no native playback error")
    }
    private func runOrdinaryEnhancement() async throws {
        func native() -> [String: Any] { state()["nativeEnhancement"] as? [String: Any] ?? [:] }
        try await wait("native state offers only Prepared", seconds: 20) { self.processing()["availableModes"] as? [String] == ["prepared"] }
        try await waitForDOM("ordinary controls offer only Prepared; Live and Adaptive are absent",
            "Array.from(document.getElementById('mode').options,o=>o.value)", equals: "[\"prepared\"]")
        try await waitForDOM("enhancement switch is enabled for Prepared", "document.getElementById('enhancement').disabled", equals: "false")
        try await click("enhancement")
        try await wait("enhancement switch turns Prepared on", seconds: 20) {
            self.processing()["enabled"] as? Bool == true && self.processing()["mode"] as? String == "prepared" &&
                native()["policy"] as? String == "prepared"
        }
    }
    private func runDeveloperEnhancement() async throws {
        try await wait("developer state offers Adaptive", seconds: 20) {
            (self.processing()["availableModes"] as? [String] ?? []).contains("adaptive")
        }
        try await waitForDOM("developer controls offer Adaptive",
            "Array.from(document.getElementById('mode').options,o=>o.value).includes('adaptive')", equals: "true")
        try await change("mode", value: "adaptive")
        try await wait("explicit switch to Adaptive") { self.processing()["mode"] as? String == "adaptive" }
        try await click("enhancement")
        try await wait("enhancement command accepted") { (self.state()["processing"] as? [String: Any])?["enabled"] as? Bool == true }
        try await click("play")
        try await wait("neural playback advances", seconds: 20) { self.number("position") > 1.2 && self.state()["paused"] as? Bool == false }
        try await click("play")
        try await wait("neural pause") { self.state()["paused"] as? Bool == true }
        try await wait("paused same-frame pair available", seconds: 20) {
            (self.state()["capabilities"] as? [String: Any])?["sameFrameComparison"] as? Bool == true
        }
        try await Task.sleep(for: .milliseconds(500))
        let paired = state()["nativeEnhancement"] as? [String: Any] ?? [:]
        let identityKeys = ["displayed-source-pts", "displayed-timebase-num", "displayed-timebase-den", "displayed-generation", "submitted-frames"]
        let identity = identityKeys.map { String(describing: paired[$0]) }
        try await click("compare")
        try await wait("compare original at retained timestamp") {
            (self.state()["nativeEnhancement"] as? [String: Any])?["comparison"] as? String == "original"
        }
        var compared = state()["nativeEnhancement"] as? [String: Any] ?? [:]
        guard identityKeys.map({ String(describing: compared[$0]) }) == identity else {
            throw Failure(message: "Original comparison changed rational PTS, generation or submitted frames")
        }
        try await click("compare")
        try await wait("compare enhanced at retained timestamp") {
            (self.state()["nativeEnhancement"] as? [String: Any])?["comparison"] as? String == "enhanced"
        }
        compared = state()["nativeEnhancement"] as? [String: Any] ?? [:]
        guard identityKeys.map({ String(describing: compared[$0]) }) == identity else {
            throw Failure(message: "Enhanced comparison changed rational PTS, generation or submitted frames")
        }
        guard let layer = video.subviews.first?.layer as? CAMetalLayer, layer.pixelFormat == .rgba16Float,
              layer.wantsExtendedDynamicRangeContent else { throw Failure(message: "Neural presentation is not float EDR") }
        checks.append("retained comparison preserved rational PTS/generation without inference submission; float EDR active")
    }
    func start() { Task { await run() } }
    private func run() async {
        var failure: String?
        do {
            switch ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] {
            case "dolby-vision": try await runDolbyVision()
            case "prepared": try await runPrepared()
            case "prepared-playback": try await runPreparedPlayback()
            case let kind? where kind.hasPrefix("preferences-"): try await runPreferences(write: kind == "preferences-write")
            default: try await runControls()
            }
        } catch { failure = error.localizedDescription }
        let layer = video.subviews.first?.layer as? CAMetalLayer
        var report: [String: Any] = ["passed": failure == nil, "checks": checks, "snapshots": snapshots,
            "finalState": state(), "scope": "Functional DOM/native playback integration; not realtime or display qualification",
            "nativeLayer": ["format": layer?.pixelFormat.rawValue ?? 0, "edr": layer?.wantsExtendedDynamicRangeContent ?? false,
                "colorSpace": layer?.colorspace?.name as String? ?? "unknown"]]
        if let failure { report["failure"] = failure }
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
        } catch { fputs("Cannot write UI smoke report: \(error)\n", stderr) }
        fputs("HDRPlayer UI smoke: \(failure ?? "passed")\n", stderr)
        NSApp.terminate(nil)
    }
}
