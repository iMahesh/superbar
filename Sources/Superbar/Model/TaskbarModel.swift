import AppKit
import Observation
import SwiftUI
import SuperbarKit

/// One button on the bar.
struct TaskbarApp: Identifiable {
    /// Bundle ID, or "pid:<n>" for an app without one.
    let id: String
    var bundleID: String?
    var pid: pid_t?
    var name: String
    var icon: NSImage
    var url: URL?
    var isPinned: Bool
    var isActive: Bool
    var isHidden: Bool
    /// Visible windows first, minimized after (WindowOrder.pickerOrder).
    var windows: [AppWindow]
    /// False until Accessibility has read this app's windows once.
    var windowsKnown = true
    var glowColor: Color

    var isRunning: Bool { pid != nil }
    /// Gets the raised button frame: it has a window, or it runs and its windows are unknown.
    /// A running app with no window (Finder with only the desktop) looks like a plain pin.
    var showsFrame: Bool { isRunning && (!windowsKnown || !windows.isEmpty) }
    var visibleWindows: [AppWindow] { windows.filter { !$0.isMinimized } }
}

struct DragState: Equatable {
    var id: String
    var offset: CGFloat
}

/// Merges pinned and running apps into one ordered list and handles every
/// click, menu, and drag on the bar. Pinned apps always have a button; unpinned
/// ones only while they have a live window (AppVisibility).
@Observable
final class TaskbarModel {
    private(set) var pins: PinList
    private(set) var running: [NSRunningApplication] = []
    private(set) var frontPID: pid_t?
    var hoveredID: String?
    var drag: DragState?
    var showDesktopOn = false
    private(set) var recent: RecentList

    /// Snapshots set fixed apps instead of reading the real ones.
    var staticApps: [TaskbarApp]?

    // Wired by AppDelegate.
    @ObservationIgnored var onToggleStart: () -> Void = {}
    @ObservationIgnored var onToggleCalendar: () -> Void = {}
    @ObservationIgnored var onTrayClick: (_ item: TrayItem, _ rect: NSRect) -> Void = { _, _ in }
    @ObservationIgnored var onOpenSettings: () -> Void = {}
    @ObservationIgnored var onButtonHover: (_ id: String, _ inside: Bool, _ rect: NSRect) -> Void = { _, _, _ in }
    @ObservationIgnored var onPick: (_ id: String, _ rect: NSRect) -> Void = { _, _ in }
    @ObservationIgnored var onCloseTransient: () -> Void = {}
    @ObservationIgnored var dock: DockController?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let index = WindowIndex.shared
    @ObservationIgnored private var hiddenByShowDesktop: [NSRunningApplication] = []

    init(defaults: UserDefaults = Store.defaults) {
        self.defaults = defaults
        pins = PinList(defaults.stringArray(forKey: Store.Key.pinnedApps) ?? Self.defaultPins)
        recent = RecentList(defaults.stringArray(forKey: Store.Key.recentApps) ?? [])
    }

    static let defaultPins = ["com.apple.finder", "com.apple.Safari", "com.apple.mail"]

    // MARK: The list

    var apps: [TaskbarApp] {
        if let staticApps { return staticApps }
        var byID: [String: NSRunningApplication] = [:]
        for app in running where byID[key(app)] == nil { byID[key(app)] = app }
        let order = AppOrdering.order(pinned: pins, running: running.map {
            AppOrdering.Running(id: key($0), isRegular: true,
                                launchOrder: $0.launchDate?.timeIntervalSince1970 ?? Double($0.processIdentifier) / 1e6)
        })
        let cache = IconCache.shared
        return order.compactMap { id in
            let app = byID[id]
            let isPinned = pins.contains(id)
            let url = app?.bundleURL ?? (isPinned ? cache.url(forBundleID: id) : nil)
            guard app != nil || url != nil else { return nil }   // a pin whose app is gone
            let pid = app?.processIdentifier
            let state = pid.map(index.state) ?? .unknown
            guard AppVisibility.isShown(isPinned: isPinned, isRunning: app != nil, windows: state) else { return nil }
            let icon = cache.icon(for: id, url: url, running: app)
            let windows = pid.map { WindowOrder.pickerOrder(index.windows[$0] ?? []) { $0.isMinimized } } ?? []
            return TaskbarApp(id: id, bundleID: app?.bundleIdentifier ?? id, pid: pid,
                              name: app?.localizedName ?? Self.displayName(url),
                              icon: icon, url: url, isPinned: isPinned,
                              isActive: pid != nil && pid == frontPID, isHidden: app?.isHidden ?? false,
                              windows: windows, windowsKnown: state != .unknown,
                              glowColor: cache.glow(for: id, icon: icon))
        }
    }

    func app(_ id: String) -> TaskbarApp? { apps.first { $0.id == id } }

    private func key(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? "pid:\(app.processIdentifier)"
    }

    static func displayName(_ url: URL?) -> String {
        guard let url else { return "App" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: Running apps

    func startWatching() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadRunning() }
            }
        }
        reloadRunning()
    }

    func reloadRunning() {
        running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated
        }
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pids = Set(running.map(\.processIdentifier))
        index.sync(pids: pids)
        index.refreshAll()
        WindowThumbnails.shared.prune(keeping: Set(index.windows.values.flatMap { $0.map(\.windowID) }))
    }

    func accessibilityGranted() {
        index.resync(pids: Set(running.map(\.processIdentifier)))
    }

    // MARK: Click

    /// `frontAtMouseDown` is read at mouse-down, before anything can change focus.
    func click(_ id: String, frontAtMouseDown: pid_t?, shift: Bool, rect: NSRect) {
        onCloseTransient()
        guard let app = app(id) else { return }
        if shift { newWindow(id); return }
        guard let pid = app.pid else { launch(app); return }
        guard AXIsProcessTrusted() else { clickWithoutAccessibility(app, pid: pid, front: frontAtMouseDown); return }

        let visible = app.visibleWindows
        let state = ClickState(isRunning: true, isActive: pid == frontAtMouseDown, isHidden: app.isHidden,
                               visibleWindows: visible.count, minimizedWindows: app.windows.count - visible.count)
        switch ClickResolver.resolve(state) {
        case .launch:
            launch(app)
        case .focus:
            let window = visible[0]
            Task { await WindowActions.focus(window, pid: pid) }
        case .unhide:
            runningApp(pid)?.unhide()
            if let window = visible.first { Task { await WindowActions.focus(window, pid: pid) } }
            else { Task { await WindowActions.activate(pid: pid) } }
        case .restoreMinimized:
            guard let window = index.mostRecentMinimized(in: app.windows) else { return }
            Task { await WindowActions.focus(window, pid: pid) }
        case .minimize:
            minimize(visible[0])
        case .pick:
            onPick(id, rect)
        case .reopen:
            reopen(app, pid: pid)
        }
    }

    /// Without Accessibility there is no window list: switch apps, and hide the active one.
    private func clickWithoutAccessibility(_ app: TaskbarApp, pid: pid_t, front: pid_t?) {
        guard let running = runningApp(pid) else { return }
        if pid == front { running.hide() } else {
            running.unhide()
            Task { await WindowActions.activate(pid: pid) }
        }
    }

    /// Takes a last picture first: a minimized window cannot be captured.
    func minimize(_ window: AppWindow) {
        index.noteMinimized(window.windowID)
        Task {
            if Permissions.shared.screenRecording {
                let capture = Task { await WindowThumbnails.shared.capture([window.windowID]) }
                // Wait for the picture, but never more than 150 ms.
                let timeout = Task { try? await Task.sleep(for: .milliseconds(150)) }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await capture.value }
                    group.addTask { await timeout.value }
                    await group.next()
                    group.cancelAll()
                }
            }
            await WindowActions.minimize(window)
        }
    }

    func focus(_ window: AppWindow, of id: String) {
        guard let pid = app(id)?.pid else { return }
        Task { await WindowActions.focus(window, pid: pid) }
    }

    func close(_ window: AppWindow, of id: String) {
        let pid = app(id)?.pid
        Task {
            await WindowActions.close(window)
            if let pid { index.refresh(pid) }
        }
    }

    func launch(_ app: TaskbarApp) {
        guard let url = app.url else { return }
        open(url: url, bundleID: app.bundleID)
    }

    /// Opens an app from the bar or the Start menu and remembers it in Recent.
    func open(url: URL, bundleID: String?) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        if let bundleID { noteRecent(bundleID) }
    }

    func noteRecent(_ bundleID: String) {
        recent.note(bundleID)
        defaults.set(recent.ids, forKey: Store.Key.recentApps)
    }

    /// Running with no windows: activate it and ask for one, like a Dock click.
    private func reopen(_ app: TaskbarApp, pid: pid_t) {
        if app.id == PinList.finderID {
            Task { await WindowActions.activate(pid: pid) }
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
        } else if let url = app.url {
            // openApplication on a running app sends it the reopen event.
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        } else {
            Task { await WindowActions.activate(pid: pid) }
        }
    }

    /// Middle click or ⇧click: a new window, with ⌘N after the app is in front.
    func newWindow(_ id: String) {
        onCloseTransient()
        guard let app = app(id) else { return }
        guard let pid = app.pid, let url = app.url else { launch(app); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                WindowActions.postKey(45, flags: .maskCommand, to: pid)  // ⌘N
            }
        }
    }

    private func runningApp(_ pid: pid_t) -> NSRunningApplication? {
        running.first { $0.processIdentifier == pid }
    }

    // MARK: Pins

    func pin(_ id: String, at index: Int? = nil) {
        var p = pins
        p.pin(id, at: index)
        setPins(p)
    }

    func unpin(_ id: String) {
        var p = pins
        p.unpin(id)
        setPins(p)
    }

    private func setPins(_ p: PinList) {
        pins = p
        defaults.set(p.ids, forKey: Store.Key.pinnedApps)
    }

    /// Drop after a drag: move a pinned app, or pin a running one dropped among the pins.
    func endDrag(_ id: String, offset: CGFloat, stride: CGFloat) {
        defer { drag = nil }
        let list = apps
        guard let from = list.firstIndex(where: { $0.id == id }), stride > 0 else { return }
        let target = max(0, min(list.count - 1, Int((CGFloat(from) + offset / stride).rounded())))
        var shown = list.filter(\.isPinned).map(\.id)
        let pinnedCount = shown.count
        if list[from].isPinned {
            guard target != from, id != PinList.finderID else { return }
            shown.removeAll { $0 == id }
            shown.insert(id, at: min(max(target, 1), shown.count))
        } else if target < pinnedCount || (target == pinnedCount && target < from) {
            shown.insert(id, at: max(target, 1))
        } else {
            return
        }
        // Pins whose app is not installed keep their place at the end.
        setPins(PinList(shown + pins.ids.filter { !shown.contains($0) }))
    }

    // MARK: Menus

    func menu(for id: String) -> NSMenu {
        let menu = NSMenu()
        guard let app = app(id) else { return menu }
        for window in app.windows {
            let title = window.title.isEmpty ? app.name : window.title
            menu.addItem(ActionItem(window.isMinimized ? "\(title) (minimized)" : title) { [weak self] in
                self?.focus(window, of: id)
            })
        }
        if !app.windows.isEmpty { menu.addItem(.separator()) }
        menu.addItem(ActionItem(app.isRunning ? "Open New Window" : "Open \(app.name)") { [weak self] in
            if app.isRunning { self?.newWindow(id) } else { self?.launch(app) }
        })
        if app.id != PinList.finderID {
            menu.addItem(app.isPinned
                ? ActionItem("Unpin from Superbar") { [weak self] in self?.unpin(id) }
                : ActionItem("Pin to Superbar") { [weak self] in self?.pin(id) })
        }
        if app.windows.count == 1, let window = app.windows.first {
            menu.addItem(ActionItem("Close Window") { [weak self] in self?.close(window, of: id) })
        } else if app.windows.count > 1 {
            menu.addItem(ActionItem("Close All Windows") { [weak self] in
                for window in app.windows { self?.close(window, of: id) }
            })
        }
        if let pid = app.pid, app.id != PinList.finderID {
            menu.addItem(.separator())
            menu.addItem(ActionItem("Quit") { [weak self] in _ = self?.runningApp(pid)?.terminate() })
        }
        return menu
    }

    func barMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem("Superbar Settings…") { [weak self] in self?.onOpenSettings() })
        if dock?.isHidden == true {
            menu.addItem(ActionItem("Restore Dock") { [weak self] in self?.dock?.restore() })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Superbar") { NSApp.terminate(nil) })
        return menu
    }

    // MARK: Mission Control

    static let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    /// Opens Mission Control the way the Dock's Mission Control app does. No permission needed.
    func openMissionControl() {
        onCloseTransient()
        if FileManager.default.fileExists(atPath: Self.missionControlURL.path) {
            let config = NSWorkspace.OpenConfiguration()
            config.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: Self.missionControlURL, configuration: config) { _, _ in }
        } else {
            _ = Private.showMissionControl()
        }
    }

    // MARK: Show desktop

    func toggleShowDesktop() {
        onCloseTransient()
        if Private.toggleShowDesktop() {
            showDesktopOn.toggle()
            return
        }
        // Fallback: hide every other app, then unhide the same ones.
        if hiddenByShowDesktop.isEmpty {
            hiddenByShowDesktop = running.filter { !$0.isHidden && $0.bundleIdentifier != PinList.finderID }
            hiddenByShowDesktop.forEach { $0.hide() }
            showDesktopOn = true
        } else {
            hiddenByShowDesktop.forEach { $0.unhide() }
            hiddenByShowDesktop = []
            showDesktopOn = false
        }
    }
}

/// An NSMenuItem that runs a closure. The target lives in `representedObject`,
/// because a menu item holds its target weakly.
func ActionItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
    let target = MenuAction(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
    item.target = target
    item.representedObject = target
    return item
}

final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}
