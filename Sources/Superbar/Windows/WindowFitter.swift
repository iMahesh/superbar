import AppKit
import ApplicationServices
import SuperbarKit

/// An AX element handed from the observer thread to the main actor and on to a worker.
/// `@unchecked Sendable`: AXUIElement is an immutable CF reference the AX API lets any thread use.
nonisolated struct AXRef: @unchecked Sendable {
    let element: AXUIElement
}

/// Where windows may go on one screen: below its menu bar and above its Superbar.
/// AX coordinates (origin at the top left of the main screen).
nonisolated struct FitArea: Sendable {
    let top: CGFloat
    let bottom: CGFloat
    /// The whole screen, to tell which screen a window is on.
    let screen: CGRect

    @MainActor
    static func of(_ screen: NSScreen, barHeight: CGFloat) -> FitArea {
        let rect = screen.cgFrame
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return FitArea(top: rect.minY + menuBar, bottom: rect.maxY - barHeight, screen: rect)
    }
}

/// Moves or trims windows that reach under Superbar (WorkArea.fit). Needs Accessibility.
/// Runs when a window opens or resizes, when an app launches or comes to the front, and
/// when the bar or the screen changes. A window being dragged is never fought: moves
/// alone do not trigger it.
final class WindowFitter {
    static let shared = WindowFitter()

    /// Set by AppDelegate: the setting is on.
    var isActive: () -> Bool = { false }
    /// Set by AppDelegate: one area per screen whose bar is not over a full-screen app.
    var areas: () -> [FitArea] = { [] }

    /// Per window, the times Superbar changed it, to stop a tug of war with an app that
    /// resizes itself back: at most 3 changes in 2 s, then hands off for 30 s.
    private var changes: [CFHashCode: [Date]] = [:]
    private var restingUntil: [CFHashCode: Date] = [:]

    /// One window, after AX said it opened or resized.
    func windowChanged(_ ref: AXRef) {
        var pid: pid_t = 0
        AXUIElementGetPid(ref.element, &pid)
        guard pid != getpid(), isActive(), AXIsProcessTrusted(), case let area = areas(), !area.isEmpty else { return }
        let key = CFHash(ref.element)
        let now = Date()
        if let until = restingUntil[key], until > now { return }
        Task {
            guard await FitWorker.fit(ref, in: area) else { return }
            let recent = (changes[key] ?? []).filter { now.timeIntervalSince($0) < 2 } + [now]
            changes[key] = recent
            if recent.count >= 3 {
                restingUntil[key] = now.addingTimeInterval(30)
                changes[key] = nil
            }
        }
    }

    /// Every window of one app.
    func scan(pid: pid_t) {
        // Never Superbar itself: AppKit traps when its own windows are set through AX
        // off the main thread (Settings is activated, and so scanned, like any app).
        guard pid != getpid(), isActive(), AXIsProcessTrusted(), case let area = areas(), !area.isEmpty else { return }
        Task { await FitWorker.scan(pid: pid, in: area) }
    }

    /// Every window of every running app.
    func scanAll() {
        guard isActive(), AXIsProcessTrusted() else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            scan(pid: app.processIdentifier)
        }
        if changes.count > 200 { changes.removeAll(); restingUntil.removeAll() }
    }
}

/// The AX side, off the main thread.
nonisolated enum FitWorker {
    /// Returns true when it moved or resized the window.
    @concurrent
    static func fit(_ ref: AXRef, in area: [FitArea]) async -> Bool {
        fitNow(ref.element, in: area)
    }

    @concurrent
    static func scan(pid: pid_t, in area: [FitArea]) async {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let windows: [AXUIElement] = AXReader.value(app, kAXWindowsAttribute) else { return }
        for window in windows { _ = fitNow(window, in: area) }
    }

    static func fitNow(_ window: AXUIElement, in areas: [FitArea]) -> Bool {
        AXUIElementSetMessagingTimeout(window, 1.0)
        let subrole: String? = AXReader.value(window, kAXSubroleAttribute)
        guard subrole == kAXStandardWindowSubrole else { return false }
        if let full: Bool = AXReader.value(window, "AXFullScreen"), full { return false }
        if let minimized: Bool = AXReader.value(window, kAXMinimizedAttribute), minimized { return false }
        guard let positionValue: AXValue = AXReader.value(window, kAXPositionAttribute),
              let sizeValue: AXValue = AXReader.value(window, kAXSizeAttribute) else { return false }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        let frame = CGRect(origin: origin, size: size)
        // The screen holding the window's middle; one showing a full-screen app has no area.
        guard let area = areas.first(where: { $0.screen.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
              let target = WorkArea.fit(frame, top: area.top, bottom: area.bottom,
                                        minX: area.screen.minX, maxX: area.screen.maxX) else { return false }
        if target.origin != frame.origin {
            var point = target.origin
            if let value = AXValueCreate(.cgPoint, &point) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
        }
        if target.size != frame.size {
            var newSize = target.size
            if let value = AXValueCreate(.cgSize, &newSize) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
            }
        }
        return true
    }
}
