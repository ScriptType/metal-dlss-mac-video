import AppKit

// Local dev tool for scripts/test-floating-video.py; CI and check.sh do not build it.
// Usage: FloatingSpaceReference PLAYER_PID REPORT_JSON. It takes a fullscreen Space of
// its own, writes the player's on-screen windows there, holds the Space for 5 s so the
// player can act on it, then leaves fullscreen and quits.
@main
@MainActor
final class FloatingSpaceReference: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let playerPID = Int32(CommandLine.arguments[1]) ?? 0
    private let reportURL = URL(fileURLWithPath: CommandLine.arguments[2])
    private let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 320),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)

    static func main() {
        let app = NSApplication.shared
        let delegate = FloatingSpaceReference()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Floating Space Reference"
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenDisallowsTiling]
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.toggleFullScreen(nil)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let player = listed.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == playerPID }.map { info in
                ["number": info[kCGWindowNumber as String] ?? 0, "layer": info[kCGWindowLayer as String] ?? 0,
                 "alpha": info[kCGWindowAlpha as String] ?? 0, "bounds": info[kCGWindowBounds as String] ?? [:]]
            }
            let report: [String: Any] = ["fullscreen": window.styleMask.contains(.fullScreen), "active": NSApp.isActive,
                                         "playerWindowsOnScreen": player]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
            try? await Task.sleep(for: .seconds(5))
            window.toggleFullScreen(nil)
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) { NSApp.terminate(nil) }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { NSApp.terminate(nil) }
}
