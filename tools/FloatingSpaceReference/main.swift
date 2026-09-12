import AppKit
import CryptoKit
import Foundation

private let helperBundleID = "dev.scripttype.FloatingSpaceReference"
private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message) }
}
private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
private func readJSON(_ url: URL) throws -> ([String: Any], Data) {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    try require(values.isRegularFile == true && values.isSymbolicLink != true && (values.fileSize ?? Int.max) <= 65_536,
        "Invalid or oversized protocol file: " + url.lastPathComponent)
    let data = try Data(contentsOf: url)
    try require(data.count <= 65_536, "Protocol file grew past its bound")
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure("Invalid protocol object") }
    return (object, data)
}
private func json(_ object: [String: Any]) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try require(data.count <= 65_536, "Protocol output exceeds 64 KiB")
    return data
}
private func immutable(_ object: [String: Any], _ url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".tmp")
    try json(object).write(to: temporary, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: temporary) }
    // Same-directory hard-link publication is atomic and refuses an existing name.
    try FileManager.default.linkItem(at: temporary, to: url)
}

@MainActor
private final class SpaceReference: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let directory: URL
    let playerReference: [String: Any]
    let playerBytes: Data
    let sessionID: String
    let playerPID: Int
    let overallDeadline: Double
    var window: NSWindow!
    var binding: [String: Any] = [:]
    var referenceBytes: Data?
    var timer: Timer?
    var watchdog: DispatchSourceTimer?
    var events: [[String: Any]] = []
    var workspaceCount = 0
    var sequence = 0
    var sampleIndex = 0
    var stageDeadline = 0.0
    var acceptedNonces = Set<String>()
    var stage = "normal"
    var pending: [String: Any]?
    var pendingBytes: Data?
    var pendingWorkspaceCount = 0
    var callbacks: [String] = []
    var acceptedCommandBytes: [Int: Data] = [:]
    var failure: String?
    var cleanupDeadline: Double?
    var cleanupExitRequested = false
    var finished = false
    var exitCode: Int32 = 1

    init(directory: URL) throws {
        self.directory = directory
        let (reference, bytes) = try readJSON(directory.appendingPathComponent("player-reference.json"))
        guard reference["version"] as? Int == 1, let session = reference["sessionID"] as? String,
              UUID(uuidString: session) != nil, let pid = reference["playerPID"] as? Int, pid > 0,
              let deadline = reference["overallDeadlineUptime"] as? Double, deadline.isFinite,
              let created = reference["createdUptime"] as? Double, created.isFinite,
              created <= ProcessInfo.processInfo.systemUptime, ProcessInfo.processInfo.systemUptime < deadline,
              deadline - created <= 90 else { throw Failure("Invalid or expired player reference") }
        self.playerReference = reference; self.playerBytes = bytes
        self.sessionID = session; self.playerPID = pid; self.overallDeadline = deadline
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try require(Bundle.main.bundleIdentifier == helperBundleID, "Helper must run from its distinct application bundle")
            try require(Int(ProcessInfo.processInfo.processIdentifier) != playerPID, "Helper must be a separate process")
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.collectionBehavior = [.fullScreenPrimary, .fullScreenDisallowsTiling]
            window.tabbingMode = .disallowed; window.title = "Owned Space Reference"
            window.contentView = NSView(); window.backgroundColor = .windowBackgroundColor
            window.makeKeyAndOrderFront(nil)
            binding = ["version": 1, "sessionID": sessionID, "playerPID": playerPID,
                "playerReferenceSHA256": digest(playerBytes), "helperPID": Int(ProcessInfo.processInfo.processIdentifier),
                "helperWindowID": window.windowNumber]
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged),
                name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            NSApp.activate(ignoringOtherApps: true)
            stageDeadline = min(overallDeadline, now + 15)
            let reference = binding.merging(["createdUptime": now, "overallDeadlineUptime": overallDeadline,
                "bundleID": helperBundleID, "executablePath": Bundle.main.executableURL!.path,
                "sample": sample()]) { _, new in new }
            try immutable(reference, directory.appendingPathComponent("helper-reference.json"))
            referenceBytes = try readJSON(directory.appendingPathComponent("helper-reference.json")).1
            try record("helper-ready")
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            let watchdog = DispatchSource.makeTimerSource(queue: .global())
            watchdog.schedule(deadline: .now() + max(1, overallDeadline - now + 6))
            watchdog.setEventHandler { fputs("Space helper exceeded its hard deadline\n", stderr); _exit(124) }
            watchdog.resume(); self.watchdog = watchdog
            tick()
        } catch { abort(error) }
    }
    var now: Double { ProcessInfo.processInfo.systemUptime }
    func sample() -> [String: Any] {
        ["stage": stage, "fullscreen": window.styleMask.contains(.fullScreen),
         "visible": window.isVisible, "onActiveSpace": window.isOnActiveSpace,
         "occlusionVisible": window.occlusionState.contains(.visible),
         "frontmostPID": NSWorkspace.shared.frontmostApplication.map { Int($0.processIdentifier) } ?? -1,
         "windowID": window.windowNumber, "workspaceChangeCount": workspaceCount]
    }
    func record(_ event: String) throws {
        try require(events.count < 128, "Helper event bound exceeded")
        let row = binding.merging(["event": event, "eventIndex": events.count,
            "observedUptime": now, "sample": sample()]) { _, new in new }
        try immutable(row, directory.appendingPathComponent(String(format: "helper-event-%03d.json", events.count)))
        events.append(row)
    }
    @objc func spaceChanged() {
        workspaceCount += 1
        do { try record("NSWorkspace.activeSpaceDidChange") } catch { abort(error) }
    }
    func callback(_ event: String) {
        do {
            if failure == nil {
                let expected = sequence == 1 ? ["will-enter", "did-enter"] : ["will-exit", "did-exit"]
                try require(pending != nil && callbacks.count < expected.count && expected[callbacks.count] == event,
                    "Unexpected, duplicate or failed fullscreen callback: " + event)
                callbacks.append(event)
            }
            if event == "will-enter" { stage = "entering" }
            if event == "did-enter" { stage = "fullscreen" }
            if event == "will-exit" { stage = "exiting" }
            if event == "did-exit" { stage = "returned" }
            try record(event)
        } catch { abort(error) }
    }
    func windowWillEnterFullScreen(_ note: Notification) { callback("will-enter") }
    func windowDidEnterFullScreen(_ note: Notification) { callback("did-enter") }
    func windowWillExitFullScreen(_ note: Notification) { callback("will-exit") }
    func windowDidExitFullScreen(_ note: Notification) { callback("did-exit") }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { callback("failed-enter") }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { callback("failed-exit") }
    func tick() {
        guard !finished else { return }
        if failure != nil { cleanupTick(); return }
        do {
            try require(now < overallDeadline && now < stageDeadline, "Space helper stage or overall deadline expired")
            try require(try readJSON(directory.appendingPathComponent("player-reference.json")).1 == playerBytes,
                "Immutable player reference changed")
            if let referenceBytes {
                try require(try readJSON(directory.appendingPathComponent("helper-reference.json")).1 == referenceBytes,
                    "Immutable helper reference changed")
            }
            for (number, bytes) in acceptedCommandBytes {
                try require(try readJSON(directory.appendingPathComponent("helper-command-\(number).json")).1 == bytes,
                    "Accepted helper command changed")
            }
            let allowedSequence = pending == nil ? min(3, sequence + 1) : sequence
            if allowedSequence < 3 {
                for future in (allowedSequence + 1)...3 {
                    try require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("helper-command-\(future).json").path),
                        "Premature future helper command")
                }
            }
            if let pending, let deadline = pending["deadlineUptime"] as? Double {
                try require(now < deadline, "Space helper stage deadline expired")
                let entered = sequence == 1
                if callbacks == (entered ? ["will-enter", "did-enter"] : ["will-exit", "did-exit"]),
                   workspaceCount > pendingWorkspaceCount, window.styleMask.contains(.fullScreen) == entered,
                   window.isOnActiveSpace, window.isVisible,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    try require(now < deadline && now < overallDeadline, "Late helper receipt")
                    var receipt = binding
                    receipt["sequence"] = sequence; receipt["action"] = pending["action"]
                    receipt["commandSHA256"] = digest(pendingBytes!); receipt["completedUptime"] = now
                    receipt["nonce"] = pending["nonce"]; receipt["playerStageSHA256"] = pending["playerStageSHA256"]
                    receipt["workspaceCountBefore"] = pendingWorkspaceCount; receipt["workspaceCountAfter"] = workspaceCount
                    receipt["callbacks"] = callbacks; receipt["sample"] = sample(); receipt["completed"] = true
                    try immutable(receipt, directory.appendingPathComponent("helper-receipt-\(sequence).json"))
                    try require(now < deadline && now < overallDeadline, "Helper deadline expired while publishing receipt")
                    self.pending = nil; pendingBytes = nil
                    stageDeadline = min(overallDeadline, now + 15)
                }
            } else if sequence < 3 {
                let number = sequence + 1
                let path = directory.appendingPathComponent("helper-command-\(number).json")
                if FileManager.default.fileExists(atPath: path.path) {
                    let (command, bytes) = try readJSON(path)
                    try require(binding.allSatisfy { (command[$0.key] as? NSObject)?.isEqual($0.value) == true }, "Helper command binding mismatch")
                    let (playerStage, stageBytes) = try readJSON(directory.appendingPathComponent("player-stage-\(number - 1).json"))
                    guard let stageBinding = playerStage["helperBinding"] as? [String: Any],
                          binding.allSatisfy({ (stageBinding[$0.key] as? NSObject)?.isEqual($0.value) == true }),
                          playerStage["stage"] as? Int == number - 1,
                          let stageLimit = playerStage["nextStageDeadlineUptime"] as? Double, stageLimit.isFinite,
                          let stageObserved = playerStage["observedUptime"] as? Double, stageObserved.isFinite else {
                        throw Failure("Missing or unbound preceding player stage")
                    }
                    let actions = ["enter-fullscreen", "exit-fullscreen", "finish"]
                    guard command["sequence"] as? Int == number, command["action"] as? String == actions[number - 1],
                          let nonce = command["nonce"] as? String, UUID(uuidString: nonce) != nil, !acceptedNonces.contains(nonce),
                          command["playerStageSHA256"] as? String == digest(stageBytes),
                          let issued = command["issuedUptime"] as? Double, issued.isFinite,
                          let deadline = command["deadlineUptime"] as? Double, deadline.isFinite,
                          stageObserved <= issued, issued <= now, now - issued <= 2,
                          now < deadline, deadline <= overallDeadline, deadline <= stageLimit,
                          deadline - issued <= 15 else { throw Failure("Stale or invalid helper command") }
                    try require(number == 1 ? stage == "normal" : number == 2 ? stage == "fullscreen" : stage == "returned",
                        "Helper command is out of phase")
                    sequence = number; acceptedCommandBytes[number] = bytes; acceptedNonces.insert(nonce)
                    stageDeadline = deadline
                    pendingWorkspaceCount = workspaceCount; callbacks = []
                    pending = command; pendingBytes = bytes
                    try record("command-accepted")
                    if number == 3 {
                        try require(!window.styleMask.contains(.fullScreen), "Cannot finish while fullscreen")
                        stage = "finished"
                        var receipt = binding
                        receipt["sequence"] = 3; receipt["action"] = "finish"; receipt["commandSHA256"] = digest(bytes)
                        receipt["completed"] = true; receipt["completedUptime"] = now; receipt["sample"] = sample()
                        receipt["nonce"] = nonce; receipt["playerStageSHA256"] = command["playerStageSHA256"]
                        try require(now < deadline && now < overallDeadline, "Late helper finish receipt")
                        try immutable(receipt, directory.appendingPathComponent("helper-receipt-3.json"))
                        try require(now < deadline && now < overallDeadline, "Helper deadline expired while publishing finish receipt")
                        finish(success: true); return
                    }
                    // Activate only this helper; never activate the player or a user application.
                    if number == 1 { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
                    try require(now < deadline && now < overallDeadline, "Helper transition deadline expired before dispatch")
                    window.toggleFullScreen(nil)
                }
            }
            sampleIndex += 1
            let live = binding.merging(["sampleIndex": sampleIndex, "observedUptime": now,
                "sequence": sequence, "sample": sample()]) { _, new in new }
            try json(live).write(to: directory.appendingPathComponent("helper-live.json"), options: .atomic)
        } catch { abort(error) }
    }
    func abort(_ error: Error) {
        guard failure == nil else { return }
        failure = String(describing: error); cleanupDeadline = now + 5
        try? immutable(binding.merging(["error": failure!, "observedUptime": now]) { _, new in new },
            directory.appendingPathComponent("helper-failure.json"))
        cleanupTick()
    }
    func cleanupTick() {
        guard !finished else { return }
        if window == nil { finish(success: false); return }
        if now >= (cleanupDeadline ?? now) { finish(success: false); return }
        if window.styleMask.contains(.fullScreen) {
            if !cleanupExitRequested && stage != "entering" && stage != "exiting" {
                cleanupExitRequested = true; window.toggleFullScreen(nil)
            }
        } else if stage != "entering" && stage != "exiting" { finish(success: false) }
    }
    func finish(success: Bool) {
        guard !finished else { return }
        finished = true; exitCode = success ? 0 : 1
        timer?.invalidate(); watchdog?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        window?.delegate = nil; window?.orderOut(nil); window?.close()
        NSApp.terminate(nil)
    }
    func windowShouldClose(_ window: NSWindow) -> Bool { abort(Failure("Unexpected helper close")); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if finished { return .terminateNow }
        abort(Failure("Unexpected helper termination")); return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { exit(exitCode) }
}

@main
private struct Main {
    @MainActor static func main() {
        do {
            let args = CommandLine.arguments
            try require(args.count == 2 && args[1].hasPrefix("/"), "Usage: FloatingSpaceReference ABSOLUTE_PROTOCOL_DIRECTORY")
            let directory = URL(fileURLWithPath: args[1], isDirectory: true)
            let delegate = try SpaceReference(directory: directory)
            let application = NSApplication.shared
            application.setActivationPolicy(.regular); application.delegate = delegate
            application.run()
            exit(delegate.exitCode)
        } catch { fputs("Space helper: \(error)\n", stderr); exit(1) }
    }
}
