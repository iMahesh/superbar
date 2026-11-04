import Foundation

/// Where Superbar keeps its data: UserDefaults. Snapshots and the self-test set
/// APP_STORE and get a separate, emptied suite, so they never touch real pins.
enum Store {
    static let testSuite = "com.maheshporeddy.superbar.test"

    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }

    static let defaults: UserDefaults = {
        guard isOverridden, let suite = UserDefaults(suiteName: testSuite) else { return .standard }
        suite.removePersistentDomain(forName: testSuite)
        return suite
    }()

    enum Key {
        static let pinnedApps = "pinnedApps"
        static let startPins = "startPinnedApps"
        static let recentApps = "recentApps"
        static let barSize = "barSize"
        static let startHotkey = "startHotkey"
    }
}
