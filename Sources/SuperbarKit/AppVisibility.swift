/// The outcome of one Accessibility read.
public enum AXQuery<Value> {
    case value(Value)
    /// The app answered: there is nothing (kAXErrorNoValue, or an empty list).
    case none
    /// No answer (timeout, app busy, Accessibility off): the state is unknown.
    case failed
}

/// Turns the AX reads for one app into its live windows, or nil when that is unknown.
///
/// kAXWindowsAttribute lists only the windows on the current Space, so a window in
/// native full screen drops out of it once you switch away. The app's focused and
/// main windows are still reported, so an empty list falls back to them.
public enum WindowListResolver {
    public static func resolve<W>(
        windows: AXQuery<[W]>,
        focused: () -> AXQuery<W>,
        main: () -> AXQuery<W>,
        isLive: (W) -> Bool,
        same: (W, W) -> Bool
    ) -> [W]? {
        let list: [W]
        switch windows {
        case .failed: return nil
        case .none: list = []
        case .value(let all): list = all
        }
        var result: [W] = []
        for w in list where isLive(w) && !result.contains(where: { same($0, w) }) {
            result.append(w)
        }
        if !result.isEmpty { return result }

        var unknown = false
        for answer in [focused(), main()] {   // main is read even when focused failed
            switch answer {
            case .value(let w) where isLive(w): return [w]
            case .value, .none: continue
            case .failed: unknown = true
            }
        }
        return unknown ? nil : []
    }
}

/// What Superbar knows about an app's windows.
public enum WindowState: Equatable, Sendable {
    /// No successful read yet (Accessibility off, or every read failed).
    case unknown
    case known(count: Int)
}

/// Which apps get a button. The same answer on every display, whatever app is
/// active and whether the bar is auto-hidden over a full-screen app.
public enum AppVisibility {
    public static func isShown(isPinned: Bool, isRunning: Bool, windows: WindowState) -> Bool {
        if isPinned { return true }
        guard isRunning else { return false }
        switch windows {
        // Without a window list, hiding every unpinned app would empty the bar: keep them.
        case .unknown: return true
        case .known(let count): return count > 0
        }
    }
}
