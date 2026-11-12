import AppKit
import IOKit.pwr_mgt
import LunaProto

/// Borderless fullscreen window that can still become key so Esc/Cmd-Q work.
final class ReceiverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class VideoHostView: NSView {
    let videoLayer: CALayer

    init(videoLayer: CALayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)
        // Layer-hosting view: the layer must be set before wantsLayer.
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }
}

final class ReceiverAppDelegate: NSObject, NSApplicationDelegate {
    private enum Mode { case fullscreen, windowed }

    private var window: ReceiverWindow!
    private let pipeline = VideoPipeline()
    private let server = ReceiverServer()
    private let statusField = NSTextField(labelWithString: "Starting…")
    private var listeningText = "starting…"
    private var sleepAssertion: IOPMAssertionID = 0
    private var keyMonitor: Any?
    private var isStreaming = false
    private var cursorHidden = false
    private var mode: Mode = .fullscreen
    private var streamSize: CGSize?
    private var streamHello: (width: Int, height: Int, fps: Int, name: String)?
    private var modeMenuItem: NSMenuItem!
    private var fullscreenObserver: NSObjectProtocol?
    // Set while waiting for a green-button (Spaces) fullscreen exit animation
    // to finish before taking over the screen borderless.
    private var pendingLunaFullscreen = false

    /// `--headless`: run the server without any window (dev harnesses).
    private var headless: Bool {
        CommandLine.arguments.contains("--headless")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let loopbackOnly = CommandLine.arguments.contains("--loopback-only")
        server.onMessage = { [weak self] message, label in
            self?.handle(message, via: label) ?? false
        }
        server.onDisconnected = { [weak self] in
            guard let self else { return }
            self.pipeline.reset()
            self.streamHello = nil
            self.isStreaming = false
            guard !self.headless else { return }
            self.preventDisplaySleep(false)
            self.showWaiting()
        }
        if headless {
            server.start(loopbackOnly: loopbackOnly)
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            lunaLog("luna: no screen available for the receiver")
            NSApp.terminate(nil)
            return
        }

        window = ReceiverWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false

        let host = VideoHostView(videoLayer: pipeline.layer)
        window.contentView = host

        statusField.textColor = .white
        statusField.font = .systemFont(ofSize: 24, weight: .light)
        statusField.alignment = .center
        statusField.maximumNumberOfLines = 0
        statusField.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(statusField)
        NSLayoutConstraint.activate([
            statusField.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            statusField.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                guard let self else { return event }
                if self.mode == .windowed {
                    self.setMode(.fullscreen)
                } else {
                    NSApp.terminate(nil)
                }
                return nil
            }
            return event
        }

        fullscreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self, self.pendingLunaFullscreen else { return }
            self.pendingLunaFullscreen = false
            self.setMode(.fullscreen)
        }

        server.onListening = { [weak self] address in
            guard let self else { return }
            self.listeningText = address
            self.showWaiting()
        }
        server.start(loopbackOnly: loopbackOnly)
        showWaiting()
    }

    func applicationWillTerminate(_ notification: Notification) {
        preventDisplaySleep(false)
        showCursor()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let fullscreenObserver { NotificationCenter.default.removeObserver(fullscreenObserver) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // NSCursor.hide only holds while the app is frontmost, so re-assert it
    // whenever we regain focus mid-stream and release it when we lose focus
    // (keeps the hide/unhide counter balanced).
    func applicationDidBecomeActive(_ notification: Notification) {
        if isStreaming, mode == .fullscreen { hideCursor() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        showCursor()
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit Luna Receiver",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        // Uppercase key equivalent = ⌘⇧F, reachable even while the menu bar
        // (and cursor) are hidden in fullscreen.
        modeMenuItem = viewMenu.addItem(
            withTitle: "Switch to Windowed Mode",
            action: #selector(toggleWindowMode), keyEquivalent: "F")
        modeMenuItem.target = self
        viewMenuItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleWindowMode() {
        setMode(mode == .fullscreen ? .windowed : .fullscreen)
    }

    private func setMode(_ newMode: Mode) {
        guard let window, newMode != mode else { return }

        if newMode == .fullscreen, window.styleMask.contains(.fullScreen) {
            // In green-button (Spaces) fullscreen: leave it first, then take
            // over borderless once the exit animation completes.
            pendingLunaFullscreen = true
            window.toggleFullScreen(nil)
            return
        }

        mode = newMode
        switch newMode {
        case .windowed:
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = "Luna Receiver"
            window.collectionBehavior = [.fullScreenPrimary]
            let avail = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? window.frame
            let aspect = streamSize ?? CGSize(width: 16, height: 9)
            window.contentAspectRatio = aspect
            let scale = min(0.7 * avail.width / aspect.width, 0.7 * avail.height / aspect.height)
            window.setContentSize(NSSize(width: aspect.width * scale, height: aspect.height * scale))
            window.center()
        case .fullscreen:
            window.styleMask = .borderless
            if let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first {
                window.setFrame(screen.frame, display: true)
            }
        }
        modeMenuItem.title =
            mode == .fullscreen ? "Switch to Windowed Mode" : "Switch to Full Screen Mode"
        applyChrome()
        if !isStreaming { showWaiting() }
        window.makeKeyAndOrderFront(nil)
    }

    private func handle(_ message: LunaMessage, via label: String?) -> Bool {
        switch message {
        case .hello(let w, let h, let fps, let name):
            guard streamHello == nil, VideoPipeline.supportsSize(width: w, height: h),
                  (1...240).contains(fps), name.utf8.count <= 256 else { return false }
            streamHello = (w, h, fps, name)
            guard !headless else { return false }
            let via = label.map { " via \($0)" } ?? ""
            statusField.stringValue = "Connected to \(name)\(via)…"
            streamSize = CGSize(width: CGFloat(w), height: CGFloat(h))
            if mode == .windowed, let size = streamSize {
                window.contentAspectRatio = size
                let maxHeight = window.screen?.visibleFrame.height ?? window.frame.height
                let scale = min(window.contentLayoutRect.width / size.width, maxHeight / size.height)
                window.setContentSize(NSSize(width: size.width * scale, height: size.height * scale))
            }
        case .paramSets(let sps, let pps):
            guard streamHello != nil else { return false }
            pipeline.setParameterSets(sps: sps, pps: pps)
        case .frame(let pts, let keyframe, let data):
            guard let hello = streamHello,
                  pipeline.enqueue(ptsMicros: pts, keyframe: keyframe, data: data) else { return false }
            if !isStreaming {
                lunaLog("luna: sender %@ streaming %dx%d@%d", hello.name, hello.width, hello.height, hello.fps)
                isStreaming = true
                if !headless {
                    statusField.isHidden = true
                    applyChrome()
                    preventDisplaySleep(true)
                }
            }
            return true
        case .capture, .caps, .camParamSets, .camFrame, .audio, .captureStatus:
            break
        }
        return false
    }

    private func showWaiting() {
        statusField.isHidden = false
        let hint = mode == .fullscreen ? "Press Esc to quit" : "Press Esc for full screen"
        statusField.stringValue =
            "Luna Receiver — waiting for a sender\n\(listeningText)\n\n\(hint)"
        isStreaming = false
        applyChrome()
    }

    /// The immersive chrome (hidden menu bar/Dock/cursor, above-menu window
    /// level) applies only while streaming in fullscreen mode; windowed mode
    /// always behaves like a regular app so the iMac's own keyboard and mouse
    /// stay usable (e.g. for screenshots of the streamed content).
    private func applyChrome() {
        if isStreaming, mode == .fullscreen {
            NSApp.presentationOptions = [.autoHideDock, .autoHideMenuBar]
            window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            if NSApp.isActive { hideCursor() }
        } else {
            NSApp.presentationOptions = []
            window.level = .normal
            showCursor()
        }
    }

    private func hideCursor() {
        guard !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    private func showCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    private func preventDisplaySleep(_ prevent: Bool) {
        if prevent, sleepAssertion == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Luna is receiving a display stream" as CFString,
                &sleepAssertion
            )
        } else if !prevent, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
        }
    }
}

// Keep AppKit from injecting "Show Tab Bar" / "Enter Full Screen" items into
// the View menu once the window turns titled; must run before the app exists.
UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
NSWindow.allowsAutomaticWindowTabbing = false

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = ReceiverAppDelegate()
app.delegate = delegate
app.run()
