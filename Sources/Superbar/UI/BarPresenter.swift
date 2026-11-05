import AppKit
import ApplicationServices
import Observation
import SuperbarKit

/// Is a screen showing a full-screen app? The Space type from SkyLight first;
/// then AXFullScreen (needs Accessibility); then a window covering the whole screen.
/// Off the main thread: the AX fallback can block on a hung app.
nonisolated enum FullScreenDetector {
    /// `screen`: the screen in CG coordinates (origin at the top left of the main screen).
    @concurrent
    static func isFullScreen(display: CGDirectDisplayID, screen: CGRect, frontPID: pid_t?) async -> Bool {
        // Best: ask the window server whether the display shows a full-screen Space.
        if let answer = Private.displayIsInFullScreenSpace(display) { return answer }
        let windows = onScreenWindows()
        // The app on top of this screen: the owner of its front normal window.
        let topPID = windows.first { w in
            w.layer == 0 && screen.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY))
        }?.ownerPID
        let pids = [topPID, frontPID].compactMap { $0 }
        if AXIsProcessTrusted() {
            for pid in Set(pids) where axFullScreenWindow(pid: pid, on: screen) { return true }
            return false
        }
        // Without Accessibility: a window that covers the whole screen.
        return pids.contains { ScreenCover.isFullScreen(windows, frontPID: $0, screen: screen) }
    }

    /// AXFullScreen on any of the app's windows on this Space that sits on this screen.
    private static func axFullScreenWindow(pid: pid_t, on screen: CGRect) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let windows: [AXUIElement] = AXReader.value(app, kAXWindowsAttribute) else { return false }
        for window in windows {
            guard let full: Bool = AXReader.value(window, "AXFullScreen"), full else { continue }
            var origin = CGPoint.zero
            if let raw: AXValue = AXReader.value(window, kAXPositionAttribute) {
                AXValueGetValue(raw, .cgPoint, &origin)
            }
            if screen.insetBy(dx: -1, dy: -1).contains(CGPoint(x: origin.x + 1, y: origin.y + 1)) { return true }
        }
        return false
    }

    /// On-screen windows, front to back. Bounds, layer, and owner need no permission.
    private static func onScreenWindows() -> [ScreenCover.Window] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let me = getpid()
        return info.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let layer = w[kCGWindowLayer as String] as? Int,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            return ScreenCover.Window(bounds: bounds, layer: layer, ownerPID: pid)
        }
    }
}

/// Places one display's bar, and hides it when Settings says auto-hide or always hide,
/// or while that display shows a full-screen app. A hidden bar comes up when the pointer
/// rests on the bottom edge (not in always hide) or the Start menu or a popover opens.
@Observable
final class BarPresenter {
    private(set) var isFullScreen = false
    private(set) var isShown = true
    let displayID: CGDirectDisplayID
    let panel: GlassPanel

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored var heldOpen: () -> Bool = { false }
    /// Called when this display enters or leaves full screen (WindowFitter).
    @ObservationIgnored var onFullScreenChange: () -> Void = {}
    @ObservationIgnored private var reveal = EdgeReveal()
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var checkTimer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var checking = false
    /// Snapshots and the self-test drive the state by hand.
    @ObservationIgnored var detectionEnabled = true

    init(panel: GlassPanel, settings: AppSettings, displayID: CGDirectDisplayID) {
        self.panel = panel
        self.settings = settings
        self.displayID = displayID
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observe(workspace, name) { $0.checkSoon() }
        }
        // A context menu from the bar keeps it up while open.
        observe(.default, NSMenu.didBeginTrackingNotification) { $0.menuOpen = true }
        observe(.default, NSMenu.didEndTrackingNotification) { $0.menuOpen = false }
        // Some apps go full screen without a Space change (games with a borderless window).
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        checkTimer = t
        applyVisibility()
        check()
    }

    /// The display went away: stop everything and remove the bar.
    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        checkTimer?.invalidate()
        checkTimer = nil
        stopPolling()
        detectionEnabled = false
        panel.orderOut(nil)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor @Sendable (BarPresenter) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, token))
    }

    // MARK: Frames

    var screen: NSScreen? { NSScreen.screens.first { $0.displayID == displayID } }

    private var shownFrame: NSRect {
        guard let f = screen?.frame else { return panel.frame }
        return NSRect(x: f.minX, y: f.minY, width: f.width, height: settings.metrics.height)
    }

    private var hiddenFrame: NSRect { shownFrame.offsetBy(dx: 0, dy: -settings.metrics.height) }

    /// Puts the bar where its state says, without animation (launch, screen change, size change).
    func layout() {
        panel.setFrame(isShown ? shownFrame : hiddenFrame, display: true)
        panel.alphaValue = isShown ? 1 : 0
        if isShown { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    // MARK: Full screen

    /// Right after a Space change, and again once the full-screen animation has settled.
    func checkSoon() {
        check()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.check()
        }
    }

    func check() {
        guard detectionEnabled, !checking, let rect = screen?.cgFrame else { return }
        checking = true
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let display = displayID
        Task { [weak self] in
            let on = await FullScreenDetector.isFullScreen(display: display, screen: rect, frontPID: front)
            guard let self else { return }
            checking = false
            if detectionEnabled { setFullScreen(on) }
        }
    }

    func setFullScreen(_ on: Bool) {
        guard on != isFullScreen else { return }
        isFullScreen = on
        applyVisibility(restart: true)
        onFullScreenChange()
    }

    // MARK: Hiding

    /// Is the bar hidden until revealed right now?
    var hides: Bool { settings.barVisibility.hides(fullScreen: isFullScreen) }

    /// After a Settings change or a full-screen change: hide or show, and poll the
    /// pointer only while hiding. `restart` hides a revealed bar again (full screen starts).
    func applyVisibility(restart: Bool = false) {
        reveal.hideDelay = settings.autoHideDelay
        reveal.edgeEnabled = settings.barVisibility.edgeReveals
        if hides {
            if restart || pollTimer == nil {
                reveal.reset()
                if heldOpen() { _ = reveal.update(pointerHeight: nil, barHeight: 0, heldOpen: true, now: 0) }
                slide(show: reveal.isRevealed)
            }
            startPolling()
        } else {
            stopPolling()
            reveal.reset()
            slide(show: true)
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            // Off while the self-test feeds the pointer and the clock by hand.
            MainActor.assumeIsolated { if self?.detectionEnabled == true { self?.poll() } }
        }
        RunLoop.main.add(t, forMode: .common)   // .common: keeps running while a menu tracks
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func poll(pointer: NSPoint = NSEvent.mouseLocation, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard hides, let frame = screen?.frame else { return }
        let onScreen = pointer.x >= frame.minX && pointer.x < frame.maxX && pointer.y >= frame.minY && pointer.y < frame.maxY
        let action = reveal.update(pointerHeight: onScreen ? Double(pointer.y - frame.minY) : nil,
                                   barHeight: Double(settings.metrics.height),
                                   heldOpen: heldOpen() || menuOpen, now: now)
        switch action {
        case .show: slide(show: true)
        case .hide: slide(show: false)
        case .none: break
        }
    }

    private func slide(show: Bool) {
        guard show != isShown else { return }
        isShown = show
        if show {
            panel.setFrame(hiddenFrame, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        let target = show ? shownFrame : hiddenFrame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: show ? .easeOut : .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}
