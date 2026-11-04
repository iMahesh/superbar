import Foundation

/// Reads and writes the Dock's autohide preferences. The app uses CFPreferences on
/// com.apple.dock and restarts the Dock; tests use a fake.
public protocol DockPreferences: AnyObject {
    var autohide: Bool? { get }
    var autohideDelay: Double? { get }
    /// nil removes the key, so the Dock goes back to its own default.
    func write(autohide: Bool?, autohideDelay: Double?)
    func restartDock()
}

/// Hides the Dock (autohide with a 1000 s delay) and restores the exact values
/// it had before. The old values are saved before anything is written.
public final class DockControl {
    private let prefs: DockPreferences
    private let store: UserDefaults
    private static let savedKey = "dockControl.saved"

    public init(prefs: DockPreferences, store: UserDefaults = .standard) {
        self.prefs = prefs
        self.store = store
    }

    /// True while Superbar has the Dock hidden and holds the old values.
    public var hasSavedState: Bool { store.dictionary(forKey: Self.savedKey) != nil }

    public var savedAutohide: Bool? { store.dictionary(forKey: Self.savedKey)?["autohide"] as? Bool }
    public var savedDelay: Double? { store.dictionary(forKey: Self.savedKey)?["delay"] as? Double }

    public func hideDock() {
        if !hasSavedState {
            var saved: [String: Any] = ["saved": true]
            if let a = prefs.autohide { saved["autohide"] = a }
            if let d = prefs.autohideDelay { saved["delay"] = d }
            store.set(saved, forKey: Self.savedKey)
        }
        prefs.write(autohide: true, autohideDelay: 1000)
        prefs.restartDock()
    }

    public func restoreDock() {
        guard hasSavedState else { return }
        prefs.write(autohide: savedAutohide, autohideDelay: savedDelay)
        store.removeObject(forKey: Self.savedKey)
        prefs.restartDock()
    }
}
