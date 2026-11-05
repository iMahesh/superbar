import AppKit
import ApplicationServices
import Synchronization
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
        guard var elements else { return nil }
        // Windows on other Spaces (each full-screen window is its own Space) are missing
        // from kAXWindowsAttribute; the window server still knows them.
        let known = Set(elements.compactMap { Private.windowID(of: $0) })
        elements += OtherSpaces.windows(pid: pid, known: known, isLive: isLive)
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

/// Finds an app's windows on other Spaces. The window server lists every window; when
/// it shows a big, normal-layer window that AX didn't report, element ids are tried
/// (Private.remoteElement) until those windows turn up. Candidates that never turn up
/// (an app's hidden helper windows) are remembered and not searched for again.
nonisolated enum OtherSpaces {
    /// Per pid, window ids searched for and not found.
    private static let notWindows = Mutex<[pid_t: Set<CGWindowID>]>([:])
    /// Element ids are small and grow as an app makes UI; AltTab tries the first 1000.
    static let maxElementID: UInt64 = 5000
    /// Never spend longer than this on one app.
    static let budget: TimeInterval = 0.5

    static func windows(pid: pid_t, known: Set<CGWindowID>, isLive: (AXUIElement) -> Bool) -> [AXUIElement] {
        guard Private.canReachOtherSpaces else { return [] }
        let skip = notWindows.withLock { $0[pid] ?? [] }
        var missing = candidates(pid: pid).subtracting(known).subtracting(skip)
        guard !missing.isEmpty else { return [] }
        let searched = missing
        var found: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(budget)
        var finished = true
        for elementID in 0..<maxElementID where !missing.isEmpty {
            if elementID % 100 == 0, Date() > deadline { finished = false; break }
            guard let element = Private.remoteElement(pid: pid, elementID: elementID) else { continue }
            AXUIElementSetMessagingTimeout(element, 0.1)
                // Every element inside a window reports that window's id: take only the window.
            guard let id = Private.windowID(of: element), missing.contains(id),
                  let role: String = AXReader.value(element, kAXRoleAttribute), role == kAXWindowRole else { continue }
            missing.remove(id)
            if isLive(element) { found.append(element) }
        }
        // Out of time: try again next read rather than write the rest off.
        guard finished else { return found }
        let foundIDs = Set(found.compactMap { Private.windowID(of: $0) })
        notWindows.withLock { $0[pid, default: []].formUnion(searched.subtracting(foundIDs)) }
        return found
    }

    /// Normal-layer windows of the app that aren't on screen, are big enough to be a
    /// document window, and belong to a Space (not hidden helper windows). Minimized windows are among them, but AX reports those already.
    private static func candidates(pid: pid_t) -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var ids = Set<CGWindowID>()
        for w in info where (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowIsOnscreen as String] as? Bool) != true,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width >= 100, bounds.height >= 100,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  Private.isOnSomeSpace(id) else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// The app quit: its window ids won't come back.
    static func forget(_ pid: pid_t) { _ = notWindows.withLock { $0.removeValue(forKey: pid) } }
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
        for pid in Set(windows.keys).subtracting(pids) {
            windows[pid] = nil
            OtherSpaces.forget(pid)
        }
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
