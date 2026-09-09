import AppKit
import FrameEngine
import WebKit

@MainActor
final class PlayerDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private var window: NSWindow!
    private var player: NativeHDRPlayback!
    private var video: HDRMetalView!
    private var controls: WKWebView!
    private let options: HDRHarnessOptions
    private var status = "Open a video · native HDR surface · video-only development harness"

    init(options: HDRHarnessOptions) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            video = try HDRMetalView()
            video.captureDirectory = options.captureDirectory
            player = try NativeHDRPlayback(surface: video, options: options)
        } catch { finish(.failure(error)); return }
        player.onStatus = { [weak self] status in self?.setStatus(status) }
        player.onFinish = { [weak self] result in self?.finish(result) }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit HDR Player", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openItem = fileMenu.addItem(withTitle: "Open Video…", action: #selector(openVideo), keyEquivalent: "o")
        openItem.target = self
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "HDR Player · Native RGBA16F / EDR harness"
        window.minSize = NSSize(width: 640, height: 420)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "player")
        controls = WKWebView(frame: .zero, configuration: configuration)
        controls.navigationDelegate = self
        let stack = NSStackView(views: [video, controls])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        controls.heightAnchor.constraint(equalToConstant: 128).isActive = true
        window.contentView = stack
        let packagedResources = Bundle.main.resourceURL?
            .appendingPathComponent("MetalDLSSVideo_HDRHarness.bundle")
        let resources = packagedResources.flatMap { Bundle(url: $0) } ?? Bundle.module
        if let html = resources.url(forResource: "index", withExtension: "html", subdirectory: "Controls") {
            controls.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        window.center()
        if !options.headless {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if let url = options.mediaURL { load(url) }
    }

    @objc private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.load(url) }
        }
    }

    private func load(_ url: URL) {
        window.title = "\(url.lastPathComponent) · Original HDR / EDR harness"
        player.load(url)
    }

    @objc private func displayChanged() { video.updateDisplay() }

    private func setStatus(_ message: String) {
        status = message
        guard let controls, let data = try? JSONSerialization.data(withJSONObject: [message]),
              let encoded = String(data: data, encoding: .utf8) else { return }
        controls.evaluateJavaScript("document.querySelector('main p:nth-child(2)').textContent = \(encoded)[0]")
    }

    private func finish(_ result: Result<HDRHarnessReport, any Error>) {
        switch result {
        case .success(let report):
            if let encoded = try? JSONEncoder().encode(report), let json = String(data: encoded, encoding: .utf8) { print(json) }
            setStatus("Completed \(report.completedFrames) original HDR frames · video harness")
            if options.exitAfterPlayback { NSApp.terminate(nil) }
        case .failure(let error):
            fputs("HDR harness: \(error.localizedDescription)\n", stderr)
            if options.exitAfterPlayback { exit(1) }
            setStatus("HDR error: \(error.localizedDescription)")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let action = message.body as? String else { return }
        switch action {
        case "open": openVideo()
        case "play": player.play()
        case "pause": player.pause()
        default: break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("Local playback controls loaded")
        setStatus(status)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("Playback controls failed: %@", error.localizedDescription)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let options: HDRHarnessOptions
do { options = try HDRHarnessOptions(arguments: Array(CommandLine.arguments.dropFirst())) }
catch { fputs("HDR harness: \(error.localizedDescription)\n", stderr); exit(2) }
let app = NSApplication.shared
let delegate = PlayerDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(options.headless ? .prohibited : .regular)
app.run()
