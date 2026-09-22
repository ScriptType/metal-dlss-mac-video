import AppKit
import Foundation
import QuartzCore
import WebKit

/// Keep the numeric/original diagnostic CLI isolated from the libmpv process so
/// the application cannot accidentally load two copies of the MLX runtime.
func runDiagnosticHarnessIfRequested() -> Never? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let diagnostic = Set(["--headless", "--capture-dir", "--capture-every", "--headroom", "--report", "--frames", "--exit-after-playback"])
    guard arguments.contains(where: diagnostic.contains) else { return nil }
    let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).standardized.deletingLastPathComponent()
    let candidates = [executableDirectory.appendingPathComponent("HDRHarness"),
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("HDRHarness.app/Contents/MacOS/HDRHarness")]
    guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        fputs("HDRHarness is unavailable. Run scripts/build-harness.sh or build the HDRHarness product.\n", stderr)
        exit(2)
    }
    let process = Process()
    process.executableURL = executable; process.arguments = arguments
    process.standardInput = FileHandle.standardInput; process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
    do { try process.run(); process.waitUntilExit(); exit(process.terminationStatus) }
    catch { fputs("HDRHarness: \(error.localizedDescription)\n", stderr); exit(2) }
}

@MainActor
final class PlayerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private var window: NSWindow!
    private var video: NSView!
    private var controls: WKWebView!
    private var player: MPVPlaybackController!
    private var keyMonitor: Any?
    private var terminating = false
    private var terminated = false
    private var latestState: [String: Any] = [:]
    private var pendingOpenURL: URL?
    private var smoke: PlayerSmokeCheck?
    private var lifecycle: PlayerLifecycleDiagnostics?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "HDR Player"
        window.minSize = NSSize(width: 680, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        if ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_REPORT"] == nil { window.setFrameAutosaveName("HDRPlayer.mainWindow") }
        let content = NSView()
        video = NSView()
        video.setAccessibilityElement(true)
        video.setAccessibilityLabel("Native HDR video")
        video.setAccessibilityRole(.image)
        let configuration = WKWebViewConfiguration()
        configuration.preferences.tabFocusesLinks = true
        configuration.userContentController.add(self, name: "player")
        controls = WKWebView(frame: .zero, configuration: configuration)
        controls.navigationDelegate = self
        controls.setAccessibilityLabel("Playback controls")
        for view in [video!, controls!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            video.topAnchor.constraint(equalTo: content.topAnchor), video.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: content.trailingAnchor), video.bottomAnchor.constraint(equalTo: controls.topAnchor),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor), controls.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: content.bottomAnchor), controls.heightAnchor.constraint(equalToConstant: 196)
        ])
        window.contentView = content
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("MetalDLSSVideo_HDRPlayer.bundle")
        let resources = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        if let html = resources.url(forResource: "index", withExtension: "html", subdirectory: "Controls") {
            controls.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        player = MPVPlaybackController(hostView: video)
        player.onState = { [weak self] state in self?.publish(state) }
        player.onStopped = { [weak self] in
            guard let self, self.terminating else { return }
            let complete: @MainActor @Sendable () -> Void = { [weak self] in
                self?.terminated = true
                NSApp.terminate(nil)
            }
            if let lifecycle = self.lifecycle {
                lifecycle.record("native-worker-destroyed", extra: ["nativeChildViews": self.video.subviews.count])
                lifecycle.finish(extra: ["workerDestroyed": true, "nativeChildViews": self.video.subviews.count], completion: complete)
            } else { complete() }
        }
        lifecycle = PlayerLifecycleDiagnostics(path: ProcessInfo.processInfo.environment["HDRPLAYER_LIFECYCLE_LOG"]) { [weak self] in
            guard let self else { return [:] }
            var snapshot = self.player.lifecycleSnapshot()
            snapshot["display"] = self.latestState["display"]
            return snapshot
        }
        player.start()
        publish(player.state)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) == nil }
            return consumed ? nil : event
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        let args = Array(CommandLine.arguments.dropFirst())
        if let url = pendingOpenURL { player.load(url); pendingOpenURL = nil }
        else if let path = args.first(where: { !$0.hasPrefix("--") }) { player.load(URL(fileURLWithPath: path)) }
        if let report = ProcessInfo.processInfo.environment["HDRPLAYER_UI_SMOKE_REPORT"] {
            smoke = PlayerSmokeCheck(webView: controls, window: window, video: video,
                reportURL: URL(fileURLWithPath: report), state: { [weak self] in self?.latestState ?? [:] })
            smoke?.start()
        }
    }

    private func makeMenus() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title); item.submenu = child; menu.addItem(item); return child
        }
        let app = submenu("HDR Player")
        let preferences = app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Quit HDR Player", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu("File")
        let open = file.addItem(withTitle: "Open Video…", action: #selector(openVideo), keyEquivalent: "o"); open.target = self
        let close = file.addItem(withTitle: "Close Window", action: #selector(closeWindow), keyEquivalent: "w"); close.target = self
        let playback = submenu("Playback")
        for (title, action, key) in [("Play/Pause", #selector(togglePlay), "p"), ("Previous Frame", #selector(previousFrame), "["),
                                     ("Next Frame", #selector(nextFrame), "]"), ("Mute", #selector(toggleMute), "m")] {
            let item = playback.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = self
        }
        let view = submenu("View")
        let fullscreen = view.addItem(withTitle: "Toggle Full Screen", action: #selector(toggleFullscreen), keyEquivalent: "f")
        fullscreen.target = self; fullscreen.keyEquivalentModifierMask = [.command, .control]
        NSApp.mainMenu = menu
    }
    @objc private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audio]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.player.load(url) }
        }
    }
    @objc private func closeWindow() { window.performClose(nil) }
    @objc private func openSettings() { controls.evaluateJavaScript("document.getElementById('settings').showModal()") }
    @objc private func togglePlay() { player.command("togglePause", value: nil) }
    @objc private func nextFrame() { player.command("frameStep", value: 1) }
    @objc private func previousFrame() { player.command("frameStep", value: -1) }
    @objc private func toggleMute() { player.command("mute", value: !(latestState["muted"] as? Bool ?? false)) }
    @objc private func toggleFullscreen() { window.toggleFullScreen(nil) }
    @objc private func willSleep() {
        lifecycle?.record("will-sleep.before-pause")
        player.sleep()
        lifecycle?.record("will-sleep.pause-enqueued")
    }
    @objc private func didWake() {
        lifecycle?.record("did-wake.before-restore")
        player.wake()
        lifecycle?.record("did-wake.restore-enqueued")
    }
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) else { return event }
        if let responder = window.firstResponder as? NSView, responder.isDescendant(of: controls) { return event }
        switch event.keyCode {
        case 49: togglePlay()
        case 123, 124:
            let current = latestState["position"] as? Double ?? 0
            let delta: Double = event.modifierFlags.contains(.shift) ? 60 : 5
            player.command("seek", value: max(0, current + (event.keyCode == 123 ? -delta : delta)))
        case 53:
            if window.styleMask.contains(.fullScreen) { toggleFullscreen() } else { return event }
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": toggleFullscreen()
            case "m": toggleMute()
            case ",": previousFrame()
            case ".": nextFrame()
            default: return event
            }
        }
        return nil
    }
    private func publish(_ state: [String: Any]) {
        latestState = state
        window.title = (state["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "HDR Player"
        var displayed = state
        if let layer = video.subviews.first?.layer as? CAMetalLayer {
            displayed["display"] = ["edr": layer.wantsExtendedDynamicRangeContent,
                "headroom": window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1,
                "screen": window.screen?.localizedName ?? "Unknown",
                "colorSpace": layer.colorspace?.name as String? ?? "Unknown"]
        }
        latestState = displayed
        lifecycle?.recordState()
        guard let data = try? JSONSerialization.data(withJSONObject: displayed, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        controls.evaluateJavaScript("window.dispatchEvent(new CustomEvent('player-state',{detail:\(json)}))")
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let command = body["command"] as? String else { return }
        switch command {
        case "open": openVideo()
        case "fullscreen":
            let wanted = body["value"] as? Bool ?? !window.styleMask.contains(.fullScreen)
            if wanted != window.styleMask.contains(.fullScreen) { toggleFullscreen() }
        default: player.command(command, value: body["value"])
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { publish(player.state) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
    func windowDidEnterFullScreen(_ notification: Notification) { player.fullscreenChanged(true); lifecycle?.record("window-fullscreen-enter") }
    func windowDidExitFullScreen(_ notification: Notification) { player.fullscreenChanged(false); lifecycle?.record("window-fullscreen-exit") }
    func windowDidResize(_ notification: Notification) { lifecycle?.record("window-resized") }
    func windowDidChangeScreen(_ notification: Notification) { lifecycle?.record("window-screen-changed") }
    func windowDidBecomeKey(_ notification: Notification) { lifecycle?.record("window-focused") }
    func windowDidResignKey(_ notification: Notification) { lifecycle?.record("window-unfocused") }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let player { player.load(url) } else { pendingOpenURL = url }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminated { return .terminateNow }
        if terminating { return .terminateCancel }
        terminating = true
        lifecycle?.record("termination-requested", extra: ["nativeChildViews": video?.subviews.count ?? 0])
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        controls?.configuration.userContentController.removeScriptMessageHandler(forName: "player")
        player.stop()
        // mpv's VO teardown synchronously detaches its NSView on the main
        // queue. Keep the ordinary AppKit loop running until that completes;
        // terminateLater's nested termination loop does not service that work.
        return .terminateCancel
    }
}

if let never = runDiagnosticHarnessIfRequested() { switch never {} }
let app = NSApplication.shared
let delegate = PlayerDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
