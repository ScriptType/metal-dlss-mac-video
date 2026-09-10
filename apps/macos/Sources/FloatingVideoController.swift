import AppKit

/// A diagnostic AppKit presentation owner. It moves the existing mpv host;
/// it does not create a renderer, core, audio output or exported video stream.
@MainActor
final class FloatingVideoController: NSObject, NSWindowDelegate {
    private enum Phase: String { case home, entering, floating, restoring, terminating, finished }

    private let host: NSView
    private let mainSlot: NSView
    private let homeConstraints: [NSLayoutConstraint]
    private let mainWindow: NSWindow
    private let command: (String, Any?) -> Void
    private var phase = Phase.home
    private var transitioning = false
    private var mainFullscreenTransitioning = false
    private var playback: [String: Any] = [:]
    private var reason = "Diagnostic floating window; presentation has not been qualified."
    private var sequence: UInt64 = 0
    private var floatingSlot: NSView?
    private var floatingConstraints: [NSLayoutConstraint] = []
    private var placeholder: NSView?
    private var placeholderConstraints: [NSLayoutConstraint] = []
    private var controls: NSStackView?
    private var playButton: NSButton?
    private var backwardButton: NSButton?
    private var forwardButton: NSButton?
    private var returnButtons: [NSButton] = []
    private var entryChildren: [String] = []
    private var entryLayers: [String] = []
    private var lastRestore: [String: Any] = [:]

    private(set) var window: NSPanel?
    var onChange: (() -> Void)?
    var onEvent: ((String, [String: Any]) -> Void)?

    init(host: NSView, mainSlot: NSView, homeConstraints: [NSLayoutConstraint],
         mainWindow: NSWindow, command: @escaping (String, Any?) -> Void) {
        self.host = host
        self.mainSlot = mainSlot
        self.homeConstraints = homeConstraints
        self.mainWindow = mainWindow
        self.command = command
        super.init()
    }

    var isActive: Bool {
        guard let floatingSlot, let window else { return false }
        return host.superview === floatingSlot && host.window === window
    }

    var state: [String: Any] {
        let children = host.subviews.map(Self.identity)
        let layers = host.subviews.compactMap { $0.layer }.map(Self.identity)
        return [
            "implementation": "appkit-floating-video-prototype", "diagnosticOnly": true,
            "systemPictureInPicture": false, "phase": phase.rawValue, "active": isActive,
            "transitioning": transitioning, "mainFullscreenTransitioning": mainFullscreenTransitioning,
            "canEnter": phase == .home && entryBlockReason == nil,
            "reason": phase == .home ? (entryBlockReason ?? reason) : reason,
            "hostIdentity": Self.identity(host), "mainSlotIdentity": Self.identity(mainSlot),
            "mainWindow": Self.windowState(mainWindow), "floatingWindow": Self.windowState(window),
            "hostWindow": Self.windowState(host.window), "hostFrame": Self.rect(host.frame),
            "hostBounds": Self.rect(host.bounds), "homeConstraintsActive": homeConstraints.filter(\.isActive).count,
            "floatingConstraintsActive": floatingConstraints.filter(\.isActive).count,
            "nativeChildIdentities": children, "nativeChildLayerIdentities": layers,
            "entryChildIdentities": entryChildren, "entryChildLayerIdentities": entryLayers,
            "childIdentitiesMatchEntry": entryChildren.isEmpty ? NSNull() : (children == entryChildren) as Any,
            "childLayerIdentitiesMatchEntry": entryLayers.isEmpty ? NSNull() : (layers == entryLayers) as Any,
            "paused": playback["paused"] as? Bool ?? true,
            "positionSeconds": number("position").map { $0 as Any } ?? NSNull(),
            "lastRestore": lastRestore, "eventSequence": sequence,
            "presentationQualified": false, "physicalHDRQualified": false, "physicalAVSyncQualified": false
        ]
    }

    /// The main-window delegate supplies this optional transition flag, including
    /// failure callbacks. Updating ordinary playback state never publishes again.
    func updatePlaybackState(_ value: [String: Any]) {
        playback = value
        if let value = value["mainFullscreenTransitioning"] as? Bool { mainFullscreenTransitioning = value }
        refreshControls()
    }

    func toggle() {
        guard acceptsTransitions else { return }
        if isActive { restore(activateMain: true) } else { enter() }
    }

    func restore(activateMain: Bool) {
        guard acceptsTransitions, isActive, let window else { return }
        transitioning = true
        phase = .restoring
        let visibleBefore = mainWindow.isVisible
        let minimizedBefore = mainWindow.isMiniaturized
        moveHome()
        window.orderOut(nil)
        self.window = nil
        window.delegate = nil
        window.contentView = nil
        floatingSlot = nil
        clearControls()
        phase = .home
        // A close or background restore must not unhide or deminiaturize the
        // main window. Only the explicit Return/toggle action requests this.
        if activateMain {
            mainWindow.deminiaturize(nil)
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        lastRestore = ["activateMain": activateMain, "mainVisibleBefore": visibleBefore,
            "mainMinimizedBefore": minimizedBefore, "mainVisibleAfter": mainWindow.isVisible,
            "mainMinimizedAfter": mainWindow.isMiniaturized]
        reason = "The existing video host is back in the main window."
        transitioning = false
        emit("floating-video-restored")
    }

    /// Keep the host, panel and native child/layer alive while mpv asynchronously
    /// destroys its worker. This method deliberately does not move or detach them.
    func prepareForTermination() {
        guard phase != .terminating, phase != .finished else { return }
        phase = .terminating
        reason = "Waiting for native worker destruction; the video host remains retained."
        controls?.isHidden = true
        returnButtons.forEach { $0.isEnabled = false; $0.isHidden = true }
        refreshControls()
        emit("floating-video-termination-prepared")
    }

    /// Call only after the native worker has stopped and detached its child view.
    func finishTermination() {
        guard phase == .terminating else { return }
        moveHome()
        window?.delegate = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        floatingSlot = nil
        clearControls()
        phase = .finished
        transitioning = false
        reason = "Native worker stopped; the floating presentation owner is finished."
        emit("floating-video-termination-finished")
    }

    private var acceptsTransitions: Bool { !transitioning && phase != .terminating && phase != .finished }

    private var entryBlockReason: String? {
        if !acceptsTransitions { return "A presentation transition or termination is in progress." }
        if mainFullscreenTransitioning || mainWindow.styleMask.contains(.fullScreen) {
            return "This prototype requires the main window to finish leaving full screen before entry."
        }
        if host.superview !== mainSlot || mainSlot.window !== mainWindow || host.window !== mainWindow {
            return "The existing video host is not attached to its expected main-window slot."
        }
        if host.translatesAutoresizingMaskIntoConstraints || homeConstraints.count != 4 || !homeConstraints.allSatisfy(\.isActive) {
            return "The four retained home constraints must be active before entry."
        }
        if !host.bounds.width.isFinite || !host.bounds.height.isFinite || host.bounds.width <= 0 || host.bounds.height <= 0 {
            return "The video host needs a valid layout before it can move."
        }
        return nil
    }

    private func enter() {
        if let blocked = entryBlockReason {
            reason = blocked
            emit("floating-video-entry-rejected")
            return
        }
        transitioning = true
        phase = .entering
        entryChildren = host.subviews.map(Self.identity)
        entryLayers = host.subviews.compactMap { $0.layer }.map(Self.identity)

        let panel = FloatingVideoPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 416),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.tabbingMode = .disallowed
        panel.contentMinSize = NSSize(width: 420, height: 240)
        panel.backgroundColor = .black
        panel.setAccessibilityLabel("Floating video")
        panel.identifier = NSUserInterfaceItemIdentifier("HDRPlayer.floatingVideo")
        let content = NSView()
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        let bar = makeControls()
        content.addSubview(slot)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            slot.leadingAnchor.constraint(equalTo: content.leadingAnchor), slot.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            slot.topAnchor.constraint(equalTo: content.topAnchor), slot.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.centerXAnchor.constraint(equalTo: content.centerXAnchor), bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            bar.heightAnchor.constraint(equalToConstant: 36),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -8)
        ])
        panel.contentView = content
        window = panel
        floatingSlot = slot
        controls = bar
        refreshControls()
        place(panel)

        NSLayoutConstraint.deactivate(homeConstraints)
        host.removeFromSuperview()
        slot.addSubview(host)
        floatingConstraints = Self.edges(host, in: slot)
        NSLayoutConstraint.activate(floatingConstraints)
        installPlaceholder()
        content.layoutSubtreeIfNeeded()
        mainSlot.layoutSubtreeIfNeeded()
        phase = .floating
        panel.makeKeyAndOrderFront(nil)
        reason = "App-owned floating video using the existing host; presentation remains unqualified."
        transitioning = false
        refreshControls()
        emit("floating-video-entered")
    }

    private func moveHome() {
        NSLayoutConstraint.deactivate(floatingConstraints)
        floatingConstraints = []
        NSLayoutConstraint.deactivate(placeholderConstraints)
        placeholderConstraints = []
        placeholder?.removeFromSuperview()
        placeholder = nil
        if host.superview !== mainSlot {
            host.removeFromSuperview()
            mainSlot.addSubview(host)
        }
        NSLayoutConstraint.activate(homeConstraints)
        mainSlot.layoutSubtreeIfNeeded()
    }

    private func installPlaceholder() {
        let label = NSTextField(labelWithString: "Video is in the floating window.")
        let button = makeButton("Return to Player", action: #selector(returnToPlayer), identifier: "returnPlaceholder")
        returnButtons.append(button)
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        mainSlot.addSubview(stack)
        placeholderConstraints = [stack.centerXAnchor.constraint(equalTo: mainSlot.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: mainSlot.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: mainSlot.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: mainSlot.trailingAnchor, constant: -12)]
        NSLayoutConstraint.activate(placeholderConstraints)
        placeholder = stack
    }

    private func makeControls() -> NSStackView {
        let back = makeButton("−5 s", action: #selector(seekBackward), identifier: "seekBackward")
        back.setAccessibilityLabel("Seek backward 5 seconds")
        let play = makeButton("Play", action: #selector(togglePlay), identifier: "playPause")
        let forward = makeButton("+5 s", action: #selector(seekForward), identifier: "seekForward")
        forward.setAccessibilityLabel("Seek forward 5 seconds")
        let restore = makeButton("Return to Player", action: #selector(returnToPlayer), identifier: "return")
        backwardButton = back; playButton = play; forwardButton = forward; returnButtons = [restore]
        let bar = NSStackView(views: [back, play, forward, restore])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }

    private func makeButton(_ title: String, action: Selector, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier("HDRPlayer.floatingVideo.\(identifier)")
        button.setAccessibilityIdentifier("HDRPlayer.floatingVideo.\(identifier)")
        button.setAccessibilityLabel(title)
        return button
    }

    private func refreshControls() {
        let paused = playback["paused"] as? Bool ?? true
        playButton?.title = paused ? "Play" : "Pause"
        playButton?.setAccessibilityLabel(paused ? "Play video" : "Pause video")
        let hasMedia = !(playback["source"] as? String ?? "").isEmpty
        playButton?.isEnabled = acceptsTransitions && hasMedia
        let canSeek = acceptsTransitions && hasMedia && number("position") != nil
        backwardButton?.isEnabled = canSeek
        forwardButton?.isEnabled = canSeek
        if let title = playback["title"] as? String, !title.isEmpty { window?.title = "Floating Video — \(title)" }
        else { window?.title = "Floating Video" }
    }

    private func clearControls() {
        controls = nil; playButton = nil; backwardButton = nil; forwardButton = nil; returnButtons = []
    }

    private func place(_ panel: NSPanel) {
        guard let screen = mainWindow.screen ?? NSScreen.main else { panel.center(); return }
        let visible = screen.visibleFrame
        let width = min(640, max(420, visible.width - 40))
        let aspect = host.bounds.width / host.bounds.height
        panel.setContentSize(NSSize(width: width, height: min(480, max(240, width / aspect + 46))))
        panel.setFrameOrigin(NSPoint(x: max(visible.minX, visible.maxX - panel.frame.width - 20),
                                     y: max(visible.minY, visible.maxY - panel.frame.height - 20)))
    }

    private func number(_ key: String) -> Double? {
        guard let value = (playback[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
        return value
    }

    @objc private func togglePlay() {
        guard acceptsTransitions, isActive, playButton?.isEnabled == true else { return }
        command("togglePause", nil)
        emit("floating-video-transport", extra: ["command": "togglePause"])
    }
    @objc private func seekBackward() { seek(by: -5) }
    @objc private func seekForward() { seek(by: 5) }
    private func seek(by delta: Double) {
        guard acceptsTransitions, isActive, backwardButton?.isEnabled == true, let position = number("position") else { return }
        var target = max(0, position + delta)
        if let duration = number("duration"), duration > 0 { target = min(duration, target) }
        guard target.isFinite else { return }
        command("seek", target)
        emit("floating-video-transport", extra: ["command": "seek", "positionSeconds": target])
    }
    @objc private func returnToPlayer() { restore(activateMain: true) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window { restore(activateMain: false) }
        return false
    }
    func windowDidResize(_ notification: Notification) { windowEvent(notification, "floating-video-resized") }
    func windowDidChangeScreen(_ notification: Notification) { windowEvent(notification, "floating-video-screen-changed") }
    func windowDidChangeBackingProperties(_ notification: Notification) { windowEvent(notification, "floating-video-backing-changed") }
    func windowDidBecomeKey(_ notification: Notification) { windowEvent(notification, "floating-video-focused") }
    func windowDidResignKey(_ notification: Notification) { windowEvent(notification, "floating-video-unfocused") }
    private func windowEvent(_ notification: Notification, _ name: String) {
        guard let sender = notification.object as? NSWindow, sender === window,
              phase == .floating, !transitioning else { return }
        emit(name)
    }

    private func emit(_ name: String, extra: [String: Any] = [:]) {
        sequence &+= 1
        var payload = state
        payload["hostUptimeSeconds"] = ProcessInfo.processInfo.systemUptime
        for (key, value) in extra { payload[key] = value }
        onEvent?(name, payload)
        onChange?()
    }

    private static func edges(_ view: NSView, in parent: NSView) -> [NSLayoutConstraint] {
        [view.leadingAnchor.constraint(equalTo: parent.leadingAnchor), view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
         view.topAnchor.constraint(equalTo: parent.topAnchor), view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)]
    }
    private static func identity(_ value: AnyObject) -> String { String(describing: ObjectIdentifier(value)) }
    private static func rect(_ value: NSRect) -> [String: Double] {
        ["x": value.origin.x, "y": value.origin.y, "width": value.width, "height": value.height]
    }
    private static func windowState(_ window: NSWindow?) -> [String: Any] {
        guard let window else { return ["attached": false] }
        return ["attached": true, "identity": identity(window), "number": window.windowNumber,
            "visible": window.isVisible, "minimized": window.isMiniaturized, "key": window.isKeyWindow,
            "onActiveSpace": window.isOnActiveSpace, "occlusionVisible": window.occlusionState.contains(.visible),
            "frame": rect(window.frame), "backingScale": window.backingScaleFactor,
            "screen": window.screen?.localizedName ?? "Unknown"]
    }
}

@MainActor
private final class FloatingVideoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
