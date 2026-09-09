import AppKit
import AVKit
import WebKit

@MainActor
final class PlayerDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private var window: NSWindow!
    private let player = AVPlayer()
    private let video = AVPlayerView()
    private var controls: WKWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        window.title = "HDR Player · Native bypass harness"
        window.minSize = NSSize(width: 640, height: 420)
        video.player = player
        video.controlsStyle = .none
        video.videoGravity = .resizeAspect
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
            .appendingPathComponent("MetalDLSSVideo_HDRPlayer.bundle")
        let resources = packagedResources.flatMap { Bundle(url: $0) } ?? Bundle.module
        if let html = resources.url(forResource: "index", withExtension: "html", subdirectory: "Controls") {
            controls.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.count == 2 {
            load(URL(fileURLWithPath: CommandLine.arguments[1]))
        }
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
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        window.title = "\(url.lastPathComponent) · Native bypass"
        player.play()
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
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("Playback controls failed: %@", error.localizedDescription)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = PlayerDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
