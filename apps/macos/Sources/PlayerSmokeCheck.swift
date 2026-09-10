import AppKit
import CryptoKit
import QuartzCore
import WebKit

/// Opt-in integration check. It drives the shipped DOM and checks independently
/// polled mpv state, with isolated preferences; normal launches never create it.
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
    private func number(_ key: String) -> Double { (state()[key] as? NSNumber)?.doubleValue ?? 0 }
    private func selected(_ type: String, id: Int) -> Bool {
        (state()["tracks"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == type && $0["id"] as? Int == id && $0["selected"] as? Bool == true }
    }
    private func runPictureInPicture() async throws {
        func pip() -> [String: Any] { state()["pip"] as? [String: Any] ?? [:] }
        func pipNumber(_ key: String) -> Int { (pip()[key] as? NSNumber)?.intValue ?? Int.max }
        func native() -> [String: Any] { state()["nativeEnhancement"] as? [String: Any] ?? [:] }
        try await wait("PiP diagnostic opt-in and media loaded", seconds: 20) {
            pip()["diagnosticEnabled"] as? Bool == true && self.number("duration") > 0 && !self.webView.isLoading
        }
        if state()["paused"] as? Bool != true { try await click("play") }
        try await wait("pause before PiP configuration") { self.state()["paused"] as? Bool == true }
        try await change("subtitleBrightness", value: "0.6")
        try await wait("native subtitle colour is opaque neutral gray at 0.6") {
            (self.state()["nativeSubtitleColor"] as? String)?.uppercased() == "#FF999999"
        }
        try await change("sub", value: "no")
        try await change("timeline", value: "0.3")
        if (state()["processing"] as? [String: Any])?["enabled"] as? Bool != true { try await click("enhancement") }
        try await wait("completed float stream and public PiP possibility", seconds: 25) {
            pip()["available"] as? Bool == true && (pip()["enqueuedFrames"] as? Int ?? 0) > 0
        }
        try await click("pip")
        try await wait("public PiP enters from shipped DOM control", seconds: 12) { pip()["active"] as? Bool == true }
        let firstFrames = pip()["enqueuedFrames"] as? Int ?? 0
        try await click("play")
        try await wait("PiP receives progressing frames from existing worker", seconds: 15) {
            self.state()["paused"] as? Bool == false && (pip()["enqueuedFrames"] as? Int ?? 0) >= firstFrames + 4
        }
        window.miniaturize(nil)
        let hiddenFrames = pip()["enqueuedFrames"] as? Int ?? 0
        try await wait("PiP keeps receiving selected frames while source window is minimized", seconds: 12) {
            self.window.isMiniaturized && (pip()["enqueuedFrames"] as? Int ?? 0) >= hiddenFrames + 4
        }
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        try await click("play")
        try await wait("PiP follows native user pause and held clock") {
            self.state()["paused"] as? Bool == true && pip()["clockRate"] as? Double == 0
        }
        try await wait("paused retained comparison is ready", seconds: 15) { native()["compare-ready"] as? Bool == true }
        try await Task.sleep(for: .milliseconds(500))
        let pts = native()["displayed-source-pts"] as? Int64
        let submitted = native()["submitted-frames"] as? Int
        let revision = pip()["revision"] as? UInt64 ?? 0
        try await click("compare")
        try await wait("unsupported original comparison exits PiP explicitly") {
            native()["comparison"] as? String == "original" && pip()["active"] as? Bool == false &&
            pip()["available"] as? Bool == false && (pip()["reason"] as? String ?? "").contains("float")
        }
        try await click("compare")
        try await wait("same-PTS enhanced replacement becomes available without inference", seconds: 12) {
            pip()["available"] as? Bool == true && (pip()["revision"] as? UInt64 ?? 0) > revision
        }
        guard native()["displayed-source-pts"] as? Int64 == pts,
              native()["submitted-frames"] as? Int == submitted else { throw Failure(message: "PiP comparison changed exact PTS or submitted new inference") }
        checks.append("same-PTS comparison preserved native identity and submission count")
        try await click("pip")
        try await wait("PiP re-enters after supported same-PTS replacement") { pip()["active"] as? Bool == true }
        let generation = pip()["generation"] as? UInt64
        try await change("timeline", value: "1.4")
        try await wait("paused seek rebinds PiP to a new generation and float frame", seconds: 20) {
            pip()["generation"] as? UInt64 != generation && pip()["compatibleStream"] as? Bool == true &&
            abs(self.number("position") - 1.4) < 0.1 && self.state()["paused"] as? Bool == true
        }
        try await change("sub", value: "1")
        try await wait("selected subtitles disable and stop uncomposited PiP") {
            pip()["active"] as? Bool == false && pip()["available"] as? Bool == false &&
            (pip()["reason"] as? String ?? "").lowercased().contains("subtitle")
        }
        try await change("sub", value: "no")
        try await wait("PiP capability recovers after subtitles are disabled") { pip()["available"] as? Bool == true }
        try await click("pip")
        try await wait("PiP active before application teardown") { pip()["active"] as? Bool == true }
        guard pipNumber("maximumObservedExportLeases") <= 3,
              pipNumber("pendingFrames") <= 1,
              pipNumber("submittedLeases") <= 1,
              pipNumber("producerPoolCapacity") == 6,
              state()["error"] == nil else { throw Failure(message: "PiP ownership bound or native playback health failed") }
        checks.append("three export leases, one pending/submitted sample and six producer surfaces stay bounded")
    }
    private func runSystemPictureInPicture() async throws {
        guard let path = ProcessInfo.processInfo.environment["HDRPLAYER_SYSTEM_PIP_DIRECTORY"] else {
            throw Failure(message: "System PiP inspection requires an explicit diagnostic directory")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let finish = directory.appendingPathComponent("finish")
        guard !FileManager.default.fileExists(atPath: finish.path) else {
            throw Failure(message: "Use a new system PiP diagnostic directory without a stale finish marker")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func pip() -> [String: Any] { state()["pip"] as? [String: Any] ?? [:] }
        try await wait("system PiP source and diagnostic controls initialized", seconds: 20) {
            pip()["diagnosticEnabled"] as? Bool == true && self.number("duration") > 40 && !self.webView.isLoading
        }
        if state()["paused"] as? Bool != true { try await click("play") }
        try await wait("system PiP setup pauses the native core") { self.state()["paused"] as? Bool == true }
        if state()["muted"] as? Bool != true { try await click("mute") }
        try await change("sub", value: "no")
        try await change("timeline", value: "20")
        if (state()["processing"] as? [String: Any])?["enabled"] as? Bool != true { try await click("enhancement") }
        try await wait("system PiP setup receives the paused float frame", seconds: 25) {
            pip()["available"] as? Bool == true && abs(self.number("position") - 20) < 0.05 && self.state()["paused"] as? Bool == true
        }
        try await click("pip")
        try await wait("system PiP owner ready for external Accessibility inspection", seconds: 12) { pip()["active"] as? Bool == true }
        let deadline = Date().addingTimeInterval(120)
        var minimizedByRequest = false
        while !FileManager.default.fileExists(atPath: finish.path) {
            guard Date() < deadline else { throw Failure(message: "External system PiP inspection timed out") }
            if !minimizedByRequest && FileManager.default.fileExists(atPath: directory.appendingPathComponent("minimize").path) {
                minimizedByRequest = true
                window.miniaturize(nil)
            }
            let value: [String: Any] = ["version": 1, "ready": true, "hostSeconds": ProcessInfo.processInfo.systemUptime,
                "playerPID": ProcessInfo.processInfo.processIdentifier, "state": state(),
                "sourceWindow": ["minimized": window.isMiniaturized, "visible": window.isVisible,
                    "key": window.isKeyWindow, "appActive": NSApp.isActive,
                    "frontmostIsPlayer": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier],
                "scope": "Waiting for external system AX controls; setup never invokes an AVKit playback delegate"]
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("live.json"), options: .atomic)
            if let error = state()["error"] as? String { throw Failure(message: error) }
            try await Task.sleep(for: .milliseconds(200))
        }
        checks.append("external system PiP inspection requested orderly teardown")
    }
    private func runReconfigurationPictureInPicture() async throws {
        func pip() -> [String: Any] { state()["pip"] as? [String: Any] ?? [:] }
        func native() -> [String: Any] { state()["nativeEnhancement"] as? [String: Any] ?? [:] }
        func integer(_ values: [String: Any], _ key: String) -> Int64 { (values[key] as? NSNumber)?.int64Value ?? -1 }
        func observe(_ phase: String) {
            guard snapshots.count < 512 else { return }
            let p = pip(), n = native(), clock = p["clock"] as? [String: Any] ?? [:]
            var sample: [String: Any] = ["phase": phase, "hostSeconds": ProcessInfo.processInfo.systemUptime,
                "configurationID": number("configurationID"), "playerPosition": number("position"),
                "userPaused": state()["paused"] ?? NSNull()]
            for key in ["active", "available", "epoch", "generation", "revision", "sourcePTS", "contentKind",
                        "enqueuedFrames", "pendingFrames", "submittedLeases", "clockRate", "reason"] {
                sample["pip-" + key] = p[key] ?? NSNull()
            }
            for key in ["displayed-generation", "displayed-source-pts", "displayed-timebase-num", "displayed-timebase-den"] {
                sample["native-" + key] = n[key] ?? NSNull()
            }
            for key in ["receivedSnapshots", "holdUpdates", "maximumInterSnapshotReceiptGapSeconds",
                        "maximumValidSnapshotHostGapSeconds", "maximumSnapshotAgeSeconds", "maximumAnchorCorrectionSeconds"] {
                sample["clock-" + key] = clock[key] ?? NSNull()
            }
            snapshots.append(sample)
        }
        try await wait("PiP reconfiguration diagnostic and source longer than ten seconds loaded", seconds: 20) {
            pip()["diagnosticEnabled"] as? Bool == true && self.number("duration") > 10 && !self.webView.isLoading
        }
        if state()["paused"] as? Bool != true { try await click("play") }
        try await wait("pause before reconfiguration setup") { self.state()["paused"] as? Bool == true }
        try await change("sub", value: "no")
        try await change("quality", value: "32x24")
        try await change("timeline", value: "0.3")
        if (state()["processing"] as? [String: Any])?["enabled"] as? Bool != true { try await click("enhancement") }
        try await wait("initial completed float frame enables PiP", seconds: 25) { pip()["available"] as? Bool == true }
        try await click("pip")
        try await wait("actual PiP enters before quality changes") { pip()["active"] as? Bool == true }
        let initialFrames = integer(pip(), "enqueuedFrames")
        try await click("play")
        try await wait("native playback and PiP progress before reconfiguration", seconds: 20) {
            self.state()["paused"] as? Bool == false && integer(pip(), "enqueuedFrames") >= initialFrames + 4
        }
        for (width, height) in [(160, 96), (32, 24)] {
            let beforeConfiguration = number("configurationID"), beforeEpoch = integer(pip(), "epoch")
            let phase = "quality-\(width)x\(height)"
            observe(phase + "-requested")
            try await change("quality", value: "\(width)x\(height)")
            let deadline = ProcessInfo.processInfo.systemUptime + 25
            var recovered = false
            repeat {
                observe(phase + "-waiting")
                let processing = state()["processing"] as? [String: Any] ?? [:]
                recovered = number("configurationID") > beforeConfiguration && integer(processing, "width") == Int64(width) &&
                    integer(processing, "height") == Int64(height) && integer(pip(), "epoch") > beforeEpoch && pip()["available"] as? Bool == true
                if recovered { break }
                try await Task.sleep(for: .milliseconds(100))
            } while ProcessInfo.processInfo.systemUptime < deadline
            guard recovered else { throw Failure(message: "No supported replacement epoch after " + phase) }
            observe(phase + "-supported-replacement")
            checks.append(phase + " creates a supported replacement epoch")
            // Record any stop instead of treating automatic PiP continuity as
            // established. This regression requires a recoverable new frame.
            if pip()["active"] as? Bool != true {
                try await click("pip")
                try await wait(phase + " PiP re-entry after recorded stop") { pip()["active"] as? Bool == true }
            }
            let frames = integer(pip(), "enqueuedFrames")
            try await wait(phase + " progresses with the new filter", seconds: 20) {
                integer(pip(), "enqueuedFrames") >= frames + 4 && self.state()["paused"] as? Bool == false
            }
            observe(phase + "-progressed")
        }
        try await click("play")
        try await wait("reconfigured PiP follows user pause and current native generation") {
            self.state()["paused"] as? Bool == true && (pip()["clockRate"] as? NSNumber)?.doubleValue == 0 &&
                integer(pip(), "generation") == integer(native(), "displayed-generation") && integer(pip(), "generation") > 0
        }
        observe("reconfiguration-finished-paused")
        let clock = pip()["clock"] as? [String: Any] ?? [:]
        guard clock["maximumInterSnapshotReceiptGapSeconds"] is NSNumber,
              clock["maximumValidSnapshotHostGapSeconds"] is NSNumber,
              (0...3).contains(integer(pip(), "maximumObservedExportLeases")),
              (0...1).contains(integer(pip(), "pendingFrames")), (0...1).contains(integer(pip(), "submittedLeases")),
              state()["error"] == nil else { throw Failure(message: "Missing gap diagnostics, unbounded leases or native error after quality changes") }
        checks.append("quality changes retain bounded leases and expose receipt/valid-host gaps without a physical timing claim")
    }
    private func runPreparedPictureInPicture() async throws {
        func pip() -> [String: Any] { state()["pip"] as? [String: Any] ?? [:] }
        func native() -> [String: Any] { state()["nativeEnhancement"] as? [String: Any] ?? [:] }
        func progress() -> [String: Any] { state()["prepared"] as? [String: Any] ?? [:] }
        func integer(_ values: [String: Any], _ key: String) -> Int64 { (values[key] as? NSNumber)?.int64Value ?? -1 }
        func exactIdentity() -> [Int64] {
            ["displayed-source-pts", "displayed-timebase-num", "displayed-timebase-den"].map { integer(native(), $0) }
        }
        func pipMatchesNativePTS() -> Bool {
            let time = pip()["sourcePTS"] as? [String: Any] ?? [:]
            let identity = exactIdentity(), scale = integer(time, "timescale")
            guard identity[1] > 0, identity[2] > 0, scale > 0 else { return false }
            // The requested one/eight-second frames keep these products in Int64.
            return integer(time, "value") * identity[2] == identity[0] * identity[1] * scale &&
                integer(pip(), "generation") == integer(native(), "displayed-generation")
        }
        try await wait("Prepared PiP diagnostic and source initialized", seconds: 20) {
            pip()["diagnosticEnabled"] as? Bool == true && self.number("duration") > 10 &&
            (self.state()["capabilities"] as? [String: Any])?["prepared"] as? Bool == true && !self.webView.isLoading
        }
        if state()["paused"] as? Bool != true { try await click("play") }
        try await wait("pause before loading existing Prepared cache") { self.state()["paused"] as? Bool == true }
        if state()["muted"] as? Bool != true { try await click("mute") }
        try await change("sub", value: "no")
        try await change("quality", value: "160x96")
        try await change("cacheCapacityGiB", value: "1")
        try await change("mode", value: "prepared")
        try await wait("filter-owned Prepared context opens seeded cache", seconds: 25) {
            progress()["configurationState"] as? String == "ready" &&
            !(progress()["availableRanges"] as? [[String: Any]] ?? []).isEmpty
        }
        if (state()["processing"] as? [String: Any])?["enabled"] as? Bool != true { try await click("enhancement") }
        try await change("timeline", value: "1")
        try await wait("cached float at one second becomes PiP available", seconds: 20) {
            native()["displayed-content-kind"] as? String == "prepared-enhanced" &&
            abs(self.number("position") - 1) < 0.02 && pip()["available"] as? Bool == true && pipMatchesNativePTS()
        }
        let cachedIdentity = exactIdentity()
        guard cachedIdentity[1] > 0, cachedIdentity[2] > 0 else { throw Failure(message: "Cached frame has no exact source identity") }
        try await click("pip")
        try await wait("cached float enters public PiP", seconds: 12) { pip()["active"] as? Bool == true }
        let initialFrames = integer(pip(), "enqueuedFrames")
        try await click("play")
        try await wait("Prepared PiP streams across the two-second segment boundary", seconds: 15) {
            self.state()["paused"] as? Bool == false && self.number("position") >= 2.2 && self.number("position") < 6 &&
            pip()["active"] as? Bool == true && integer(pip(), "enqueuedFrames") >= initialFrames + 20 &&
            native()["displayed-content-kind"] as? String == "prepared-enhanced"
        }
        try await click("play")
        try await wait("Prepared PiP pauses with the native clock") {
            self.state()["paused"] as? Bool == true && (pip()["clockRate"] as? NSNumber)?.doubleValue == 0
        }
        let generation = integer(pip(), "generation")
        try await change("timeline", value: "8")
        try await wait("uncached float Original stays in PiP with exact native source identity", seconds: 15) {
            abs(self.number("position") - 8) < 0.02 && native()["displayed-content-kind"] as? String == "original" &&
            self.state()["paused"] as? Bool == true && pip()["active"] as? Bool == true && pip()["available"] as? Bool == true &&
            integer(pip(), "contentKind") == 1 && integer(progress(), "cacheMisses") > 0 && pipMatchesNativePTS()
        }
        try await change("timeline", value: "1")
        try await wait("return to the same cached PTS recovers a new PiP generation", seconds: 20) {
            exactIdentity() == cachedIdentity && native()["displayed-content-kind"] as? String == "prepared-enhanced" &&
            pip()["active"] as? Bool == true && pip()["available"] as? Bool == true && integer(pip(), "contentKind") == 4 &&
            integer(pip(), "generation") > generation && pipMatchesNativePTS()
        }
        guard integer(progress(), "processedFrames") == 0 else { throw Failure(message: "PiP cache playback unexpectedly prepared new frames") }
        checks.append("cached PiP playback reused existing segments without a preparation job")
        try await wait("recovered cached PiP remains active for teardown") { pip()["active"] as? Bool == true }
        guard (0...3).contains(integer(pip(), "maximumObservedExportLeases")),
              (0...1).contains(integer(pip(), "pendingFrames")), (0...1).contains(integer(pip(), "submittedLeases")),
              integer(pip(), "producerPoolCapacity") == 6, state()["error"] == nil else {
            throw Failure(message: "Prepared PiP ownership or native playback health failed")
        }
        checks.append("Prepared PiP keeps bounded consumer leases and producer capacity")
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
    func start() { Task { await run() } }
    private func run() async {
        var failure: String?
        do {
            if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] == "pip-system" {
                try await runSystemPictureInPicture()
            } else if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] == "pip-prepared" {
                try await runPreparedPictureInPicture()
            } else if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] == "pip-reconfigure" {
                try await runReconfigurationPictureInPicture()
            } else if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] == "pip" {
                try await runPictureInPicture()
            } else if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] == "dolby-vision" {
                try await runDolbyVision()
            } else if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] == "prepared" {
                try await runPrepared()
            } else if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"]?.hasPrefix("preferences-") == true {
                try await runPreferences(write: ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] == "preferences-write")
            } else {
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
            guard state()["error"] == nil else { throw Failure(message: state()["error"] as? String ?? "Unknown playback error") }
            checks.append("no native playback error")
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
