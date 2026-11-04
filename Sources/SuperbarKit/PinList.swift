/// The taskbar's pinned apps: an ordered list of bundle IDs with Finder always first.
public struct PinList: Equatable, Sendable {
    public static let finderID = "com.apple.finder"

    public private(set) var ids: [String]

    public init(_ ids: [String] = []) {
        var seen: Set<String> = [Self.finderID]
        var result = [Self.finderID]
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        self.ids = result
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Pins `id` at `index` (clamped after Finder), or at the end. Moves it if already pinned.
    public mutating func pin(_ id: String, at index: Int? = nil) {
        guard id != Self.finderID else { return }
        ids.removeAll { $0 == id }
        let target = min(max(index ?? ids.count, 1), ids.count)
        ids.insert(id, at: target)
    }

    /// Returns false for Finder, which stays pinned.
    @discardableResult
    public mutating func unpin(_ id: String) -> Bool {
        guard id != Self.finderID else { return false }
        ids.removeAll { $0 == id }
        return true
    }

    /// Moves a pinned app to `index`. Finder keeps slot 0.
    public mutating func move(_ id: String, to index: Int) {
        guard id != Self.finderID, contains(id) else { return }
        pin(id, at: index)
    }
}

/// Merges pinned and running apps into the bar's order: Finder, the other pins
/// in saved order, then running apps that are not pinned, in launch order.
public enum AppOrdering {
    /// A running process as the bar sees it.
    public struct Running: Equatable, Sendable {
        public var id: String
        /// activationPolicy == .regular (has a Dock icon and windows).
        public var isRegular: Bool
        public var launchOrder: Double
        public init(id: String, isRegular: Bool, launchOrder: Double) {
            self.id = id; self.isRegular = isRegular; self.launchOrder = launchOrder
        }
    }

    /// Bar order from raw processes: only regular apps, Finder first.
    public static func order(pinned: PinList, running: [Running]) -> [String] {
        let ids = running.filter(\.isRegular).sorted { $0.launchOrder < $1.launchOrder }.map(\.id)
        return order(pinned: pinned, runningInLaunchOrder: ids)
    }

    public static func order(pinned: PinList, runningInLaunchOrder running: [String]) -> [String] {
        var result = pinned.ids
        var seen = Set(result)
        for id in running where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }
}

/// Last apps opened from Superbar, newest first.
public struct RecentList: Equatable, Sendable {
    public private(set) var ids: [String]
    public let limit: Int

    public init(_ ids: [String] = [], limit: Int = 10) {
        self.limit = limit
        var seen: Set<String> = []
        self.ids = Array(ids.filter { seen.insert($0).inserted }.prefix(limit))
    }

    public mutating func note(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        if ids.count > limit { ids.removeLast(ids.count - limit) }
    }
}
