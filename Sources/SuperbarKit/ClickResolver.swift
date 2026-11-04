/// What a left click on a taskbar button does, decided from the app's state at mouse-down.
public enum ClickAction: Equatable, Sendable {
    /// Not running: launch it.
    case launch
    /// Running in the background: bring its last-used window to the front.
    case focus
    /// Hidden with ⌘H: unhide it.
    case unhide
    /// No visible window, at least one minimized: restore the most recent one.
    case restoreMinimized
    /// Active with one visible window: minimize it.
    case minimize
    /// Active with two or more windows: show the window picker.
    case pick
    /// Running with no windows at all: activate it and ask for a new window.
    case reopen
}

public struct ClickState: Equatable, Sendable {
    public var isRunning: Bool
    public var isActive: Bool
    public var isHidden: Bool
    public var visibleWindows: Int
    public var minimizedWindows: Int

    public init(isRunning: Bool, isActive: Bool = false, isHidden: Bool = false,
                visibleWindows: Int = 0, minimizedWindows: Int = 0) {
        self.isRunning = isRunning
        self.isActive = isActive
        self.isHidden = isHidden
        self.visibleWindows = visibleWindows
        self.minimizedWindows = minimizedWindows
    }
}

public enum ClickResolver {
    public static func resolve(_ s: ClickState) -> ClickAction {
        guard s.isRunning else { return .launch }
        if s.isHidden { return .unhide }
        let total = s.visibleWindows + s.minimizedWindows
        if s.isActive {
            if total >= 2 { return .pick }
            if s.visibleWindows == 1 { return .minimize }
            if s.minimizedWindows == 1 { return .restoreMinimized }
            return .reopen
        }
        if s.visibleWindows > 0 { return .focus }
        if s.minimizedWindows > 0 { return .restoreMinimized }
        return .reopen
    }
}

/// Window order for the picker and the preview popover: visible windows first
/// (front to back, as AX lists them), minimized ones after.
public enum WindowOrder {
    public static func pickerOrder<T>(_ windows: [T], isMinimized: (T) -> Bool) -> [T] {
        windows.filter { !isMinimized($0) } + windows.filter(isMinimized)
    }
}
