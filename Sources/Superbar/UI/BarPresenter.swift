import AppKit
import ApplicationServices
import Observation
import SuperbarKit

/// Is the main screen showing a full-screen app? The Space type from SkyLight first;
/// then AXFullScreen (needs Accessibility); then a window covering the whole screen.
/// Off the main thread: the AX fallback can block on a hung app.
nonisolated enum FullScreenDetector {
    @concurrent
    static func mainScreenIsFullScreen(screenSize: CGSize, frontPID: pid_t?) async -> Bool {
        // Best: ask the window server whether the main display shows a full-screen Space.
        if let answer = Private.mainDisplayIsInFullScreenSpace() { return answer }
        let screen = CGRect(origin: .zero, size: screenSize)   // the main screen in CG coordinates
        let windows = onScreenWindows()
        // The app on top of the main screen: the owner of its front normal window.
        let topPID = windows.first { w in
            w.layer == 0 && screen.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY))
        }?.ownerPID
        let pids = [topPID, frontPID].compactMap { $0 }
        if AXIsProcessTrusted() {
            for pid in Set(pids) where axFullScreenWindow(pid: pid, on: screen) { return true }
            return false
        }
        // Without Accessibility: a window that covers the whole main screen.
        return pids.contains { ScreenCover.isFullScreen(windows, frontPID: $0, screen: screen) }
    }

    /// AXFullScreen on any of the app's windows on this Space that sits on the main screen.
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

/// Places the bar, and over a full-screen app hides it until the pointer rests on
/// the bottom edge (EdgeReveal), like the Dock.
@Observable
final class BarPresenter {
    private(set) var isFullScreen = false
    private(set) var isShown = true

    @ObservationIgnored private let panel: GlassPanel
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored var heldOpen: () -> Bool = { false }
    @ObservationIgnored private var reveal = EdgeReveal()
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var checkTimer: Timer?
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var checking = false
    /// Snapshots and the self-test drive the state by hand.
    @ObservationIgnored var detectionEnabled = true

    init(panel: GlassPanel, settings: AppSettings) {
        self.panel = panel
        self.settings = settings
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SuperbarMain.delegate.barPresenter?.checkSoon() }
            }
        }
        // A context menu from the bar keeps it up while open.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SuperbarMain.delegate.barPresenter?.menuOpen = true }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SuperbarMain.delegate.barPresenter?.menuOpen = false }
        }
        // Some apps go full screen without a Space change (games with a borderless window).
        let t = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { SuperbarMain.delegate.barPresenter?.check() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        checkTimer = t
        check()
    }

    // MARK: Frames

    private var screen: NSScreen? { NSScreen.screens.first }

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
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            check()
        }
    }

    func check() {
        guard detectionEnabled, !checking, let size = screen?.frame.size else { return }
        checking = true
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task {
            let on = await FullScreenDetector.mainScreenIsFullScreen(screenSize: size, frontPID: front)
            checking = false
            if detectionEnabled { setFullScreen(on) }
        }
    }

    func setFullScreen(_ on: Bool) {
        guard on != isFullScreen else { return }
        isFullScreen = on
        reveal.reset()
        if on {
            slide(show: heldOpen())
            startPolling()
        } else {
            stopPolling()
            slide(show: true)
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { SuperbarMain.delegate.barPresenter?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)   // .common: keeps running while a menu tracks
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func poll(pointer: NSPoint = NSEvent.mouseLocation, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard isFullScreen, let frame = screen?.frame else { return }
        let onMain = pointer.x >= frame.minX && pointer.x < frame.maxX && pointer.y >= frame.minY && pointer.y < frame.maxY
        let action = reveal.update(pointerHeight: onMain ? Double(pointer.y - frame.minY) : nil,
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
        } completionHandler: {
            MainActor.assumeIsolated {
                guard let presenter = SuperbarMain.delegate.barPresenter, !presenter.isShown else { return }
                presenter.panel.orderOut(nil)
            }
        }
    }
}
