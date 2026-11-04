import AppKit
import Observation
import SuperbarKit

/// The Dock's real preferences in com.apple.dock, through CFPreferences.
nonisolated final class SystemDockPreferences: DockPreferences {
    private let domain = "com.apple.dock" as CFString

    var autohide: Bool? {
        CFPreferencesCopyAppValue("autohide" as CFString, domain) as? Bool
    }

    var autohideDelay: Double? {
        CFPreferencesCopyAppValue("autohide-delay" as CFString, domain) as? Double
    }

    func write(autohide: Bool?, autohideDelay: Double?) {
        CFPreferencesSetAppValue("autohide" as CFString, autohide.map { NSNumber(value: $0) }, domain)
        CFPreferencesSetAppValue("autohide-delay" as CFString, autohideDelay.map { NSNumber(value: Float($0)) }, domain)
        CFPreferencesAppSynchronize(domain)
    }

    func restartDock() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["Dock"]
        try? kill.run()
    }
}

/// "Hide the macOS Dock" for Settings and the bar's menu. Never changes the
/// Dock without asking: `requestHide()` shows an alert first.
@Observable
final class DockController {
    @ObservationIgnored private let control: DockControl
    private(set) var isHidden: Bool

    init(prefs: DockPreferences = SystemDockPreferences(), store: UserDefaults = Store.defaults) {
        control = DockControl(prefs: prefs, store: store)
        isHidden = control.hasSavedState
    }

    func requestHide() {
        guard !isHidden else { return }
        let alert = NSAlert()
        alert.messageText = "Hide the macOS Dock?"
        alert.informativeText = "Superbar turns on Dock hiding with a long delay, so the Dock stops appearing at the bottom edge. Your current Dock settings are saved, and Restore Dock puts them back."
        alert.addButton(withTitle: "Hide Dock")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        control.hideDock()
        isHidden = true
    }

    func restore() {
        control.restoreDock()
        isHidden = control.hasSavedState
    }
}
