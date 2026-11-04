import CoreGraphics

/// Over a full-screen app the bar hides, and slides up when the pointer rests on
/// the bottom edge of the main screen, like the Dock. Feed it the pointer every
/// tick; it says when to show or hide.
public struct EdgeReveal: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case none, show, hide }

    /// The pointer must rest this long on the edge, so a quick pass over a video's
    /// controls does not pop the bar up.
    public var showDelay: Double = 0.2
    /// After the pointer leaves the bar, wait this long before hiding.
    public var hideDelay: Double = 0.6
    /// The edge zone, in points from the bottom of the screen.
    public var edge: Double = 2
    /// Extra room above the bar the pointer may wander before the hide timer starts.
    public var slack: Double = 12

    public private(set) var isRevealed = false
    private var edgeSince: Double?
    private var outsideSince: Double?

    public init() {}

    /// - Parameters:
    ///   - pointerHeight: the pointer's distance from the bottom of the main screen,
    ///     or nil when it is on another screen.
    ///   - barHeight: the bar's height.
    ///   - heldOpen: the Start menu, a preview, the calendar, or a menu is open.
    ///   - now: seconds, any monotonic clock.
    public mutating func update(pointerHeight: Double?, barHeight: Double, heldOpen: Bool, now: Double) -> Action {
        if !isRevealed {
            outsideSince = nil
            if heldOpen {
                isRevealed = true
                edgeSince = nil
                return .show
            }
            guard let y = pointerHeight, y <= edge else { edgeSince = nil; return .none }
            if edgeSince == nil { edgeSince = now }
            guard now - (edgeSince ?? now) >= showDelay else { return .none }
            isRevealed = true
            edgeSince = nil
            return .show
        }
        if heldOpen || (pointerHeight.map { $0 <= barHeight + slack } ?? false) {
            outsideSince = nil
            return .none
        }
        if outsideSince == nil { outsideSince = now }
        guard now - (outsideSince ?? now) >= hideDelay else { return .none }
        isRevealed = false
        outsideSince = nil
        return .hide
    }

    /// Back to hidden, as when full screen starts.
    public mutating func reset() {
        self = EdgeReveal(showDelay: showDelay, hideDelay: hideDelay, edge: edge, slack: slack)
    }

    init(showDelay: Double, hideDelay: Double, edge: Double, slack: Double) {
        self.showDelay = showDelay
        self.hideDelay = hideDelay
        self.edge = edge
        self.slack = slack
    }
}

/// The fallback full-screen check when Accessibility is off: a normal-layer window
/// that covers the whole main screen. A zoomed window never does, because it stops
/// under the menu bar. CG coordinates: origin at the top left of the main screen.
public enum ScreenCover {
    public struct Window: Equatable, Sendable {
        public var bounds: CGRect
        public var layer: Int
        public var ownerPID: Int32
        public init(bounds: CGRect, layer: Int, ownerPID: Int32) {
            self.bounds = bounds; self.layer = layer; self.ownerPID = ownerPID
        }
    }

    public static func isFullScreen(_ windows: [Window], frontPID: Int32, screen: CGRect) -> Bool {
        windows.contains { w in
            w.layer == 0 && w.ownerPID == frontPID
                && abs(w.bounds.minX - screen.minX) < 1 && abs(w.bounds.minY - screen.minY) < 1
                && abs(w.bounds.width - screen.width) < 1 && abs(w.bounds.height - screen.height) < 1
        }
    }
}
