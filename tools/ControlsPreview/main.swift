import AppKit
import WebKit

@MainActor
final class Preview: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    var messages: [[String: Any]] = []
    let width: CGFloat
    let output: URL
    let page: URL
    init(width: CGFloat, output: URL, page: URL) { self.width = width; self.output = output; self.page = page }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "player")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 196), configuration: configuration)
        web.navigationDelegate = self
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; window.orderFront(nil)
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = """
        window.dispatchEvent(new CustomEvent('player-state', {detail: {
          version: 1, title: 'Coast at dusk · HDR10', paused: false, position: 73.25, duration: 368,
          volume: 72, muted: false, fullscreen: false,
          tracks: [{id:1,type:'audio',title:'English · 5.1',selected:true},{id:2,type:'audio',title:'Japanese'},{id:3,type:'sub',title:'English SDH',selected:true}],
          chapters: [{index:0,title:'Opening',time:0},{index:1,title:'The coast',time:65}], chapter:1,
          processing: {mode:'adaptive',availableModes:[],enabled:true,modelAvailable:true,strength:0.65,colorStrength:0.8,width:320,height:192,status:'Processing',message:'HDR preserved · processing frame'},
          capabilities: {prepared:false,pip:false,sameFrameComparison:false}
        }}));
        document.querySelector('#mute').click();
        document.querySelector('#volume').value = 43;
        document.querySelector('#volume').dispatchEvent(new Event('input'));
        document.querySelector('#timeline').value = 87.5;
        document.querySelector('#timeline').dispatchEvent(new Event('change'));
        ({scrollWidth:document.documentElement.scrollWidth, width:innerWidth, height:document.querySelector('main').getBoundingClientRect().height,
          disabledModes:document.querySelector('#mode').disabled, hiddenComparison:document.querySelector('#compare').hidden});
        """
        Task {
            do {
                let layout = try await web.evaluateJavaScript(script)
                try await Task.sleep(for: .milliseconds(300))
                let configuration = WKSnapshotConfiguration()
                configuration.rect = web.bounds
                let image = try await web.takeSnapshot(configuration: configuration)
                guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                      let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "snapshot", code: 1) }
                try png.write(to: output)
                let report: [String: Any] = ["layout": layout ?? NSNull(), "messages": messages, "snapshot": output.path]
                let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: json, as: UTF8.self))
                guard let values = layout as? [String: Any], let scroll = values["scrollWidth"] as? Double,
                      let width = values["width"] as? Double, scroll <= width,
                      messages.contains(where: { $0["command"] as? String == "seek" && $0["value"] as? Double == 87.5 }) else { exit(1) }
                NSApp.terminate(nil)
            } catch { fputs("\(error)\n", stderr); exit(1) }
        }
    }
}
MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, let width = Double(arguments[1]), width.isFinite, width >= 640 else {
        fputs("Usage: controls-preview WIDTH OUTPUT_PNG CONTROLS_HTML (width >= 640)\n", stderr); exit(64)
    }
    let preview = Preview(width: CGFloat(width), output: URL(fileURLWithPath: arguments[2]), page: URL(fileURLWithPath: arguments[3]))
    let app = NSApplication.shared
    app.delegate = preview; app.setActivationPolicy(.accessory); app.run()
}
