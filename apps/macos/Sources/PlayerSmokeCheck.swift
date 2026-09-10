import AppKit
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
    private func runDolbyVision() async throws {
        func native() -> [String: Any] { state()["nativeEnhancement"] as? [String: Any] ?? [:] }
        try await wait("real Dolby Vision frame reaches the native surface", seconds: 20) {
            !self.video.subviews.isEmpty && !self.webView.isLoading &&
            native()["source-dolby-vision"] as? Bool == true &&
            native()["displayed-dolby-vision-metadata"] as? Bool == true
        }
        let track = (state()["tracks"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "video" && $0["selected"] as? Bool == true }
        guard track?["dolby-vision-profile"] as? Int == 8 && track?["dolby-vision-compatibility-id"] as? Int == 4 else {
            throw Failure(message: "Expected the real Profile 8.4 regression fixture")
        }
        checks.append("selected stream retains Profile 8 and HLG compatibility ID 4")
        let disabled = try await script("return ['enhancement','strength','colorStrength','quality','mode'].every(id=>document.getElementById(id).disabled)")
        guard disabled == "true", (state()["capabilities"] as? [String: Any])?["prepared"] as? Bool == false else {
            throw Failure(message: "Unqualified Dolby Vision enhancement controls are available")
        }
        checks.append("neural quality, effect and Prepared controls are disabled")
        _ = try await script("window.webkit.messageHandlers.player.postMessage({command:'enhancement',value:true});return true")
        try await Task.sleep(for: .milliseconds(300))
        guard (state()["processing"] as? [String: Any])?["enabled"] as? Bool == false,
              native()["submitted-frames"] as? Int == 0 else { throw Failure(message: "Dolby Vision entered neural processing") }
        checks.append("direct enhancement request cannot admit a Dolby Vision frame")
        if state()["paused"] as? Bool != true { try await click("play") }
        try await wait("Dolby Vision pauses through native controls") { self.state()["paused"] as? Bool == true }
        try await change("timeline", value: "0.7")
        try await wait("Dolby Vision seeks while retaining native metadata") {
            abs(self.number("position") - 0.7) < 0.08 && native()["displayed-dolby-vision-metadata"] as? Bool == true
        }
        guard state()["error"] == nil else { throw Failure(message: state()["error"] as? String ?? "Dolby Vision playback error") }
        checks.append("native fallback has no playback error")
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
            if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] == "dolby-vision" {
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
