import AppKit
import ApplicationServices
import Observation
import SuperbarKit

/// One window of a running app.
/// `@unchecked Sendable`: AXUIElement is an immutable CF reference that the AX API
/// lets any thread use, and the struct has only `let` and value fields.
nonisolated struct AppWindow: Identifiable, @unchecked Sendable {
    let windowID: CGWindowID
    let element: AXUIElement
    var title: String
    var isMinimized: Bool

    var id: String { windowID != 0 ? "w\(windowID)" : "e\(CFHash(element))" }
}

/// Reads windows through AX, off the main thread. AX is the only list that
/// includes minimized windows; CG only adds IDs and names.
nonisolated enum AXReader {
    /// nil when the read failed: the caller keeps what it knew.
    @concurrent
    static func windows(pid: pid_t) async -> [AppWindow]? { read(pid: pid) }

    /// The app's live windows: ordinary, minimized, and native full screen (through
    /// the focused/main fallback in WindowListResolver). nil when unknown.
    static func read(pid: pid_t) -> [AppWindow]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let elements = WindowListResolver.resolve(
            windows: query(app, kAXWindowsAttribute) as AXQuery<[AXUIElement]>,
            focused: { query(app, kAXFocusedWindowAttribute) },
            main: { query(app, kAXMainWindowAttribute) },
            isLive: isLive,
            same: { a, b in
                let ia = Private.windowID(of: a) ?? 0, ib = Private.windowID(of: b) ?? 0
                return ia != 0 && ib != 0 ? ia == ib : CFEqual(a, b)
            })
        guard let elements else { return nil }
        var cgNames: [CGWindowID: String]?
        return elements.map { element in
            let id = Private.windowID(of: element) ?? 0
            var title: String = value(element, kAXTitleAttribute) ?? ""
            if title.isEmpty, id != 0 {
                if cgNames == nil { cgNames = windowNames(pid: pid) }
                title = cgNames?[id] ?? ""
            }
            let minimized: Bool = value(element, kAXMinimizedAttribute) ?? false
            return AppWindow(windowID: id, element: element, title: title, isMinimized: minimized)
        }
    }

    /// A window a person works in. Standard windows and dialogs (macOS reports an
    /// inactive or minimized window as a dialog); not panels, the Finder desktop, or
    /// tiny placeholder windows. Untitled windows count.
    private static func isLive(_ element: AXUIElement) -> Bool {
        let subrole: String? = value(element, kAXSubroleAttribute)
        guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return false }
        if let raw: AXValue = value(element, kAXSizeAttribute) {
            var size = CGSize.zero
            if AXValueGetValue(raw, .cgSize, &size), size.width < 20 || size.height < 20 { return false }  // grid: ok placeholder size, not layout
        }
        return true
    }

    /// No value and an unsupported attribute are answers; anything else is a failed read.
    static func query<T>(_ element: AXUIElement, _ attribute: String) -> AXQuery<T> {
        var raw: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) {
        case .success: return (raw as? T).map { .value($0) } ?? .none
        case .noValue, .attributeUnsupported: return .none
        default: return .failed
        }
    }

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    /// kCGWindowName per window ID. Empty without Screen Recording.
    private static func windowNames(pid: pid_t) -> [CGWindowID: String] {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var names: [CGWindowID: String] = [:]
        for w in info where (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
            if let id = w[kCGWindowNumber as String] as? CGWindowID, let name = w[kCGWindowName as String] as? String, !name.isEmpty {
                names[id] = name
            }
        }
        return names
    }
}

/// One AXObserver per pid, on its own thread with its own run loop, so an app
/// that hangs never blocks the main thread.
/// `@unchecked Sendable`: `observers` and `runLoop` are touched only on that thread
/// (through `perform`), after `init` has set `runLoop` and returned.
nonisolated final class AXObserverHost: @unchecked Sendable {
    static let shared = AXObserverHost()

    private var observers: [pid_t: AXObserver] = [:]
    private var runLoop: CFRunLoop!
    private static let notifications = [
        kAXWindowCreatedNotification, kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
        kAXTitleChangedNotification, kAXFocusedWindowChangedNotification,
        kAXWindowResizedNotification,
    ]

    private init() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Superbar AX observers"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }

    private func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    func watch(_ pid: pid_t) {
        perform { [self] in
            guard observers[pid] == nil else { return }
            var observer: AXObserver?
            guard AXObserverCreate(pid, Self.callback, &observer) == .success, let observer else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 1.0)
            for name in Self.notifications {
                AXObserverAddNotification(observer, app, name as CFString, nil)
            }
            CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }
    }

    /// "Destroyed" is sent only to observers of the window itself, not of its app,
    /// so each window is registered as it is read. Registering twice is harmless.
    func watchWindows(_ windows: [AppWindow], pid: pid_t) {
        perform { [self] in
            guard let observer = observers[pid] else { return }
            for window in windows {
                AXObserverAddNotification(observer, window.element, kAXUIElementDestroyedNotification as CFString, nil)
            }
        }
    }

    func unwatch(_ pid: pid_t) {
        perform { [self] in
            guard let observer = observers.removeValue(forKey: pid) else { return }
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    func unwatchAll() {
        perform { [self] in
            for observer in observers.values {
                CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observers.removeAll()
        }
    }

    private static let callback: AXObserverCallback = { _, element, notification, _ in
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let minimized = (notification as String) == kAXWindowMiniaturizedNotification
        let windowID = minimized ? Private.windowID(of: element) : nil
        let name = notification as String
        // A new or resized window may reach under the bar (WindowFitter). Moves alone never
        // trigger it, so a window being dragged is not fought.
        if name == kAXWindowCreatedNotification || name == kAXWindowResizedNotification {
            let ref = AXRef(element: element)
            Task { @MainActor in WindowFitter.shared.windowChanged(ref) }
        }
        // Resizes are frequent and do not change the window list.
        guard name != kAXWindowResizedNotification else { return }
        Task { @MainActor in WindowIndex.shared.changed(pid: pid, minimizedWindow: windowID) }
    }
}

/// Every running app's windows, kept current by AX notifications.
@Observable
final class WindowIndex {
    static let shared = WindowIndex()

    /// The last successful read per pid. A failed read leaves it as it was.
    private(set) var windows: [pid_t: [AppWindow]] = [:]
    @ObservationIgnored private var watched: Set<pid_t> = []
    @ObservationIgnored private var pending: Set<pid_t> = []
    @ObservationIgnored private var minimizedAt: [CGWindowID: Date] = [:]

    /// Starts watching new pids and drops quit ones.
    func sync(pids: Set<pid_t>) {
        // Termination is the one thing that clears a pid's windows, with or without Accessibility.
        for pid in watched.subtracting(pids) { AXObserverHost.shared.unwatch(pid) }
        for pid in Set(windows.keys).subtracting(pids) { windows[pid] = nil }
        guard AXIsProcessTrusted() else { watched.formIntersection(pids); return }
        for pid in pids.subtracting(watched) {
            AXObserverHost.shared.watch(pid)
            refresh(pid)
        }
        watched = pids
    }

    /// After Accessibility is granted: observers made before the grant never fire.
    func resync(pids: Set<pid_t>) {
        AXObserverHost.shared.unwatchAll()
        watched = []
        sync(pids: pids)
    }

    /// Coalesces bursts of notifications into one read per pid.
    func refresh(_ pid: pid_t) {
        guard !pending.contains(pid) else { return }
        pending.insert(pid)
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            pending.remove(pid)
            // A failed read is unknown, not "no windows": keep the last good list
            // until a read succeeds or the app quits (sync drops it).
            guard let list = await AXReader.windows(pid: pid), watched.contains(pid) else { return }
            windows[pid] = list
            AXObserverHost.shared.watchWindows(list, pid: pid)
        }
    }

    /// `.unknown` until a read of this pid has succeeded.
    func state(_ pid: pid_t) -> WindowState {
        windows[pid].map { .known(count: $0.count) } ?? .unknown
    }

    func refreshAll() {
        for pid in watched { refresh(pid) }
    }

    func changed(pid: pid_t, minimizedWindow: CGWindowID?) {
        if let minimizedWindow { minimizedAt[minimizedWindow] = .now }
        refresh(pid)
    }

    func noteMinimized(_ windowID: CGWindowID) {
        minimizedAt[windowID] = .now
    }

    /// The window minimized last, for "restore its most recent minimized window".
    func mostRecentMinimized(in list: [AppWindow]) -> AppWindow? {
        let minimized = list.filter(\.isMinimized)
        return minimized.max { (minimizedAt[$0.windowID] ?? .distantPast) < (minimizedAt[$1.windowID] ?? .distantPast) }
    }

    /// For snapshots and the self-test.
    func setForTesting(_ list: [AppWindow], pid: pid_t) {
        windows[pid] = list
    }
}
