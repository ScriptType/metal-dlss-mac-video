import AppKit

/// Moves the existing mpv host view between the main window and an always-on-top
/// panel. A move never touches the player, its core or its audio output.
@MainActor
final class FloatingVideoController: NSObject, NSWindowDelegate {
    private let host: NSView
    private let mainSlot: NSView
    private let mainWindow: NSWindow
    private let togglePlay: () -> Void
    private let seek: (Double) -> Void
    private let panelSlot = NSView()
    private let placeholder = NSStackView()
    private var panel: NSPanel?
    private var playButton: NSButton?
    private(set) var placement = VideoPlacement.main
    var onChange: ((VideoPlacement) -> Void)?

    init(host: NSView, mainSlot: NSView, mainWindow: NSWindow,
         togglePlay: @escaping () -> Void, seek: @escaping (Double) -> Void) {
        self.host = host
        self.mainSlot = mainSlot
        self.mainWindow = mainWindow
        self.togglePlay = togglePlay
        self.seek = seek
        super.init()
        placeholder.addArrangedSubview(NSTextField(labelWithString: "Video is in the floating window."))
        placeholder.addArrangedSubview(button("Return to Player", #selector(returnToMain)))
        placeholder.orientation = .vertical
        placeholder.spacing = 12
        placeholder.appearance = NSAppearance(named: .darkAqua)
        placeholder.isHidden = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        mainSlot.addSubview(placeholder)
        NSLayoutConstraint.activate([placeholder.centerXAnchor.constraint(equalTo: mainSlot.centerXAnchor),
                                     placeholder.centerYAnchor.constraint(equalTo: mainSlot.centerYAnchor)])
        dock(in: mainSlot)
    }

    @discardableResult
    func perform(_ action: VideoPlacement.Action) -> VideoPlacement {
        let next = placement.after(action)
        guard next != placement else { return next }
        switch (placement, next) {
        case (.main, .floating): showPanel()
        case (.floating, .main): showMain()
        case (.floating(mainHidden: false), .floating(mainHidden: true)): mainWindow.orderOut(nil)
        default: break
        }
        placement = next
        onChange?(next)
        return next
    }

    func update(title: String, paused: Bool) {
        panel?.title = title
        playButton?.title = paused ? "Play" : "Pause"
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        dock(in: panelSlot)
        placeholder.isHidden = false
        panel.makeKeyAndOrderFront(nil)
    }

    private func showMain() {
        dock(in: mainSlot)
        placeholder.isHidden = true
        panel?.orderOut(nil)
        mainWindow.deminiaturize(nil)
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func dock(in slot: NSView) {
        host.frame = slot.bounds
        host.autoresizingMask = [.width, .height]
        slot.addSubview(host)
    }

    private func makePanel() -> NSPanel {
        // Nonactivating: an activating panel leaves another app's fullscreen Space with the main window.
        let panel = FloatingVideoPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 416),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.tabbingMode = .disallowed
        panel.contentMinSize = NSSize(width: 420, height: 240)
        panel.backgroundColor = .black
        panel.title = mainWindow.title
        let play = button("Pause", #selector(playPressed))
        playButton = play
        let bar = NSStackView(views: [button("−5 s", #selector(seekBackward), label: "Seek back 5 seconds"), play,
                                      button("+5 s", #selector(seekForward), label: "Seek forward 5 seconds"),
                                      button("Return to Player", #selector(returnToMain))])
        bar.appearance = NSAppearance(named: .darkAqua)
        let content = NSView()
        for view in [panelSlot, bar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            panelSlot.leadingAnchor.constraint(equalTo: content.leadingAnchor), panelSlot.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            panelSlot.topAnchor.constraint(equalTo: content.topAnchor), panelSlot.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor), bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
        panel.contentView = content
        let aspect = host.bounds.height > 0 ? host.bounds.width / host.bounds.height : 16 / 9
        panel.setContentSize(NSSize(width: 640, height: 640 / aspect + 46))
        if let visible = (mainWindow.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 20, y: visible.maxY - 20))
        } else { panel.center() }
        return panel
    }

    private func button(_ title: String, _ action: Selector, label: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        if let label { button.setAccessibilityLabel(label) }
        return button
    }

    @objc private func playPressed() { togglePlay() }
    @objc private func seekBackward() { seek(-5) }
    @objc private func seekForward() { seek(5) }
    @objc private func returnToMain() { perform(.returnToMain) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        perform(.returnToMain)
        return false
    }
}

private final class FloatingVideoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
