import AppKit
import ApplicationServices

/// Focus, minimize, restore, and close, off the main thread: AX calls block
/// up to the messaging timeout on a hung app.
nonisolated enum WindowActions {
    @concurrent
    static func focus(_ window: AppWindow, pid: pid_t) async {
        if window.isMinimized {
            set(window.element, kAXMinimizedAttribute, false)
        }
        if !Private.bringToFront(pid: pid, windowID: window.windowID) {
            await activateWithPublicAPI(pid)
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        set(window.element, kAXMainAttribute, true)
    }

    /// The app, with no particular window.
    @concurrent
    static func activate(pid: pid_t) async {
        if !Private.bringToFront(pid: pid, windowID: nil) {
            await activateWithPublicAPI(pid)
        }
    }

    @concurrent
    static func minimize(_ window: AppWindow) async {
        set(window.element, kAXMinimizedAttribute, true)
    }

    /// Presses the window's close button, so an unsaved document still asks.
    @concurrent
    static func close(_ window: AppWindow) async {
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window.element, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID() else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    /// Posts a key press to one app, or to the whole system when `pid` is nil.
    static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags, to pid: pid_t?) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
        }
    }

    private static func set(_ element: AXUIElement, _ attribute: String, _ flag: Bool) {
        AXUIElementSetAttributeValue(element, attribute as CFString, NSNumber(value: flag))
    }

    private static func activateWithPublicAPI(_ pid: pid_t) async {
        await MainActor.run { _ = NSRunningApplication(processIdentifier: pid)?.activate() }
    }
}
