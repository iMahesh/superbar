import AppKit
import ApplicationServices
import Observation

/// Accessibility, Screen Recording, and Automation of System Events, polled so
/// a grant shows up without a restart.
@Observable
final class Permissions {
    static let shared = Permissions()

    enum Automation { case on, off, notAsked }

    private(set) var accessibility = AXIsProcessTrusted()
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    private(set) var automation: Automation = .notAsked

    /// Set while Settings is open: poll fast and include Automation.
    @ObservationIgnored var settingsVisible = false { didSet { schedule() } }
    @ObservationIgnored var onAccessibilityGranted: () -> Void = {}
    @ObservationIgnored private var timer: Timer?

    func start() {
        refresh()
        schedule()
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        if ax && !accessibility { onAccessibilityGranted() }
        if ax != accessibility { accessibility = ax; schedule() }
        let screen = CGPreflightScreenCaptureAccess()
        if screen != screenRecording { screenRecording = screen }
        if settingsVisible { refreshAutomation(ask: false) }
    }

    /// Poll every 1.5 s while Accessibility is off or Settings is open, else every 20 s.
    private func schedule() {
        timer?.invalidate()
        let fast = !accessibility || settingsVisible
        let t = Timer(timeInterval: fast ? 1.5 : 20, repeats: true) { _ in
            MainActor.assumeIsolated { Permissions.shared.refresh() }
        }
        t.tolerance = fast ? 0.2 : 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshAutomation(ask: Bool) {
        Task {
            let state = await Self.automationState(ask: ask)
            if state != automation { automation = state }
        }
    }

    @concurrent
    nonisolated private static func automationState(ask: Bool) async -> Automation {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        guard let desc = target.aeDesc else { return .notAsked }
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .on
        case -1743: return .off          // errAEEventNotPermitted
        case -1744: return .notAsked     // errAEEventWouldRequireUserConsent
        default: return .notAsked        // -600: System Events is not running yet
        }
    }

    // MARK: Grant

    func grantAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        open("Privacy_Accessibility")
    }

    func grantScreenRecording() {
        if !CGRequestScreenCaptureAccess() { open("Privacy_ScreenCapture") }
    }

    func grantAutomation() {
        // System Events must be running to ask; launching it is harmless.
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in
                let state = await Permissions.automationState(ask: true)
                Permissions.shared.automation = state
                if state == .off { Permissions.shared.open("Privacy_Automation") }
            }
        }
    }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
