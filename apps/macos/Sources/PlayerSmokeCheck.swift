import AppKit
import CryptoKit
import QuartzCore
import WebKit

/// Records only a smoke-registered NSEvent object while the existing app monitor handles it.
/// Unregistered events are neither retained nor described.
@MainActor
final class PlayerSyntheticKeyReceipt {
    static weak var active: PlayerSyntheticKeyReceipt?
    let event: NSEvent
    let eventID: String
    let sessionID: String
    let sequence: Int
    let context: () -> [String: Any]
    private(set) var arrivalCount = 0
    private(set) var returnCount = 0
    private(set) var commandCount = 0
    private(set) var arrivals: [[String: Any]] = []
    private(set) var returns: [[String: Any]] = []
    private(set) var commands: [[String: Any]] = []

    init(event: NSEvent, eventID: String, sessionID: String, sequence: Int,
         context: @escaping () -> [String: Any]) {
        self.event = event; self.eventID = eventID; self.sessionID = sessionID
        self.sequence = sequence; self.context = context
    }
    var eventIdentity: String { String(describing: ObjectIdentifier(event)) }
    var registration: [String: Any] {
        ["eventID": eventID, "sessionID": sessionID, "sequence": sequence, "eventIdentity": eventIdentity,
         "type": Int(event.type.rawValue), "keyCode": Int(event.keyCode),
         "characters": event.characters ?? "", "charactersIgnoringModifiers": event.charactersIgnoringModifiers ?? "",
         "modifierFlags": event.modifierFlags.rawValue, "isRepeat": event.isARepeat,
         "timestamp": event.timestamp, "windowNumber": event.windowNumber]
    }
    private func record(_ kind: String) -> [String: Any] {
        let target = event.window
        return ["eventID": eventID, "sessionID": sessionID, "sequence": sequence, "eventIdentity": eventIdentity,
            "kind": kind, "hostSeconds": ProcessInfo.processInfo.systemUptime,
            "eventWindowNumber": event.windowNumber,
            "resolvedEventWindowNumber": target.map { $0.windowNumber as Any } ?? NSNull(),
            "resolvedEventWindowIdentity": target.map { String(describing: ObjectIdentifier($0)) as Any } ?? NSNull(),
            "type": Int(event.type.rawValue), "keyCode": Int(event.keyCode),
            "characters": event.characters ?? "", "charactersIgnoringModifiers": event.charactersIgnoringModifiers ?? "",
            "modifierFlags": event.modifierFlags.rawValue, "isRepeat": event.isARepeat,
            "eventTimestamp": event.timestamp, "context": context()]
    }
    static func willHandle(_ event: NSEvent) {
        guard let active, active.event === event else { return }
        active.arrivalCount += 1
        if active.arrivals.count < 2 { active.arrivals.append(active.record("monitor-before-handleKey")) }
    }
    static func didHandle(_ event: NSEvent, consumed: Bool) {
        guard let active, active.event === event else { return }
        active.returnCount += 1
        var row = active.record("monitor-after-handleKey")
        row["consumed"] = consumed
        if active.returns.count < 2 { active.returns.append(row) }
    }
    static func didInvoke(_ event: NSEvent, command: String, value: Any) {
        guard let active, active.event === event else { return }
        active.commandCount += 1
        var row = active.record("command-returned")
        row["command"] = command; row["value"] = value
        if active.commands.count < 2 { active.commands.append(row) }
    }
}

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
    private func runFloatingVideo() async throws {
        let spacePath = ProcessInfo.processInfo.environment["HDRPLAYER_FLOATING_SPACE_DIRECTORY"]
        let spaceDeadline = ProcessInfo.processInfo.systemUptime + 90
        var spaceStageDeadline: Double? = nil
        let fullscreenDiagnostic = ProcessInfo.processInfo.environment["HDRPLAYER_FLOATING_FULLSCREEN_DIAGNOSTIC"] == "1"
        let fullscreenDeadline = ProcessInfo.processInfo.systemUptime + 90
        var fullscreenStageDeadline: Double? = nil
        let capturePath = ProcessInfo.processInfo.environment["HDRPLAYER_FLOATING_CAPTURE_DIRECTORY"]
        let keyDiagnostic = ProcessInfo.processInfo.environment["HDRPLAYER_FLOATING_KEYBOARD_DIAGNOSTIC"] == "1"
        let keyStarted = ProcessInfo.processInfo.systemUptime
        let keyDeadline = keyStarted + 90
        var keyStageDeadline: Double? = keyDiagnostic ? min(keyDeadline, keyStarted + 15) : nil
        guard !keyDiagnostic || (spacePath == nil && !fullscreenDiagnostic && capturePath == nil) else {
            throw Failure(message: "Select only one floating keyboard, Space, fullscreen or capture diagnostic")
        }
        if keyDiagnostic {
            guard PlayerSyntheticKeyReceipt.active == nil,
                  let path = ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_WINDOW_OBSERVATIONS"],
                  !path.isEmpty else { throw Failure(message: "Synthetic keyboard diagnostic requires the external window observer") }
        }
        guard !fullscreenDiagnostic || capturePath == nil else {
            throw Failure(message: "Select only one floating capture or fullscreen diagnostic")
        }
        guard spacePath == nil || (!fullscreenDiagnostic && capturePath == nil) else {
            throw Failure(message: "Select only one floating Space, fullscreen or capture diagnostic")
        }
        let spaceDirectory: URL?
        if let path = spacePath {
            guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else {
                throw Failure(message: "Floating Space diagnostic requires a new absolute directory")
            }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            spaceDirectory = directory
        } else { spaceDirectory = nil }
        let captureStarted = ProcessInfo.processInfo.systemUptime
        let captureDeadline = captureStarted + 105
        let captureDirectory: URL?
        var capturePhaseDeadline: Double? = nil
        if let path = capturePath {
            guard path.hasPrefix("/"), !FileManager.default.fileExists(atPath: path) else {
                throw Failure(message: "Floating capture requires a new absolute output directory")
            }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            captureDirectory = directory
        } else { captureDirectory = nil }
        func checkCaptureDeadline() throws {
            if keyDiagnostic && ProcessInfo.processInfo.systemUptime >= min(keyDeadline, keyStageDeadline ?? keyDeadline) {
                throw Failure(message: "Floating keyboard diagnostic exceeded its fifteen-second phase or ninety-second overall deadline")
            }
            if spaceDirectory != nil && ProcessInfo.processInfo.systemUptime >= min(spaceDeadline, spaceStageDeadline ?? spaceDeadline) {
                throw Failure(message: "Floating Space diagnostic exceeded its stage or overall deadline")
            }
            if fullscreenDiagnostic && ProcessInfo.processInfo.systemUptime >= min(fullscreenDeadline, fullscreenStageDeadline ?? fullscreenDeadline) {
                throw Failure(message: "Floating fullscreen diagnostic exceeded its stage or overall deadline")
            }
            if let phaseDeadline = capturePhaseDeadline, ProcessInfo.processInfo.systemUptime >= phaseDeadline {
                throw Failure(message: "Floating capture exceeded its 30-second phase deadline")
            }
            if captureDirectory != nil && ProcessInfo.processInfo.systemUptime >= captureDeadline {
                throw Failure(message: "Floating capture exceeded its 105-second overall deadline")
            }
        }
        func floatingWait(_ label: String, seconds: Double = 8, until condition: () -> Bool) async throws {
            guard captureDirectory != nil || fullscreenDiagnostic || spaceDirectory != nil || keyDiagnostic else { try await self.wait(label, seconds: seconds, until: condition); return }
            let overall = keyDiagnostic ? keyDeadline : spaceDirectory != nil ? spaceDeadline : fullscreenDiagnostic ? fullscreenDeadline : captureDeadline
            let stage = keyDiagnostic ? keyStageDeadline : spaceDirectory != nil ? spaceStageDeadline : fullscreenDiagnostic ? fullscreenStageDeadline : capturePhaseDeadline
            let deadline = min(min(overall, stage ?? overall), ProcessInfo.processInfo.systemUptime + seconds)
            while true {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "Timed out: " + label) }
                if condition() { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            checks.append(label)
            snapshots.append(["check": label, "state": state()])
        }
        func floating() -> [String: Any] { state()["floatingVideo"] as? [String: Any] ?? [:] }
        func native() -> [String: Any] { state()["nativeEnhancement"] as? [String: Any] ?? [:] }
        func integer(_ values: [String: Any], _ key: String) -> Int64 { (values[key] as? NSNumber)?.int64Value ?? -1 }
        let identityKeys = ["displayed-source-pts", "displayed-timebase-num", "displayed-timebase-den",
            "displayed-generation", "generation", "submitted-frames", "completed-frames", "pending-frames"]
        func identity() -> [String: Int64]? {
            let value = native()
            guard identityKeys.allSatisfy({ value[$0] is NSNumber }),
                  integer(value, "displayed-timebase-num") > 0, integer(value, "displayed-timebase-den") > 0,
                  integer(value, "displayed-generation") > 0, integer(value, "completed-frames") > 0 else { return nil }
            return Dictionary(uniqueKeysWithValues: identityKeys.map { ($0, integer(value, $0)) })
        }
        func record(_ label: String) {
            snapshots.append(["check": label, "hostSeconds": ProcessInfo.processInfo.systemUptime, "state": state()])
        }
        func settle(_ label: String, allowBufferedPending: Bool = false) async throws -> [String: Int64] {
            var previous: [String: Int64]?, consecutive = 0
            try await floatingWait(label, seconds: 25) {
                let current = identity()
                let pending = integer(native(), "pending-frames")
                // Ordinary pause may retain future output within HDR_SLOTS (3).
                // Initial setup and paused seeks still require an empty queue.
                let pendingReady = allowBufferedPending
                    ? (0...3).contains(pending) && native()["preview-pending"] as? Bool == false
                    : pending == 0
                let ready = self.state()["paused"] as? Bool == true && native()["compare-ready"] as? Bool == true &&
                    pendingReady && current != nil
                consecutive = ready && current == previous ? consecutive + 1 : 0
                previous = current
                return ready && consecutive >= 3
            }
            guard let result = identity() else { throw Failure(message: "Missing exact native identity after " + label) }
            return result
        }
        func exactSeconds(_ seconds: Int64) -> Bool {
            let value = native(), pts = integer(value, "displayed-source-pts")
            let num = integer(value, "displayed-timebase-num"), den = integer(value, "displayed-timebase-den")
            guard pts >= 0, num > 0, den > 0 else { return false }
            let lhs = pts.multipliedReportingOverflow(by: num), rhs = seconds.multipliedReportingOverflow(by: den)
            return !lhs.overflow && !rhs.overflow && lhs.partialValue == rhs.partialValue
        }
        func menuEntry(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.title == "Floating Video (Diagnostic)" { return (menu, index) }
                if let child = item.submenu, let found = menuEntry(child) { return found }
            }
            return nil
        }
        func button(_ identifier: String, in view: NSView) -> NSButton? {
            if let candidate = view as? NSButton,
               candidate.identifier?.rawValue == "HDRPlayer.floatingVideo." + identifier { return candidate }
            for child in view.subviews { if let found = button(identifier, in: child) { return found } }
            return nil
        }
        func observeWindowBeforeAction(_ window: NSWindow, requestLabel: String) async throws {
            guard let path = ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_WINDOW_OBSERVATIONS"],
                  !path.isEmpty else { return }
            let started = ProcessInfo.processInfo.systemUptime
            let number = window.windowNumber
            guard number > 0 else { throw Failure(message: "Native action has no window number: " + requestLabel) }
            while ProcessInfo.processInfo.systemUptime - started < 5 {
                try checkCaptureDeadline()
                guard window.windowNumber == number else {
                    throw Failure(message: "Native action window changed while awaiting observation: " + requestLabel)
                }
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let observation = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   observation["version"] as? Int == 1,
                   observation["targetPID"] as? Int == Int(ProcessInfo.processInfo.processIdentifier),
                   let queryStart = observation["queryStartUptime"] as? Double, queryStart.isFinite,
                   let queryEnd = observation["queryEndUptime"] as? Double, queryEnd.isFinite,
                   queryStart >= started, queryEnd >= queryStart,
                   let windows = observation["windows"] as? [[String: Any]],
                   let observed = windows.first(where: { $0["windowID"] as? Int == number }),
                   observed["onScreen"] as? Bool == true, observed["alpha"] as? Double == 1,
                   let bounds = observed["bounds"] as? [String: Double],
                   ["X", "Y", "Width", "Height"].allSatisfy({ bounds[$0]?.isFinite == true }),
                   (bounds["Width"] ?? 0) > 0, (bounds["Height"] ?? 0) > 0 {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - started < 5, queryEnd <= now, now - queryEnd <= 2 {
                        let proof: [String: Any] = ["version": 1,
                            "targetPID": Int(ProcessInfo.processInfo.processIdentifier),
                            "queryStartUptime": queryStart, "queryEndUptime": queryEnd,
                            "windows": [["windowID": number, "onScreen": true, "alpha": 1, "bounds": bounds]]]
                        var ready: [String: Any] = ["check": requestLabel + "-observer-window-ready", "hostSeconds": now,
                            "waitStartedUptime": started, "windowObservation": proof, "state": state()]
                        if fullscreenDiagnostic || keyDiagnostic { ready["actionWindowNumber"] = number }
                        snapshots.append(ready)
                        return
                    }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw Failure(message: "Timed out awaiting fresh observer window record: " + requestLabel)
        }
        func press(_ identifier: String, in panel: NSPanel) async throws {
            guard let content = panel.contentView, let control = button(identifier, in: content),
                  control.isEnabled, !control.isHidden, control.target != nil, control.action != nil else {
                throw Failure(message: "Native floating button unavailable: " + identifier)
            }
            let requestLabel = "native-button-" + identifier + "-requested"
            try await observeWindowBeforeAction(panel, requestLabel: requestLabel)
            try checkCaptureDeadline()
            record(requestLabel)
            control.performClick(nil)
        }
        try await floatingWait("floating prototype and sixty-second fixture loaded", seconds: 20) {
            floating()["implementation"] as? String == "appkit-floating-video-prototype" &&
                floating()["diagnosticOnly"] as? Bool == true && self.number("duration") >= 59 &&
                self.number("duration") <= 61 && !self.webView.isLoading && !self.video.subviews.isEmpty
        }
        if keyDiagnostic { try checkCaptureDeadline() }
        if state()["paused"] as? Bool != true {
            try await click("play")
            if keyDiagnostic { try checkCaptureDeadline() }
        }
        try await floatingWait("native core paused before floating setup") { self.state()["paused"] as? Bool == true }
        if keyDiagnostic { try checkCaptureDeadline() }
        if state()["muted"] as? Bool != true {
            try await click("mute")
            if keyDiagnostic { try checkCaptureDeadline() }
        }
        try await change("sub", value: captureDirectory == nil ? "no" : "1")
        if keyDiagnostic { try checkCaptureDeadline() }
        if captureDirectory != nil {
            try await change("subtitleBrightness", value: "1")
            try await change("subtitleScale", value: "1")
            try await change("subtitleDelay", value: "0")
        }
        if keyDiagnostic { try checkCaptureDeadline() }
        try await change("quality", value: "160x96")
        if keyDiagnostic { try checkCaptureDeadline() }
        try await change("timeline", value: captureDirectory == nil ? "20" : "4")
        if keyDiagnostic { try checkCaptureDeadline() }
        if (state()["processing"] as? [String: Any])?["enabled"] as? Bool != true {
            try await click("enhancement")
            if keyDiagnostic { try checkCaptureDeadline() }
        }
        try await floatingWait(captureDirectory == nil ? "160x96 Adaptive enhancement reaches exact twenty-second frame" : "160x96 Adaptive enhancement reaches exact four-second frame", seconds: 25) {
            let processing = self.state()["processing"] as? [String: Any] ?? [:]
            return processing["enabled"] as? Bool == true && processing["mode"] as? String == "adaptive" &&
                integer(processing, "width") == 160 && integer(processing, "height") == 96 && exactSeconds(captureDirectory == nil ? 20 : 4)
        }
        if captureDirectory != nil {
            try await floatingWait("capture subtitle selection and native settings applied") {
                self.selected("sub", id: 1) && self.number("subtitleScale") == 1 && self.number("subtitleDelay") == 0 &&
                    (self.state()["nativeSubtitleColor"] as? String)?.uppercased() == "#FFFFFFFF" &&
                    ((self.state()["processing"] as? [String: Any])?["subtitleBrightness"] as? NSNumber)?.doubleValue == 1
            }
        }
        let initial = try await settle("initial paused rational PTS and accepted/emitted filter counters settle")
        let children = video.subviews, layers = video.subviews.compactMap { $0.layer }
        guard let metal = layers.first as? CAMetalLayer, children.count == layers.count,
              let home = video.superview, video.window === window,
              let source = state()["source"] as? String, !source.isEmpty,
              let core = state()["coreLibrary"] as? String, !core.isEmpty,
              let configuration = state()["configurationID"] as? NSNumber else {
            throw Failure(message: "Missing native view, Metal layer or core configuration identity")
        }
        func checkObjects(_ label: String) throws {
            guard video.subviews.count == children.count, zip(video.subviews, children).allSatisfy({ $0.0 === $0.1 }),
                  zip(children, layers).allSatisfy({ $0.0.layer === $0.1 }),
                  state()["source"] as? String == source, state()["coreLibrary"] as? String == core,
                  (state()["configurationID"] as? NSNumber)?.uint64Value == configuration.uint64Value,
                  metal.pixelFormat == .rgba16Float, metal.wantsExtendedDynamicRangeContent,
                  state()["error"] == nil else { throw Failure(message: "Native ownership/configuration/EDR changed at " + label) }
        }
        func preserved(_ expected: [String: Int64], _ label: String) async throws {
            let actual = try await settle(label, allowBufferedPending: (expected["pending-frames"] ?? 0) > 0)
            guard actual == expected else { throw Failure(message: "Paused PTS, generation, accepted/emitted filter counters or pending count changed at " + label) }
            try checkObjects(label)
            checks.append(label + " preserves actual host child/layer, rational PTS, generations, accepted/emitted filter counters and pending count")
        }
        func enter(_ label: String) async throws -> NSPanel {
            guard let main = NSApp.mainMenu, let (menu, index) = menuEntry(main) else {
                throw Failure(message: "Floating diagnostic native menu item missing")
            }
            menu.update()
            guard menu.items[index].isEnabled, floating()["canEnter"] as? Bool == true else {
                throw Failure(message: "Floating diagnostic native menu entry disabled")
            }
            let requestLabel = label + "-menu-requested"
            try await observeWindowBeforeAction(window, requestLabel: requestLabel)
            try checkCaptureDeadline()
            record(requestLabel)
            menu.performActionForItem(at: index)
            try await floatingWait(label + " reparents the same host into an observable native panel") {
                guard let panel = self.video.window as? NSPanel else { return false }
                return panel.identifier?.rawValue == "HDRPlayer.floatingVideo" && panel.isVisible && !panel.isMiniaturized &&
                    panel.isOnActiveSpace && panel.occlusionState.contains(.visible) &&
                    floating()["active"] as? Bool == true && floating()["phase"] as? String == "floating" &&
                    integer(floating(), "homeConstraintsActive") == 0 && integer(floating(), "floatingConstraintsActive") == 4 &&
                    floating()["childIdentitiesMatchEntry"] as? Bool == true && floating()["childLayerIdentitiesMatchEntry"] as? Bool == true
            }
            guard let panel = video.window as? NSPanel else { throw Failure(message: "Floating panel disappeared") }
            try checkObjects(label)
            return panel
        }
        func returned(_ panel: NSPanel, _ label: String, minimized: Bool) async throws {
            try await floatingWait(label) {
                self.video.superview === home && self.video.window === self.window && !panel.isVisible && panel.contentView == nil &&
                    floating()["active"] as? Bool == false && floating()["phase"] as? String == "home" &&
                    integer(floating(), "homeConstraintsActive") == 4 && integer(floating(), "floatingConstraintsActive") == 0 &&
                    self.window.isMiniaturized == minimized && (minimized || self.window.isVisible)
            }
            try checkObjects(label)
        }
        func progress(_ label: String, from start: [String: Int64], panel: NSPanel, minimized: Bool) async throws {
            var seen = Set<Int64>()
            try await floatingWait(label, seconds: 20) {
                let value = native(), pts = integer(value, "displayed-source-pts")
                let eligible = integer(value, "displayed-generation") == start["displayed-generation"] &&
                    integer(value, "generation") == start["generation"] &&
                    integer(value, "displayed-timebase-num") == start["displayed-timebase-num"] &&
                    integer(value, "displayed-timebase-den") == start["displayed-timebase-den"] &&
                    self.state()["paused"] as? Bool == false && self.window.isMiniaturized == minimized &&
                    self.video.window === panel && panel.isVisible && panel.isOnActiveSpace && panel.occlusionState.contains(.visible) &&
                    floating()["active"] as? Bool == true && self.state()["source"] as? String == source &&
                    self.state()["coreLibrary"] as? String == core &&
                    (self.state()["configurationID"] as? NSNumber)?.uint64Value == configuration.uint64Value &&
                    self.video.subviews.count == children.count && zip(self.video.subviews, children).allSatisfy({ $0.0 === $0.1 }) &&
                    zip(children, layers).allSatisfy({ $0.0.layer === $0.1 })
                if eligible, pts > (start["displayed-source-pts"] ?? Int64.max), seen.insert(pts).inserted {
                    record(label + "-exact-PTS")
                }
                return eligible && seen.count >= 3 && integer(value, "completed-frames") >= (start["completed-frames"] ?? Int64.max) + 3
            }
            try checkObjects(label)
        }
        if keyDiagnostic {
            guard PlayerSyntheticKeyReceipt.active == nil,
                  let observations = ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_WINDOW_OBSERVATIONS"],
                  !observations.isEmpty else {
                throw Failure(message: "Synthetic keys require a fresh external window observer and no active registration")
            }
            guard exactSeconds(20), initial["pending-frames"] == 0,
                  state()["paused"] as? Bool == true, state()["muted"] as? Bool == true,
                  !(state()["tracks"] as? [[String: Any]] ?? []).contains(where: {
                      $0["type"] as? String == "sub" && $0["selected"] as? Bool == true
                  }) else { throw Failure(message: "Synthetic keyboard setup is not the paused muted subtitle-off exact twenty-second control") }
            let sessionID = UUID().uuidString
            var sequence = 0
            var dispatchReceipts: [[String: Any]] = []
            var temporaryField: NSTextField?
            func phase(_ name: String) throws {
                try checkCaptureDeadline()
                let deadline = min(keyDeadline, ProcessInfo.processInfo.systemUptime + 15)
                keyStageDeadline = deadline
                snapshots.append(["check": "synthetic-key-phase-" + name, "hostSeconds": ProcessInfo.processInfo.systemUptime,
                    "sessionID": sessionID, "overallDeadlineUptime": keyDeadline,
                    "stageDeadlineUptime": deadline])
            }
            try phase("right-seek")
            let panel = try await enter("synthetic keyboard floating entry")
            let panelNumber = panel.windowNumber
            defer {
                PlayerSyntheticKeyReceipt.active = nil
                if let field = temporaryField {
                    panel.endEditing(for: field)
                    if panel.contentView != nil { _ = panel.makeFirstResponder(nil) }
                    field.removeFromSuperview()
                }
            }
            try await preserved(initial, "paused before synthetic keyboard dispatch")
            func settings() -> NSDictionary {
                let current = state(), processing = current["processing"] as? [String: Any] ?? [:]
                var result = Dictionary(uniqueKeysWithValues:
                    ["muted", "volume", "subtitleScale", "subtitleDelay", "nativeSubtitleColor", "tracks"].map {
                        ($0, current[$0] ?? NSNull())
                    })
                let keys = ["enabled", "mode", "width", "height", "strength", "colorStrength", "subtitleBrightness", "comparison"]
                result["processing"] = Dictionary(uniqueKeysWithValues: keys.map { ($0, processing[$0] ?? NSNull()) })
                return result as NSDictionary
            }
            let initialSettings = settings()
            func sameSettings() -> Bool { settings().isEqual(initialSettings) }
            func focus() -> [String: Any] {
                let responder = panel.firstResponder
                let view = responder as? NSView
                return ["targetWindowNumber": panel.windowNumber,
                    "targetWindowIdentity": String(describing: ObjectIdentifier(panel)),
                    "targetIsKey": panel.isKeyWindow, "targetVisible": panel.isVisible,
                    "targetOnActiveSpace": panel.isOnActiveSpace,
                    "targetOcclusionVisible": panel.occlusionState.contains(.visible),
                    "targetNonactivatingPanel": panel.styleMask.contains(.nonactivatingPanel),
                    "applicationActive": NSApp.isActive,
                    "keyWindowNumber": NSApp.keyWindow.map { $0.windowNumber as Any } ?? NSNull(),
                    "keyWindowIdentity": NSApp.keyWindow.map { String(describing: ObjectIdentifier($0)) as Any } ?? NSNull(),
                    "firstResponderIdentity": responder.map { String(describing: ObjectIdentifier($0)) as Any } ?? NSNull(),
                    "firstResponderClass": responder.map { String(describing: type(of: $0)) as Any } ?? NSNull(),
                    "firstResponderIsWindow": responder === panel,
                    "firstResponderIsNSControl": responder is NSControl,
                    "firstResponderIsNSTextView": responder is NSTextView,
                    "firstResponderIsControlsDescendant": view?.isDescendant(of: webView) ?? false]
            }
            func ownedEditorState() -> Any {
                guard let field = temporaryField, let editor = field.currentEditor() as? NSTextView else { return NSNull() }
                let selection = editor.selectedRange()
                let known = ["ab", "a b"]
                return ["fieldIdentity": String(describing: ObjectIdentifier(field)),
                    "editorIdentity": String(describing: ObjectIdentifier(editor)),
                    "editorIsActualFirstResponder": panel.firstResponder === editor,
                    "editorIsEditable": editor.isEditable,
                    "editorString": known.contains(editor.string) ? editor.string as Any : NSNull(),
                    "editorStringIsKnown": known.contains(editor.string),
                    "selectedRange": ["location": selection.location, "length": selection.length],
                    "fieldStringValue": known.contains(field.stringValue) ? field.stringValue as Any : NSNull(),
                    "fieldStringValueIsKnown": known.contains(field.stringValue),
                    "textScope": "Only known owned diagnostic strings are retained; NSTextField value may lag its field editor."]
            }
            func context() -> [String: Any] {
                ["ownedEditor": ownedEditorState(), "nativePID": Int(ProcessInfo.processInfo.processIdentifier), "focus": focus(),
                 "identity": identity().map { $0 as Any } ?? NSNull(),
                 "paused": state()["paused"] ?? NSNull(), "playing": state()["playing"] ?? NSNull(),
                 "source": state()["source"] ?? NSNull(), "coreLibrary": state()["coreLibrary"] ?? NSNull(),
                 "configurationID": state()["configurationID"] ?? NSNull(),
                 "hostIdentity": String(describing: ObjectIdentifier(video)),
                 "hostWindowNumber": video.window.map { $0.windowNumber as Any } ?? NSNull()]
            }
            func requireFocus(_ expected: NSResponder) throws {
                try checkCaptureDeadline()
                guard panel.windowNumber == panelNumber, panel.isKeyWindow, NSApp.keyWindow === panel,
                      panel.firstResponder === expected, panel.styleMask.contains(.nonactivatingPanel),
                      panel.isVisible, !panel.isMiniaturized, panel.isOnActiveSpace,
                      panel.occlusionState.contains(.visible), video.window === panel,
                      sameSettings() else { throw Failure(message: "Actual synthetic-key target or focus is not ready") }
            }
            func windowFocus() throws {
                try checkCaptureDeadline()
                guard panel.makeFirstResponder(nil), panel.firstResponder === panel else {
                    throw Failure(message: "Panel refused window first-responder focus; no settings were changed")
                }
                try requireFocus(panel)
            }
            func dispatch(_ name: String, code: UInt16, characters: String, responder: NSResponder,
                          consumed: Bool, command expectedCommand: String?, value expectedValue: Any?) async throws -> [String: Any] {
                let label = "native-key-" + name + "-requested"
                try requireFocus(responder)
                try await observeWindowBeforeAction(panel, requestLabel: label)
                try requireFocus(responder)
                if let editor = responder as? NSTextView {
                    guard temporaryField?.currentEditor() === editor, editor.string == "ab",
                          editor.selectedRange() == NSRange(location: 1, length: 0) else {
                        throw Failure(message: "Owned editor changed before synthetic Space dispatch")
                    }
                }
                guard PlayerSyntheticKeyReceipt.active == nil,
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panelNumber, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code),
                      event.window === panel else { throw Failure(message: "Cannot register an exact owned synthetic key event") }
                sequence += 1
                let probe = PlayerSyntheticKeyReceipt(event: event, eventID: UUID().uuidString,
                    sessionID: sessionID, sequence: sequence, context: context)
                let registration = probe.registration
                snapshots.append(["check": label, "hostSeconds": ProcessInfo.processInfo.systemUptime,
                    "actionWindowNumber": panelNumber, "eventID": probe.eventID, "sessionID": sessionID,
                    "sequence": sequence, "registeredEvent": registration, "focus": focus(), "state": state()])
                try checkCaptureDeadline()
                PlayerSyntheticKeyReceipt.active = probe
                defer { PlayerSyntheticKeyReceipt.active = nil }
                let began = ProcessInfo.processInfo.systemUptime
                NSApp.sendEvent(event)
                let ended = ProcessInfo.processInfo.systemUptime
                PlayerSyntheticKeyReceipt.active = nil
                let receipt: [String: Any] = [
                    "check": label + "-dispatch-returned", "hostSeconds": ended,
                    "eventID": probe.eventID, "sessionID": sessionID, "sequence": sequence,
                    "actionWindowNumber": panelNumber, "registeredEvent": registration,
                    "sendEventStartedUptime": began, "sendEventReturnedUptime": ended,
                    "monitorArrivalCount": probe.arrivalCount, "monitorReturnCount": probe.returnCount,
                    "commandCount": probe.commandCount, "monitorBefore": probe.arrivals,
                    "monitorAfter": probe.returns, "commands": probe.commands,
                    "expectedConsumed": consumed, "afterContext": context(), "state": state(),
                    "scope": "Registered in-process NSApp.sendEvent injection; no WindowServer, physical input or queue-retrieval proof."]
                snapshots.append(receipt)
                dispatchReceipts.append(receipt)
                try checkCaptureDeadline()
                guard probe.arrivalCount == 1, probe.returnCount == 1,
                      let arrival = probe.arrivals.first,
                      arrival["resolvedEventWindowNumber"] as? Int == panelNumber,
                      arrival["resolvedEventWindowIdentity"] as? String == String(describing: ObjectIdentifier(panel)),
                      arrival["eventWindowNumber"] as? Int == panelNumber,
                      let arrivalContext = arrival["context"] as? [String: Any],
                      let arrivalFocus = arrivalContext["focus"] as? [String: Any],
                      arrivalFocus["targetWindowNumber"] as? Int == panelNumber,
                      arrivalFocus["keyWindowIdentity"] as? String == String(describing: ObjectIdentifier(panel)),
                      arrivalFocus["firstResponderIdentity"] as? String == String(describing: ObjectIdentifier(responder)),
                      probe.returns.first?["consumed"] as? Bool == consumed else {
                    throw Failure(message: "Synthetic event did not traverse the original local key monitor exactly once as expected")
                }
                if let expectedCommand, let expectedValue {
                    guard probe.commandCount == 1, probe.commands.first?["command"] as? String == expectedCommand,
                          let actual = probe.commands.first?["value"],
                          NSDictionary(dictionary: ["value": actual]).isEqual(to: ["value": expectedValue]) else {
                        throw Failure(message: "Synthetic event has no matching actual handler command receipt")
                    }
                } else if probe.commandCount != 0 {
                    throw Failure(message: "Focused control/text event unexpectedly invoked a player shortcut")
                }
                return receipt
            }
            func settled(_ receipt: [String: Any], _ expected: [String: Int64], text: String? = nil) async throws {
                try await preserved(expected, "synthetic key " + String(describing: receipt["sequence"]!) + " settles")
                try checkCaptureDeadline()
                guard sameSettings() else { throw Failure(message: "Synthetic key changed unrelated settings") }
                var row: [String: Any] = ["check": (receipt["check"] as! String).replacingOccurrences(of: "-dispatch-returned", with: "-settled"),
                    "hostSeconds": ProcessInfo.processInfo.systemUptime,
                    "eventID": receipt["eventID"]!, "sessionID": sessionID, "sequence": receipt["sequence"]!,
                    "actionWindowNumber": panelNumber, "identity": expected, "context": context(), "state": state()]
                if let text {
                    guard let editor = temporaryField?.currentEditor() as? NSTextView,
                          panel.firstResponder === editor, editor.string == text,
                          editor.selectedRange() == NSRange(location: 2, length: 0) else {
                        throw Failure(message: "Owned field editor text or selection changed before settled receipt")
                    }
                    row["verifiedOwnedFieldText"] = text
                }
                snapshots.append(row)
            }
            try windowFocus()
            let right = try await dispatch("seekRight", code: 124, characters: "\u{F703}", responder: panel,
                consumed: true, command: "seek", value: Double(25))
            try await floatingWait("synthetic Right Arrow reaches exact paused twenty-five-second frame") {
                exactSeconds(25) && self.state()["paused"] as? Bool == true &&
                    integer(native(), "generation") > (initial["generation"] ?? Int64.max) &&
                    integer(native(), "displayed-generation") == integer(native(), "generation")
            }
            let held = try await settle("synthetic Right Arrow completes paused replacement")
            guard held["submitted-frames"] == (initial["submitted-frames"] ?? 0) + 1,
                  held["completed-frames"] == (initial["completed-frames"] ?? 0) + 1,
                  held["pending-frames"] == 0 else { throw Failure(message: "Synthetic Right Arrow did not produce exactly one accepted/emitted replacement") }
            try await settled(right, held)

            try phase("focused-button")
            guard let content = panel.contentView, let control = button("return", in: content),
                  control.isEnabled, !control.isHidden, panel.makeFirstResponder(control),
                  panel.firstResponder === control else {
                throw Failure(message: "Existing button cannot receive actual focus under current settings")
            }
            let buttonEvent = try await dispatch("focusedButtonRight", code: 124, characters: "\u{F703}", responder: control,
                consumed: false, command: nil, value: nil)
            try await settled(buttonEvent, held)

            try phase("field-editor")
            let field = NSTextField(string: "ab")
            field.identifier = NSUserInterfaceItemIdentifier("HDRPlayer.syntheticKeyField")
            field.setAccessibilityLabel("Synthetic key diagnostic field")
            field.frame = NSRect(x: 8, y: 52, width: 120, height: 24)
            panel.contentView?.addSubview(field)
            temporaryField = field
            guard panel.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView,
                  panel.firstResponder === editor, editor.window === panel, editor.isEditable else {
                throw Failure(message: "Owned diagnostic field editor did not become the actual first responder")
            }
            editor.setSelectedRange(NSRange(location: 1, length: 0))
            guard editor.string == "ab", editor.selectedRange() == NSRange(location: 1, length: 0) else {
                throw Failure(message: "Owned diagnostic editor did not retain its known initial text and insertion selection")
            }
            let textEvent = try await dispatch("fieldEditorSpace", code: 49, characters: " ", responder: editor,
                consumed: false, command: nil, value: nil)
            guard editor.string == "a b", editor.selectedRange() == NSRange(location: 2, length: 0) else {
                throw Failure(message: "Synthetic Space was not inserted at the owned field editor selection")
            }
            try await settled(textEvent, held, text: "a b")
            try windowFocus()
            panel.endEditing(for: field)
            field.removeFromSuperview()
            guard field.superview == nil, field.window == nil, field.currentEditor() == nil else {
                throw Failure(message: "Owned diagnostic text field did not detach before Escape")
            }
            temporaryField = nil
            snapshots.append(["check": "synthetic-key-field-cleanup", "hostSeconds": ProcessInfo.processInfo.systemUptime,
                "sessionID": sessionID, "fieldDetached": true, "fieldEditingEnded": true, "context": context()])

            try phase("escape-return")
            try windowFocus()
            let escape = try await dispatch("escapeReturn", code: 53, characters: "\u{1B}", responder: panel,
                consumed: true, command: "restoreFloating", value: true)
            try await returned(panel, "synthetic Escape restores the same host to main", minimized: false)
            guard (floating()["lastRestore"] as? [String: Any])?["activateMain"] as? Bool == true else {
                throw Failure(message: "Synthetic Escape did not request explicit main restoration")
            }
            try await settled(escape, held)
            try phase("final-floating-teardown")
            _ = try await enter("floating entry before asynchronous quit")
            try await preserved(held, "paused active floating host before asynchronous quit")
            try checkCaptureDeadline()
            guard sequence == 4, dispatchReceipts.count == 4, PlayerSyntheticKeyReceipt.active == nil,
                  temporaryField == nil else { throw Failure(message: "Synthetic key diagnostic did not cleanly finish four registered events") }
            checks.append("four registered NSApp.sendEvent key events prove local monitor consumption, focused-control forwarding and correlated transport; physical input remains unqualified")
            return
        }
        if let directory = spaceDirectory {
            let sessionID = UUID().uuidString, pid = Int(ProcessInfo.processInfo.processIdentifier)
            let panel = try await enter("Space diagnostic floating entry")
            try await preserved(initial, "paused before owned helper Space transition")
            let panelNumber = panel.windowNumber, mainNumber = window.windowNumber
            var helperBinding: [String: Any]?
            var helperReferenceBytes: Data?
            var stage = 0, sampleIndex = 0
            var workspaceEvents: [[String: Any]] = []
            var stageWorkspaceCount = 0
            var receiptBytes: [Int: Data] = [:]
            var receiptRecords: [Int: [String: Any]] = [:]
            var commandBytes: [Int: Data] = [:]
            var commandIssued: [Int: Double] = [:]
            var stageHashes: [Int: String] = [:]
            let initialHostBounds = video.bounds, initialDrawable = metal.drawableSize, initialScale = metal.contentsScale
            func settings() -> NSDictionary {
                let current = state(), processing = current["processing"] as? [String: Any] ?? [:]
                let keys = ["muted", "volume", "subtitleScale", "subtitleDelay", "nativeSubtitleColor", "tracks"]
                var result = Dictionary(uniqueKeysWithValues: keys.map { ($0, current[$0] ?? NSNull()) })
                let processingKeys = ["enabled", "mode", "width", "height", "strength", "colorStrength", "subtitleBrightness", "comparison"]
                result["processing"] = Dictionary(uniqueKeysWithValues: processingKeys.map { ($0, processing[$0] ?? NSNull()) })
                return result as NSDictionary
            }
            let initialSettings = settings()
            func windowSample(_ target: NSWindow) -> [String: Any] {
                ["number": target.windowNumber, "visible": target.isVisible, "onActiveSpace": target.isOnActiveSpace,
                 "occlusionVisible": target.occlusionState.contains(.visible), "minimized": target.isMiniaturized,
                 "fullscreen": target.styleMask.contains(.fullScreen),
                 "frame": ["x": target.frame.minX, "y": target.frame.minY, "width": target.frame.width, "height": target.frame.height]]
            }
            func held() throws -> [String: Any] {
                try checkCaptureDeadline(); try checkObjects("owned helper Space hold")
                guard identity() == initial, initial["pending-frames"] == 0,
                      state()["paused"] as? Bool == true, state()["playing"] as? Bool == false,
                      native()["compare-ready"] as? Bool == true, native()["preview-pending"] as? Bool == false,
                      settings().isEqual(initialSettings), video.window === panel, panel.windowNumber == panelNumber,
                      window.windowNumber == mainNumber, floating()["active"] as? Bool == true,
                      floating()["phase"] as? String == "floating", integer(floating(), "homeConstraintsActive") == 0,
                      integer(floating(), "floatingConstraintsActive") == 4,
                      !window.styleMask.contains(.fullScreen), floating()["mainFullscreenTransitioning"] as? Bool == false,
                      video.bounds == initialHostBounds, metal.drawableSize == initialDrawable, metal.contentsScale == initialScale else {
                    throw Failure(message: "Space transition changed paused state, settings, ownership or native geometry")
                }
                return ["identity": initial, "settings": initialSettings, "source": source, "core": core,
                    "configuration": configuration, "hostIdentity": String(describing: ObjectIdentifier(video)),
                    "hostBounds": ["x": video.bounds.minX, "y": video.bounds.minY, "width": video.bounds.width, "height": video.bounds.height],
                    "drawableSize": ["width": metal.drawableSize.width, "height": metal.drawableSize.height], "contentsScale": metal.contentsScale,
                    "children": children.map { String(describing: ObjectIdentifier($0)) },
                    "layers": layers.map { String(describing: ObjectIdentifier($0)) },
                    "mainWindow": windowSample(window), "floatingWindow": windowSample(panel),
                    "frontmostPID": NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) } ?? -1,
                    "workspaceChangeCount": workspaceEvents.count]
            }
            func json(_ value: [String: Any]) throws -> Data {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                guard data.count <= 65_536 else { throw Failure(message: "Space protocol document exceeds 64 KiB") }
                return data
            }
            func read(_ name: String) throws -> ([String: Any], Data) {
                let url = directory.appendingPathComponent(name)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 65_536 else {
                    throw Failure(message: "Invalid Space protocol file: " + name)
                }
                let data = try Data(contentsOf: url)
                guard data.count <= 65_536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw Failure(message: "Invalid Space protocol JSON: " + name)
                }
                return (object, data)
            }
            func immutable(_ value: [String: Any], _ name: String) throws -> String {
                let data = try json(value), temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
                try data.write(to: temporary, options: .withoutOverwriting)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.linkItem(at: temporary, to: directory.appendingPathComponent(name))
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            let callbacks = FloatingSpaceSmokeCallbacks(window: window) {
                let row: [String: Any] = ["check": "NSWorkspace.activeSpaceDidChange", "hostSeconds": ProcessInfo.processInfo.systemUptime,
                    "eventIndex": workspaceEvents.count, "mainWindow": windowSample(self.window),
                    "floatingWindow": windowSample(panel), "frontmostPID": NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) } ?? -1]
                workspaceEvents.append(row); self.snapshots.append(row)
            }
            defer { callbacks.stop() }
            let binding: [String: Any] = ["version": 1, "sessionID": sessionID, "playerPID": pid,
                "mainWindowID": mainNumber, "panelWindowID": panelNumber]
            var reference = binding
            reference["createdUptime"] = ProcessInfo.processInfo.systemUptime; reference["overallDeadlineUptime"] = spaceDeadline
            reference["sample"] = try held()
            let referenceSHA = try immutable(reference, "player-reference.json")
            let originalReferenceBytes = try read("player-reference.json").1
            spaceStageDeadline = min(spaceDeadline, ProcessInfo.processInfo.systemUptime + 15)
            defer { spaceStageDeadline = nil }
            func liveSample() throws -> [String: Any] {
                let sample = try held()
                sampleIndex += 1
                var live = binding
                live["playerReferenceSHA256"] = referenceSHA; live["stage"] = stage
                live["sampleIndex"] = sampleIndex; live["observedUptime"] = ProcessInfo.processInfo.systemUptime
                live["stageDeadlineUptime"] = spaceStageDeadline; live["sample"] = sample
                live["workspaceEvents"] = workspaceEvents
                try json(live).write(to: directory.appendingPathComponent("player-live.json"), options: .atomic)
                try checkCaptureDeadline()
                return live
            }
            func panelPositive() -> Bool {
                panel.isVisible && panel.isOnActiveSpace && panel.occlusionState.contains(.visible) && !panel.isMiniaturized
            }
            while true {
                try checkCaptureDeadline()
                guard workspaceEvents.count <= 32, try read("player-reference.json").1 == originalReferenceBytes else {
                    throw Failure(message: "Space event bound exceeded or immutable player reference changed")
                }
                var live = try liveSample()
                if helperBinding == nil, FileManager.default.fileExists(atPath: directory.appendingPathComponent("helper-reference.json").path) {
                    let (helper, bytes) = try read("helper-reference.json")
                    guard helper["version"] as? Int == 1, helper["sessionID"] as? String == sessionID,
                          helper["playerPID"] as? Int == pid, helper["playerReferenceSHA256"] as? String == referenceSHA,
                          helper["bundleID"] as? String == "dev.scripttype.FloatingSpaceReference",
                          let helperPID = helper["helperPID"] as? Int, helperPID > 0, helperPID != pid,
                          let helperWindow = helper["helperWindowID"] as? Int, helperWindow > 0,
                          helperWindow != mainNumber, helperWindow != panelNumber else { throw Failure(message: "Unbound helper reference") }
                    helperBinding = Dictionary(uniqueKeysWithValues: ["version", "sessionID", "playerPID", "playerReferenceSHA256", "helperPID", "helperWindowID"].map { ($0, helper[$0]!) })
                    helperReferenceBytes = bytes
                }
                if let helperBinding, let helperReferenceBytes {
                    guard try read("helper-reference.json").1 == helperReferenceBytes else { throw Failure(message: "Immutable helper reference changed") }
                    let helperPID = helperBinding["helperPID"] as! Int
                    func helperFrontmost() -> Bool {
                        NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) } == helperPID
                    }
                    // Resample after binding the helper; never prove a stage from a pre-receipt sample.
                    live = try liveSample()
                    if stage == 0, panelPositive(), window.isOnActiveSpace, helperFrontmost() {
                        let nextDeadline = min(spaceDeadline, ProcessInfo.processInfo.systemUptime + 15)
                        var proof = live; proof["helperBinding"] = helperBinding; proof["stageName"] = "helper-normal"
                        proof["nextStageDeadlineUptime"] = nextDeadline
                        try checkCaptureDeadline()
                        stageHashes[0] = try immutable(proof, "player-stage-0.json")
                        try checkCaptureDeadline()
                        stageWorkspaceCount = workspaceEvents.count; stage = 1; spaceStageDeadline = nextDeadline
                    }
                    for (number, bytes) in receiptBytes {
                        guard try read("helper-receipt-\(number).json").1 == bytes,
                              try read("helper-command-\(number).json").1 == commandBytes[number] else {
                            throw Failure(message: "Accepted helper receipt or command changed")
                        }
                    }
                    if stage >= 1 && stage <= 3 {
                        if stage < 3, FileManager.default.fileExists(atPath: directory.appendingPathComponent("helper-receipt-\(stage + 1).json").path) {
                            throw Failure(message: "Helper advanced before the player witnessed the current Space")
                        }
                        let name = "helper-receipt-\(stage).json"
                        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
                            if receiptRecords[stage] == nil {
                                let (receipt, bytes) = try read(name)
                                let (command, bytesOfCommand) = try read("helper-command-\(stage).json")
                                let now = ProcessInfo.processInfo.systemUptime
                                let action = ["enter-fullscreen", "exit-fullscreen", "finish"][stage - 1]
                                guard helperBinding.allSatisfy({ (receipt[$0.key] as? NSObject)?.isEqual($0.value) == true }),
                                      helperBinding.allSatisfy({ (command[$0.key] as? NSObject)?.isEqual($0.value) == true }),
                                      receipt["sequence"] as? Int == stage, receipt["action"] as? String == action,
                                      command["sequence"] as? Int == stage, command["action"] as? String == action,
                                      let nonce = command["nonce"] as? String, UUID(uuidString: nonce) != nil,
                                      receipt["nonce"] as? String == nonce,
                                      receipt["commandSHA256"] as? String == SHA256.hash(data: bytesOfCommand).map({ String(format: "%02x", $0) }).joined(),
                                      command["playerStageSHA256"] as? String == stageHashes[stage - 1],
                                      receipt["completed"] as? Bool == true,
                                      let issued = command["issuedUptime"] as? Double, issued.isFinite,
                                      let completed = receipt["completedUptime"] as? Double, completed.isFinite,
                                      issued <= completed, completed <= now, now - completed <= 2 else {
                                    throw Failure(message: "Stale or unbound helper receipt")
                                }
                                if stage < 3 {
                                    let expected = stage == 1 ? ["will-enter", "did-enter"] : ["will-exit", "did-exit"]
                                    guard receipt["callbacks"] as? [String] == expected,
                                          (receipt["workspaceCountAfter"] as? Int ?? 0) > (receipt["workspaceCountBefore"] as? Int ?? Int.max) else {
                                        throw Failure(message: "Helper lacks actual fullscreen or Space-change callbacks")
                                    }
                                }
                                receiptBytes[stage] = bytes; receiptRecords[stage] = receipt; commandBytes[stage] = bytesOfCommand
                                commandIssued[stage] = issued
                            }
                            // Accepted bytes remain pinned while the post-transition state settles.
                            // Freshness applies at initial acceptance, not on every later tick.
                            live = try liveSample()
                            if stage < 3, panelPositive(), helperFrontmost(), window.isOnActiveSpace == (stage == 2),
                               workspaceEvents.count > stageWorkspaceCount,
                               workspaceEvents.contains(where: { event in
                                   guard let observed = event["hostSeconds"] as? Double else { return false }
                                   return observed >= commandIssued[stage]! && observed <= (live["observedUptime"] as! Double)
                               }) {
                                let nextDeadline = min(spaceDeadline, ProcessInfo.processInfo.systemUptime + 15)
                                var proof = live; proof["helperBinding"] = helperBinding
                                proof["helperReceiptSHA256"] = SHA256.hash(data: receiptBytes[stage]!).map { String(format: "%02x", $0) }.joined()
                                proof["stageName"] = stage == 1 ? "helper-fullscreen" : "helper-returned"
                                proof["nextStageDeadlineUptime"] = nextDeadline
                                try checkCaptureDeadline()
                                stageHashes[stage] = try immutable(proof, "player-stage-\(stage).json")
                                try checkCaptureDeadline()
                                stageWorkspaceCount = workspaceEvents.count; stage += 1; spaceStageDeadline = nextDeadline
                            }
                        }
                    }
                    let acknowledgementPath = directory.appendingPathComponent("player-complete.json")
                    if FileManager.default.fileExists(atPath: acknowledgementPath.path) {
                        let (ack, _) = try read("player-complete.json")
                        guard stage == 3, receiptBytes.count == 3, stageHashes.count == 3,
                              helperBinding.allSatisfy({ (ack[$0.key] as? NSObject)?.isEqual($0.value) == true }),
                              ack["verified"] as? Bool == true, ack["helperExitCode"] as? Int == 0,
                              panelPositive(), window.isOnActiveSpace else { throw Failure(message: "Premature or invalid final Space acknowledgement") }
                        for number in 0...2 {
                            guard ack["playerStage\(number)SHA256"] as? String == stageHashes[number] else { throw Failure(message: "Final Space stage hash mismatch") }
                        }
                        for number in 1...3 {
                            let sha = SHA256.hash(data: receiptBytes[number]!).map { String(format: "%02x", $0) }.joined()
                            guard ack["helperReceipt\(number)SHA256"] as? String == sha else { throw Failure(message: "Final helper receipt hash mismatch") }
                        }
                        let finalSample = try held()
                        guard panelPositive(), window.isOnActiveSpace else { throw Failure(message: "Space membership changed before final receipt") }
                        try checkCaptureDeadline()
                        var after = binding; after["playerReferenceSHA256"] = referenceSHA
                        after["observedUptime"] = ProcessInfo.processInfo.systemUptime; after["sample"] = finalSample
                        after["workspaceEvents"] = workspaceEvents; after["acknowledgement"] = ack
                        after["scope"] = "Observed helper fullscreen Space roundtrip; external coordinator verifies window queries and helper exit. No pixel, arbitrary desktop-ID or physical qualification."
                        _ = try immutable(after, "player-after.json")
                        try checkCaptureDeadline()
                        snapshots.append(["check": "owned helper Space roundtrip completed", "hostSeconds": ProcessInfo.processInfo.systemUptime,
                            "receipt": after, "state": state()])
                        checks.append("same paused floating panel survives an observed other-application fullscreen Space roundtrip")
                        checks.append("paused active floating host retained for external asynchronous teardown")
                        return
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        if fullscreenDiagnostic {
            // Exercise real AppKit callbacks; no physical key/titlebar/Space claim.
            var callbackRows: [[String: Any]] = []
            var callbackFailure: String?
            var expectedEvents: [String] = []
            var receivedEvents: [String] = []
            var route = ""
            var detachedPanel: NSPanel?
            func fullscreenMenu(in menu: NSMenu) -> (NSMenu, Int)? {
                for (index, item) in menu.items.enumerated() {
                    if item.action == NSSelectorFromString("toggleFullscreen") { return (menu, index) }
                    if let submenu = item.submenu, let found = fullscreenMenu(in: submenu) { return found }
                }
                return nil
            }
            func checkHome(_ label: String) throws {
                try checkObjects(label)
                guard identity() == initial, self.state()["paused"] as? Bool == true,
                      native()["compare-ready"] as? Bool == true, native()["preview-pending"] as? Bool == false,
                      video.superview === home, video.window === window,
                      floating()["active"] as? Bool == false, floating()["phase"] as? String == "home",
                      integer(floating(), "homeConstraintsActive") == 4, integer(floating(), "floatingConstraintsActive") == 0,
                      let panel = detachedPanel, !panel.isVisible, panel.contentView == nil else {
                    throw Failure(message: "Fullscreen changed the held identity or failed to detach its panel: " + label)
                }
            }
            let settingsKeys = ["muted", "volume", "subtitleScale", "subtitleDelay", "nativeSubtitleColor", "tracks"]
            let processingKeys = ["enabled", "mode", "width", "height", "strength", "colorStrength", "subtitleBrightness", "comparison"]
            func settings() -> NSDictionary {
                let current = state(), processing = current["processing"] as? [String: Any] ?? [:]
                var result = Dictionary(uniqueKeysWithValues: settingsKeys.map { ($0, current[$0] ?? NSNull()) })
                result["processing"] = Dictionary(uniqueKeysWithValues: processingKeys.map { ($0, processing[$0] ?? NSNull()) })
                return result as NSDictionary
            }
            let initialSettings = settings()
            let callbacks = FloatingFullscreenSmokeCallbacks(window: window) { event in
                let now = ProcessInfo.processInfo.systemUptime
                let row: [String: Any] = ["check": "fullscreen-delegate-" + event, "hostSeconds": now,
                    "route": route, "event": event, "callbackIndex": callbackRows.count,
                    "actualFullscreen": self.window.styleMask.contains(.fullScreen), "state": self.state()]
                callbackRows.append(row)
                self.snapshots.append(row)
                do {
                    try checkCaptureDeadline()
                    guard receivedEvents.count < expectedEvents.count,
                          expectedEvents[receivedEvents.count] == event else {
                        throw Failure(message: "Unexpected, duplicate or failed fullscreen callback: " + event)
                    }
                    receivedEvents.append(event)
                    try checkHome(event)
                    guard settings().isEqual(initialSettings),
                          let main = NSApp.mainMenu, let (menu, index) = menuEntry(main) else {
                        throw Failure(message: "Fullscreen callback changed settings or lost the floating menu")
                    }
                    menu.update()
                    let transitioning = event.hasPrefix("will-")
                    let blocked = transitioning || event == "did-enter"
                    guard floating()["mainFullscreenTransitioning"] as? Bool == transitioning,
                          floating()["canEnter"] as? Bool == !blocked, menu.items[index].isEnabled == !blocked,
                          transitioning || self.window.styleMask.contains(.fullScreen) == (event == "did-enter") else {
                        throw Failure(message: "Floating entry guard disagrees with actual fullscreen callback: " + event)
                    }
                    self.checks.append("actual " + event + " callback preserves held state and correct floating-entry availability")
                } catch {
                    if callbackFailure == nil { callbackFailure = error.localizedDescription }
                }
            }
            defer { callbacks.stop() }
            func transition(_ selectedRoute: String, entering: Bool, panel: NSPanel) async throws {
                fullscreenStageDeadline = min(fullscreenDeadline, ProcessInfo.processInfo.systemUptime + 15)
                defer { fullscreenStageDeadline = nil }
                try checkCaptureDeadline()
                route = selectedRoute
                detachedPanel = panel
                expectedEvents = entering ? ["will-enter", "did-enter"] : ["will-exit", "did-exit"]
                receivedEvents = []
                let operation = entering ? "enter" : "exit"
                let label = selectedRoute == "menu-shared-handler"
                    ? "fullscreen-menu-" + operation + "-menu-requested"
                    : "fullscreen-direct-" + operation + "-window-requested"
                try await observeWindowBeforeAction(window, requestLabel: label)
                try checkCaptureDeadline()
                guard settings().isEqual(initialSettings), identity() == initial,
                      self.window.styleMask.contains(.fullScreen) != entering else {
                    throw Failure(message: "Unexpected held state before fullscreen request")
                }
                snapshots.append(["check": label, "hostSeconds": ProcessInfo.processInfo.systemUptime,
                    "route": selectedRoute, "entering": entering, "actionWindowNumber": window.windowNumber, "state": state()])
                if selectedRoute == "menu-shared-handler" {
                    guard let main = NSApp.mainMenu, let (menu, index) = fullscreenMenu(in: main) else {
                        throw Failure(message: "Native fullscreen menu is unavailable")
                    }
                    menu.update()
                    guard menu.items[index].isEnabled else { throw Failure(message: "Native fullscreen menu is disabled") }
                    menu.performActionForItem(at: index)
                } else {
                    window.toggleFullScreen(nil)
                }
                try await floatingWait(selectedRoute + " " + operation + " completes actual fullscreen callbacks", seconds: 15) {
                    callbackFailure != nil || receivedEvents == expectedEvents
                }
                if let callbackFailure { throw Failure(message: callbackFailure) }
                try checkCaptureDeadline()
                try checkHome(selectedRoute + " " + operation)
                try await preserved(initial, selectedRoute + " " + operation + " settles paused identity")
                guard settings().isEqual(initialSettings) else {
                    throw Failure(message: "Fullscreen changed native playback or processing settings")
                }
            }
            let firstPanel = try await enter("fullscreen shared-handler floating entry")
            try await preserved(initial, "paused before shared fullscreen handler")
            try await transition("menu-shared-handler", entering: true, panel: firstPanel)
            try await transition("menu-shared-handler", entering: false, panel: firstPanel)
            let secondPanel = try await enter("fullscreen direct-callback floating re-entry")
            try await preserved(initial, "paused before direct fullscreen callback")
            try await transition("direct-appkit-api", entering: true, panel: secondPanel)
            try await transition("direct-appkit-api", entering: false, panel: secondPanel)
            guard callbackRows.count == 8 else { throw Failure(message: "Expected eight actual fullscreen callbacks") }
            _ = try await enter("floating entry before asynchronous quit")
            try await preserved(initial, "paused active floating host before asynchronous quit")
            try checkCaptureDeadline()
            if let callbackFailure { throw Failure(message: callbackFailure) }
            guard callbackRows.count == 8 else { throw Failure(message: "Unexpected fullscreen callback during final floating re-entry") }
            checks.append("both fullscreen routes restore and preserve the same paused native host; external asynchronous teardown remains required")
            return
        }
        if let directory = captureDirectory {
            // Caller-coordinated compositor diagnostic only: the application never captures pixels.
            let sessionID = UUID().uuidString, pid = Int(ProcessInfo.processInfo.processIdentifier)
            guard NSScreen.screens.count == 1, let screen = window.screen, screen.frame.origin == .zero,
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  screen.backingScaleFactor.isFinite, screen.backingScaleFactor > 0 else {
                throw Failure(message: "Capture requires one display with an unambiguous zero-origin coordinate space")
            }
            let scale = screen.backingScaleFactor
            let screenFrame = screen.frame, visibleFrame = screen.visibleFrame
            let viewport = NSSize(width: 800, height: 480)
            func rect(_ value: NSRect) -> [String: CGFloat] {
                ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
            }
            func serverRect(_ value: NSRect) -> [String: CGFloat] {
                ["X": value.minX, "Y": screenFrame.maxY - value.maxY, "Width": value.width, "Height": value.height]
            }
            func json(_ value: [String: Any]) throws -> Data {
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                guard data.count <= 65_536 else { throw Failure(message: "Capture protocol document exceeds 64 KiB") }
                return data
            }
            func immutable(_ data: Data, at destination: URL) throws {
                // Publish complete bytes without replacing an existing reference, acknowledgement or receipt.
                let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
                try data.write(to: temporary, options: .withoutOverwriting)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            func geometryReady(_ target: NSWindow) -> Bool {
                target === self.video.window && self.video.bounds.size == viewport &&
                    self.video.convertToBacking(self.video.bounds).size == NSSize(width: 800 * scale, height: 480 * scale) &&
                    children.allSatisfy { $0.bounds.size == viewport && $0.convert($0.bounds, to: self.video) == self.video.bounds &&
                        $0.convertToBacking($0.bounds).size == NSSize(width: 800 * scale, height: 480 * scale) } &&
                    metal.bounds.size == viewport && metal.contentsScale == scale &&
                    metal.drawableSize == NSSize(width: 800 * scale, height: 480 * scale)
            }
            func fitViewport(_ target: NSWindow, _ phase: String) async throws {
                guard let content = target.contentView else { throw Failure(message: "Missing capture window content") }
                content.layoutSubtreeIfNeeded()
                let measured = video.bounds.size
                target.setContentSize(NSSize(width: content.bounds.width + viewport.width - measured.width,
                    height: content.bounds.height + viewport.height - measured.height))
                content.layoutSubtreeIfNeeded(); video.layoutSubtreeIfNeeded()
                guard target.frame.width <= visibleFrame.width, target.frame.height <= visibleFrame.height else {
                    throw Failure(message: "The measured capture window does not fit the visible display")
                }
                target.setFrameOrigin(NSPoint(x: min(max(target.frame.minX, visibleFrame.minX), visibleFrame.maxX - target.frame.width),
                    y: min(max(target.frame.minY, visibleFrame.minY), visibleFrame.maxY - target.frame.height)))
                try await floatingWait(phase + " has a measured 800x480-point native viewport") { geometryReady(target) }
            }
            func sample(_ target: NSWindow) throws -> [String: Any] {
                try checkCaptureDeadline(); try checkObjects("compositor hold")
                let current = state(), processing = current["processing"] as? [String: Any] ?? [:]
                let nativeState = native()
                guard identity() == initial, exactSeconds(4), initial["pending-frames"] == 0,
                      current["paused"] as? Bool == true, current["playing"] as? Bool == false,
                      current["muted"] as? Bool == true, nativeState["compare-ready"] as? Bool == true,
                      nativeState["preview-pending"] as? Bool == false,
                      nativeState["comparison"] as? String == "enhanced", nativeState["displayed-content-kind"] as? String == "enhanced",
                      processing["enabled"] as? Bool == true, processing["mode"] as? String == "adaptive",
                      integer(processing, "width") == 160, integer(processing, "height") == 96,
                      (processing["strength"] as? NSNumber)?.doubleValue == 1,
                      (processing["colorStrength"] as? NSNumber)?.doubleValue == 1,
                      selected("sub", id: 1), number("subtitleScale") == 1, number("subtitleDelay") == 0,
                      (current["nativeSubtitleColor"] as? String)?.uppercased() == "#FFFFFFFF",
                      (processing["subtitleBrightness"] as? NSNumber)?.doubleValue == 1,
                      NSScreen.screens.count == 1, target.screen === screen, screen.frame == screenFrame,
                      screen.visibleFrame == visibleFrame, screen.backingScaleFactor == scale, target.backingScaleFactor == scale,
                      target.windowNumber > 0, target.isVisible, !target.isMiniaturized, target.isOnActiveSpace,
                      target.occlusionState.contains(.visible), visibleFrame.contains(target.frame),
                      geometryReady(target), metal.contentsRect == CGRect(x: 0, y: 0, width: 1, height: 1),
                      CATransform3DIsIdentity(metal.transform), let content = target.contentView else {
                    throw Failure(message: "Frame, native subtitle, ownership or measured geometry changed during compositor hold")
                }
                let videoInWindow = video.convert(video.bounds, to: nil)
                let geometry: [String: Any] = [
                    "coordinateSpace": "single-display AppKit bottom-left; WindowServer rects global top-left",
                    "displayID": displayID, "screenFrame": rect(screenFrame), "screenVisibleFrame": rect(visibleFrame),
                    "windowFrame": rect(target.frame), "windowServerBounds": serverRect(target.frame),
                    "windowContentLayoutRect": rect(target.contentLayoutRect), "contentBounds": rect(content.bounds),
                    "videoRectInWindow": rect(videoInWindow), "videoRectInContent": rect(video.convert(video.bounds, to: content)),
                    "videoWindowServerRect": serverRect(target.convertToScreen(videoInWindow)),
                    "hostIdentity": String(describing: ObjectIdentifier(video)), "hostBounds": rect(video.bounds),
                    "hostBackingBounds": rect(video.convertToBacking(video.bounds)), "backingScale": scale,
                    "contentsScale": metal.contentsScale, "drawableSize": ["width": metal.drawableSize.width, "height": metal.drawableSize.height],
                    "layerBounds": rect(metal.bounds), "layerContentsRect": rect(metal.contentsRect), "layerTransformIsIdentity": true,
                    "children": children.map { child -> [String: Any] in
                        let inWindow = child.convert(child.bounds, to: nil)
                        return ["identity": String(describing: ObjectIdentifier(child)),
                            "layerIdentity": String(describing: ObjectIdentifier(child.layer!)),
                            "bounds": rect(child.bounds), "backingBounds": rect(child.convertToBacking(child.bounds)),
                            "rectInWindow": rect(inWindow), "windowServerRect": serverRect(target.convertToScreen(inWindow))]
                    }]
                return ["identity": initial, "geometry": geometry,
                    "source": source, "core": core, "configuration": configuration,
                    "subtitle": ["selectedTrackID": 1, "scale": number("subtitleScale"), "delay": number("subtitleDelay"),
                        "brightness": (processing["subtitleBrightness"] as? NSNumber)!, "nativeColor": current["nativeSubtitleColor"]!],
                    "processing": ["mode": "adaptive", "enabled": true, "width": 160, "height": 96,
                        "strength": processing["strength"]!, "colorStrength": processing["colorStrength"]!,
                        "comparison": "enhanced", "displayedContentKind": "enhanced"]]
            }
            func capture(_ phase: String, sequence: Int, target: NSWindow) async throws {
                let phaseDeadline = min(captureDeadline, ProcessInfo.processInfo.systemUptime + 30)
                capturePhaseDeadline = phaseDeadline
                defer { capturePhaseDeadline = nil }
                try await fitViewport(target, phase)
                try await preserved(initial, phase + " capture-ready paused identity")
                let baseline = try sample(target), baselineData = try json(baseline)
                let binding: [String: Any] = ["version": 1, "sessionID": sessionID, "phase": phase,
                    "phaseSequence": sequence, "targetPID": pid, "windowID": target.windowNumber]
                var reference = binding
                reference["createdUptime"] = ProcessInfo.processInfo.systemUptime
                reference["createdMediaTime"] = CACurrentMediaTime()
                reference["overallDeadlineUptime"] = captureDeadline
                reference["phaseDeadlineUptime"] = phaseDeadline
                reference["sample"] = baseline
                let referenceData = try json(reference)
                let referenceSHA = SHA256.hash(data: referenceData).map { String(format: "%02x", $0) }.joined()
                let acknowledgementURL = directory.appendingPathComponent(phase + "-complete.json")
                guard !FileManager.default.fileExists(atPath: acknowledgementURL.path) else {
                    throw Failure(message: "Premature capture acknowledgement for " + phase)
                }
                try checkCaptureDeadline()
                try immutable(referenceData, at: directory.appendingPathComponent(phase + "-reference.json"))
                record(phase + "-compositor-reference-published")
                var sampleIndex = 0
                while true {
                    try checkCaptureDeadline()
                    guard ProcessInfo.processInfo.systemUptime < phaseDeadline else { throw Failure(message: "Capture stage exceeded 30 seconds: " + phase) }
                    let observed = try sample(target)
                    guard try json(observed) == baselineData else { throw Failure(message: "Capture sample changed within " + phase) }
                    sampleIndex += 1
                    var live = binding
                    live["referenceSHA256"] = referenceSHA; live["sampleIndex"] = sampleIndex
                    live["observedUptime"] = ProcessInfo.processInfo.systemUptime; live["observedMediaTime"] = CACurrentMediaTime()
                    live["status"] = "holding"; live["sample"] = observed
                    try json(live).write(to: directory.appendingPathComponent(phase + "-live.json"), options: .atomic)
                    if FileManager.default.fileExists(atPath: acknowledgementURL.path) {
                        let attributes = try FileManager.default.attributesOfItem(atPath: acknowledgementURL.path)
                        guard let size = attributes[.size] as? NSNumber, size.intValue <= 65_536 else {
                            throw Failure(message: "Oversized capture acknowledgement")
                        }
                        let acknowledgementData = try Data(contentsOf: acknowledgementURL)
                        guard acknowledgementData.count <= 65_536,
                              let acknowledgement = try JSONSerialization.jsonObject(with: acknowledgementData) as? [String: Any],
                              acknowledgement["version"] as? Int == 1, acknowledgement["sessionID"] as? String == sessionID,
                              acknowledgement["phase"] as? String == phase, acknowledgement["phaseSequence"] as? Int == sequence,
                              acknowledgement["targetPID"] as? Int == pid, acknowledgement["windowID"] as? Int == target.windowNumber,
                              acknowledgement["referenceSHA256"] as? String == referenceSHA,
                              acknowledgement["captured"] as? Bool == true else {
                            throw Failure(message: "Capture acknowledgement does not bind the current immutable reference")
                        }
                        let acceptedSample = try sample(target)
                        guard try json(acceptedSample) == baselineData, ProcessInfo.processInfo.systemUptime < phaseDeadline else {
                            throw Failure(message: "Capture state or deadline changed before acknowledgement acceptance")
                        }
                        sampleIndex += 1; live["sampleIndex"] = sampleIndex; live["sample"] = acceptedSample
                        live["status"] = "complete"; live["observedUptime"] = ProcessInfo.processInfo.systemUptime
                        live["observedMediaTime"] = CACurrentMediaTime()
                        live["acknowledgement"] = acknowledgement
                        live["acknowledgementScope"] = "external coordinator assertion; no in-app pixel verification"
                        try immutable(try json(live), at: directory.appendingPathComponent(phase + "-after.json"))
                        try json(live).write(to: directory.appendingPathComponent(phase + "-live.json"), options: .atomic)
                        snapshots.append(["check": phase + "-compositor-external-acknowledgement", "hostSeconds": ProcessInfo.processInfo.systemUptime,
                            "referenceSHA256": referenceSHA, "sampleCount": sampleIndex, "receipt": live, "state": state()])
                        checks.append(phase + " external compositor acknowledgement preserves exact held identity and measured geometry")
                        return
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            try await capture("main", sequence: 1, target: window)
            let panel = try await enter("compositor floating entry")
            try await capture("floating", sequence: 2, target: panel)
            try await press("return", in: panel)
            try await returned(panel, "compositor Return restores main host and constraints", minimized: false)
            try await capture("returned", sequence: 3, target: window)
            // Preserve the frozen external runner's active-floating asynchronous teardown contract.
            _ = try await enter("floating entry before asynchronous quit")
            try await preserved(initial, "paused active floating host before asynchronous quit")
            try checkCaptureDeadline()
            checks.append("three caller-coordinated same-frame subtitle-on compositor stages completed; external teardown still required")
            return
        }
        let firstPanel = try await enter("initial floating entry")
        try await preserved(initial, "paused floating entry")
        for size in [NSSize(width: 800, height: 500), NSSize(width: 640, height: 416)] {
            let before = metal.drawableSize
            firstPanel.setContentSize(size)
            firstPanel.contentView?.layoutSubtreeIfNeeded()
            try await floatingWait("paused native panel resize to \(Int(size.width))x\(Int(size.height))") {
                let bounds = self.video.bounds
                return abs(bounds.width - size.width) < 1 && bounds.height > 0 &&
                    children.allSatisfy { abs($0.bounds.width - bounds.width) < 1 && abs($0.bounds.height - bounds.height) < 1 } &&
                    metal.drawableSize != before && metal.drawableSize.width > 0 && metal.drawableSize.height > 0
            }
            snapshots.append(["check": "resized native Metal drawable", "hostSeconds": ProcessInfo.processInfo.systemUptime,
                "drawableWidth": metal.drawableSize.width, "drawableHeight": metal.drawableSize.height,
                "contentsScale": metal.contentsScale, "state": state()])
            try await preserved(initial, "paused resize \(Int(size.width))x\(Int(size.height))")
        }
        try await press("return", in: firstPanel)
        try await returned(firstPanel, "native Return restores main host and constraints", minimized: false)
        try await preserved(initial, "paused native Return")

        let transportPanel = try await enter("floating transport entry")
        var previousSeek = initial
        for (control, seconds) in [("seekForward", Int64(25)), ("seekBackward", Int64(20))] {
            try await press(control, in: transportPanel)
            try await floatingWait("native \(control) reaches exact \(seconds)-second source frame", seconds: 25) {
                exactSeconds(seconds) && integer(native(), "displayed-generation") > (previousSeek["displayed-generation"] ?? Int64.max) &&
                    self.state()["paused"] as? Bool == true
            }
            previousSeek = try await settle("native \(control) completes one paused replacement")
            try checkObjects(control)
        }
        guard previousSeek["displayed-source-pts"] == initial["displayed-source-pts"],
              previousSeek["displayed-timebase-num"] == initial["displayed-timebase-num"],
              previousSeek["displayed-timebase-den"] == initial["displayed-timebase-den"] else {
            throw Failure(message: "Native ±5-second seek did not return to the original exact rational timestamp")
        }
        checks.append("native ±5-second controls preserve the source timeline and return to the exact initial frame")
        try await press("playPause", in: transportPanel)
        try await progress("native Play advances exact frames through the same core", from: previousSeek, panel: transportPanel, minimized: false)
        guard let beforeMinimize = identity() else { throw Failure(message: "Missing progressing native identity") }
        window.miniaturize(nil)
        try await progress("floating playback progresses while main is minimized", from: beforeMinimize, panel: transportPanel, minimized: true)
        try await press("playPause", in: transportPanel)
        let held = try await settle("native floating Pause settles exact source identity", allowBufferedPending: true)
        try await press("return", in: transportPanel)
        try await returned(transportPanel, "explicit Return deminiaturizes and shows main", minimized: false)
        guard (floating()["lastRestore"] as? [String: Any])?["activateMain"] as? Bool == true else {
            throw Failure(message: "Return did not record explicit main activation")
        }
        try await preserved(held, "paused minimize and explicit Return")

        let closePanel = try await enter("main close control entry")
        window.performClose(nil)
        try await floatingWait("closing main hides it while floating host remains attached") {
            !self.window.isVisible && !self.window.isMiniaturized && self.video.window === closePanel && closePanel.isVisible &&
                floating()["active"] as? Bool == true
        }
        try await preserved(held, "paused main close")
        try await press("return", in: closePanel)
        try await returned(closePanel, "Return unhides main after close", minimized: false)
        try await preserved(held, "paused main close and Return")

        let nonactivatingPanel = try await enter("nonactivating panel close entry")
        window.miniaturize(nil)
        try await floatingWait("main minimized before panel close") { self.window.isMiniaturized }
        nonactivatingPanel.performClose(nil)
        try await returned(nonactivatingPanel, "panel close restores host without deminiaturizing main", minimized: true)
        guard (floating()["lastRestore"] as? [String: Any])?["activateMain"] as? Bool == false else {
            throw Failure(message: "Panel close unexpectedly requested main activation")
        }
        try await preserved(held, "paused nonactivating panel close")
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        try await floatingWait("explicit harness restoration makes main observable") { self.window.isVisible && !self.window.isMiniaturized }
        _ = try await enter("floating entry before asynchronous quit")
        try await preserved(held, "paused active floating host before asynchronous quit")
        checks.append("quit is requested after this report; external lifecycle log and process exit must verify worker destruction and panel release")
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
            if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] == "floating-video" {
                try await runFloatingVideo()
            } else if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] == "pip-system" {
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
        if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_KIND"] == "floating-video" {
            report["scope"] = "Actual AppKit windows and programmatic native menu/button/window actions with exact native frame identity; not physical input delivery, compositor presentation, HDR scanout or realtime qualification. Async quit is checked separately from this pre-termination report."
            report["scenario"] = "floating-video"
            report["physicalInputDeliveryQualified"] = false
            report["presentationQualified"] = false
            report["physicalHDRQualified"] = false
            report["asynchronousTerminationVerifiedByThisReport"] = false
        }
        if let failure { report["failure"] = failure }
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
        } catch { fputs("Cannot write UI smoke report: \(error)\n", stderr) }
        fputs("HDRPlayer UI smoke: \(failure ?? "passed")\n", stderr)
        NSApp.terminate(nil)
    }
}

/// A synchronous diagnostic tap invoked only after the real main-window delegate
/// has updated and published its fullscreen guard. It never dispatches an action.
@MainActor
private final class FloatingFullscreenSmokeCallbacks: NSObject {
    private let receive: (String) -> Void
    init(window: NSWindow, receive: @escaping (String) -> Void) {
        self.receive = receive
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(observed(_:)),
            name: Notification.Name("HDRPlayer.FloatingFullscreenDiagnostic"), object: window)
    }
    @objc private func observed(_ notification: Notification) {
        if let event = notification.userInfo?["event"] as? String { receive(event) }
    }
    func stop() { NotificationCenter.default.removeObserver(self) }
}

@MainActor
private final class FloatingSpaceSmokeCallbacks: NSObject {
    private let receive: () -> Void
    init(window: NSWindow, receive: @escaping () -> Void) {
        self.receive = receive
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(observed(_:)),
            name: Notification.Name("HDRPlayer.FloatingSpaceDiagnostic"), object: window)
    }
    @objc private func observed(_ notification: Notification) { receive() }
    func stop() { NotificationCenter.default.removeObserver(self) }
}
