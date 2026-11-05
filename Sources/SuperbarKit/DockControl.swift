import Foundation

/// Reads and writes keys in com.apple.dock. The app uses CFPreferences and restarts
/// the Dock; tests use a fake.
public protocol DockPreferences: AnyObject {
    /// The key's value (a property-list value), or nil when it isn't set.
    func value(_ key: String) -> Any?
    /// Writes each key; nil removes it, so the Dock goes back to its own default.
    func write(_ values: [String: Any?])
    func restartDock()
}

/// Hides the Dock and restores the exact values it had before. The old values are saved
/// before anything is written.
///
/// Hidden means: autohide with a 1000 s delay, so it never pops up; at the bottom, so
/// minimized windows shrink toward the bottom of the screen (where Superbar is) instead
/// of a side; and with small icons and no magnification, so in Mission Control, which
/// always shows the Dock, it fits under the bar.
public final class DockControl {
    private let prefs: DockPreferences
    private let store: UserDefaults
    private static let savedKey = "dockControl.saved"

    public static var hiddenValues: [String: Any] { [
        "autohide": true,
        "autohide-delay": 1000.0,
        "orientation": "bottom",
        "tilesize": 16.0,
        "magnification": false,
    ] }

    public init(prefs: DockPreferences, store: UserDefaults = .standard) {
        self.prefs = prefs
        self.store = store
    }

    /// True while Superbar has the Dock hidden and holds the old values.
    public var hasSavedState: Bool { store.dictionary(forKey: Self.savedKey) != nil }

    /// The value a key had before Superbar hid the Dock; nil when it wasn't set.
    public func savedValue(_ key: String) -> Any? { saved().values[key] }

    /// Hidden by an older Superbar that changed fewer keys: hiding again adds the rest.
    public var needsUpgrade: Bool {
        guard hasSavedState else { return false }
        let s = saved()
        return Self.hiddenValues.keys.contains { s.values[$0] == nil && !s.absent.contains($0) }
    }

    public func hideDock() {
        var s = saved()
        // Record only keys not saved yet, so hiding twice keeps the user's originals.
        for key in Self.hiddenValues.keys where s.values[key] == nil && !s.absent.contains(key) {
            if let v = prefs.value(key) { s.values[key] = v } else { s.absent.append(key) }
        }
        store.set(["values": s.values, "absent": s.absent.sorted()], forKey: Self.savedKey)
        prefs.write(Self.hiddenValues.mapValues { Optional($0) })
        prefs.restartDock()
    }

    public func restoreDock() {
        guard hasSavedState else { return }
        let s = saved()
        var values: [String: Any?] = [:]
        for key in s.values.keys { values[key] = s.values[key] }
        for key in s.absent { values[key] = .some(nil) }
        prefs.write(values)
        store.removeObject(forKey: Self.savedKey)
        prefs.restartDock()
    }

    /// The saved values, reading the first format too: {saved, autohide, delay}.
    private func saved() -> (values: [String: Any], absent: [String]) {
        guard let dict = store.dictionary(forKey: Self.savedKey) else { return ([:], []) }
        if let values = dict["values"] as? [String: Any] {
            return (values, dict["absent"] as? [String] ?? [])
        }
        var values: [String: Any] = [:]
        var absent: [String] = []
        if let a = dict["autohide"] { values["autohide"] = a } else { absent.append("autohide") }
        if let d = dict["delay"] { values["autohide-delay"] = d } else { absent.append("autohide-delay") }
        return (values, absent)
    }
}
