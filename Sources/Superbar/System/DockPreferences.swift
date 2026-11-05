import AppKit
import Observation
import SuperbarKit

/// The Dock's real preferences in com.apple.dock, through CFPreferences.
nonisolated final class SystemDockPreferences: DockPreferences {
    private let domain = "com.apple.dock" as CFString

    func value(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain)
    }

    func write(_ values: [String: Any?]) {
        for (key, value) in values {
            CFPreferencesSetAppValue(key as CFString, value.map { $0 as AnyObject as CFPropertyList }, domain)
        }
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
        alert.informativeText = "Superbar turns on Dock hiding with a long delay, so the Dock stops appearing at the bottom edge. It also moves the Dock to the bottom with small icons, so minimized windows shrink toward Superbar and the Dock stays under the bar in Mission Control. Your current Dock settings are saved, and Restore Dock puts them back."
        alert.addButton(withTitle: "Hide Dock")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        control.hideDock()
        isHidden = true
    }

    /// Hidden by an earlier version, which left the Dock's side and size alone: move it
    /// under the bar now. Once; Restore Dock still puts back every original value.
    func upgradeIfNeeded() {
        guard isHidden, control.needsUpgrade else { return }
        control.hideDock()
    }

    func restore() {
        control.restoreDock()
        isHidden = control.hasSavedState
    }
}
