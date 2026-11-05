import AppKit
import ApplicationServices
import SuperbarKit

/// One screen's free area for snapping, worked out on the main thread and handed to a worker.
/// AX coordinates (origin at the top left of the main screen).
nonisolated struct SnapScreen: Sendable {
    let screen: CGRect
    let area: CGRect
}

/// Snaps a window to the whole free area, a half, a quarter, or a third of its screen,
/// above Superbar and beside the Dock. From the ⌃⌥ shortcuts (the front window) and from
/// an app button's menu (that app's window). Needs Accessibility.
final class WindowSnapper {
    static let shared = WindowSnapper()

    /// Set by AppDelegate: how much of a screen's bottom Superbar keeps (0 while it hides).
    var reservedHeight: (NSScreen) -> CGFloat = { _ in 0 }
    /// Set by AppDelegate: Accessibility is off, so say why nothing happened.
    var onNeedsAccessibility: () -> Void = {}

    func screens() -> [SnapScreen] {
        NSScreen.screens.map { screen in
            let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let v = screen.visibleFrame
            let visible = CGRect(x: v.minX, y: mainHeight - v.maxY, width: v.width, height: v.height)
            return SnapScreen(screen: screen.cgFrame,
                              area: SnapArea.of(screen: screen.cgFrame, visible: visible, barHeight: reservedHeight(screen)))
        }
    }

    /// The shortcut: the front app's focused window.
    func snapFrontWindow(_ snap: Snap) {
        guard AXIsProcessTrusted() else { onNeedsAccessibility(); return }
        // Never Superbar's own windows: AX on our own pid off the main thread traps in AppKit.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else { return }
        let screens = screens()
        Task { _ = await SnapWorker.snap(snap, pid: pid, fallback: nil, screens: screens, bringForward: false) }
    }

    /// The button menu: the app's focused window, else its first open one; then bring it forward.
    func snap(_ snap: Snap, pid: pid_t, windows: [AppWindow]) {
        guard AXIsProcessTrusted() else { onNeedsAccessibility(); return }
        guard pid != getpid() else { return }
        let screens = screens()
        let fallback = (windows.first { !$0.isMinimized } ?? windows.first).map { AXRef(element: $0.element) }
        Task { _ = await SnapWorker.snap(snap, pid: pid, fallback: fallback, screens: screens, bringForward: true) }
    }
}

/// The AX work, off the main thread: a hung app can block each call up to the timeout.
nonisolated enum SnapWorker {
    @concurrent
    static func snap(_ snap: Snap, pid: pid_t, fallback: AXRef?, screens: [SnapScreen], bringForward: Bool) async -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let focused: AXUIElement? = AXReader.value(app, kAXFocusedWindowAttribute)
            ?? AXReader.value(app, kAXMainWindowAttribute)
        guard let window = focused ?? fallback?.element else { return false }
        let done = apply(snap, to: window, app: app, screens: screens)
        if bringForward {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            await WindowActions.activate(pid: pid)
        }
        return done
    }

    static func apply(_ snap: Snap, to window: AXUIElement, app: AXUIElement, screens: [SnapScreen]) -> Bool {
        AXUIElementSetMessagingTimeout(window, 1.0)
        // A native full-screen window owns its Space; it can't be moved.
        if let full: Bool = AXReader.value(window, "AXFullScreen"), full { return false }
        if let minimized: Bool = AXReader.value(window, kAXMinimizedAttribute), minimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        guard let frame = frame(of: window) else { return false }
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        guard let target = screens.first(where: { $0.screen.contains(middle) })
                ?? screens.max(by: { overlap($0.screen, frame) < overlap($1.screen, frame) }) else { return false }
        let area = target.area
        let goal = snap.frame(in: area)

        // Chrome, Electron, and others animate or fight AX resizes while this is on.
        let enhanced: Bool? = AXReader.value(app, "AXEnhancedUserInterface")
        if enhanced == true { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced == true { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }

        // Move first, so the new size isn't cut short by the screen edge; then size; then
        // move again, as some apps shift the window while resizing.
        setPosition(window, goal.origin)
        setSize(window, goal.size)
        setPosition(window, goal.origin)

        // An app with a minimum size may stay bigger than the cell. Keep it inside the
        // free area, so the bar never covers its content.
        if let result = self.frame(of: window), !area.contains(result.insetBy(dx: 1, dy: 1)) {
            var origin = result.origin
            origin.x = min(max(origin.x, area.minX), max(area.maxX - result.width, area.minX))
            origin.y = min(max(origin.y, area.minY), max(area.maxY - result.height, area.minY))
            if origin != result.origin { setPosition(window, origin) }
            if result.height > area.height || result.width > area.width {
                setSize(window, CGSize(width: min(result.width, area.width), height: min(result.height, area.height)))
            }
        }
        return true
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let p: AXValue = AXReader.value(window, kAXPositionAttribute),
              let s: AXValue = AXReader.value(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(p, .cgPoint, &origin)
        AXValueGetValue(s, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }
}
