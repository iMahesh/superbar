import AppKit
import ApplicationServices
import SwiftUI
import SuperbarKit

// Superbar
//   Superbar                         the taskbar
//   APP_STORE=<x> Superbar           use a separate, emptied UserDefaults suite (tests, snapshots)
//   APP_SNAPSHOT=<dir> Superbar      save PNGs of the bar, Start menu, previews, calendar, and Settings, then quit
//   Superbar --render-icon <dir>     write the app icon's PNGs (tools/make_flat_icon.sh)
//   Superbar --windows <bundle id>   print the windows Superbar sees for one running app
//   Superbar --selftest              run the self-test and quit with 0 or 1 (tools/selftest.sh)

@main
enum SuperbarMain {
    static let delegate = AppDelegate()

    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), CommandLine.arguments.count > i + 1 {
            exit(AppIconArt.render(to: CommandLine.arguments[i + 1]) ? 0 : 1)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--windows"), CommandLine.arguments.count > i + 1 {
            // Debugging: what the window reader sees for one app, run from a trusted shell.
            let bid = CommandLine.arguments[i + 1]
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.processIdentifier
            else { print("not running"); exit(1) }
            let list = AXReader.read(pid: pid)
            print(list.map { "\($0.count) windows: " + $0.map { "\($0.windowID) \($0.title)\($0.isMinimized ? " (min)" : "")" }.joined(separator: ", ") } ?? "unknown")
            exit(0)
        }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon, like LSUIElement
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let permissions = Permissions.shared
    let tray = TrayModel()
    let model = TaskbarModel()
    let appIndex = AppIndex()
    private(set) lazy var dock = DockController()
    private(set) lazy var preview = PreviewController(model: model)
    private(set) lazy var startMenu = StartMenuController(model: StartMenuModel(index: appIndex, taskbar: model), settings: settings)
    private(set) lazy var calendar = CalendarController(settings: settings)
    private(set) lazy var trayPopovers = TrayPopoverController(tray: tray, settings: settings)
    private(set) lazy var settingsWindow = SettingsWindowController(state: settingsState) { [unowned self] in
        AnyView(SettingsView(state: settingsState, settings: settings, dock: dock, permissions: permissions).themed())
    }
    let settingsState = SettingsState()
    /// One bar per display, all showing the same apps.
    private(set) var bars: [BarPresenter] = []
    private var barsStarted = false
    /// The main display's bar (snapshots and the self-test use it).
    var barPresenter: BarPresenter? { bars.first { $0.displayID == CGMainDisplayID() } ?? bars.first }
    var bar: GlassPanel! { barPresenter?.panel }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        installMainMenu()
        wire()
        if ProcessInfo.processInfo.environment["SUPERBAR_DEBUG"] != nil {
            // Debugging, run from a trusted shell: press show desktop without a click.
            DistributedNotificationCenter.default().addObserver(forName: .init("com.maheshporeddy.superbar.debug.showDesktop"),
                                                                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.toggleShowDesktop() }
            }
        }
        syncBars()
        tray.start()

        if Snapshot.runIfRequested(self) { return }
        if SelfTest.runIfRequested(self) { return }

        model.startWatching()
        dock.upgradeIfNeeded()
        barsStarted = true
        for presenter in bars { presenter.start() }
        startWindowFitter()
        HotkeyCenter.shared.onStart = { [weak self] in self?.toggleStart() }
        HotkeyCenter.shared.register(settings.startHotkey)
        startSnapping()
        permissions.onAccessibilityGranted = { [weak self] in
            self?.model.accessibilityGranted()
            WindowFitter.shared.scanAll()
        }
        permissions.start()
        if !permissions.accessibility { settingsWindow.show(tab: .permissions) }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                SuperbarMain.delegate.layoutBar()
                WindowFitter.shared.scanAll()
            }
        }
        observeBarSize()
        observeVisibility()

        // Prewarm: build the Start panel and the popover and index apps, so the first open is instant.
        Task {
            try? await Task.sleep(for: .seconds(2))
            startMenu.prewarm()
            preview.prewarm()
        }
    }

    private func wire() {
        model.dock = dock
        model.onToggleStart = { [weak self] in self?.toggleStart() }
        model.onToggleCalendar = { [weak self] in
            self?.startMenu.close()
            self?.preview.hide()
            self?.trayPopovers.close()
            self?.calendar.toggle()
        }
        model.onTrayClick = { [weak self] item, rect in
            self?.startMenu.close()
            self?.preview.hide()
            self?.calendar.close()
            self?.trayPopovers.toggle(item, anchor: rect)
        }
        model.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        model.settingsState = settingsState
        model.onSettingsButton = { [weak self] in self?.settingsWindow.toggleFromBar() }
        model.onCloseSettings = { [weak self] in self?.settingsWindow.close() }
        model.onButtonHover = { [weak self] id, inside, rect in self?.preview.buttonHover(id, inside: inside, rect: rect) }
        model.onPick = { [weak self] id, rect in self?.preview.showNow(id, anchor: rect) }
        model.onCloseTransient = { [weak self] in
            self?.startMenu.close()
            self?.calendar.close()
            self?.preview.hide()
            self?.trayPopovers.close()
        }
        // Snapping keeps windows above the bar of their screen while it keeps its space.
        WindowSnapper.shared.reservedHeight = { [unowned self] screen in
            guard settings.barVisibility.reservesSpace,
                  let bar = bars.first(where: { $0.displayID == screen.displayID }), !bar.isFullScreen else { return 0 }
            return settings.metrics.height
        }
        WindowSnapper.shared.onNeedsAccessibility = { [weak self] in self?.settingsWindow.show(tab: .permissions) }
        Power.onAutomationDenied = { [weak self] in self?.settingsWindow.show(tab: .permissions) }
    }

    /// Keeps windows out from under the bar: on launch, when apps launch or come to the
    /// front, and when the bar or the screen changes. Window opens and resizes come from
    /// the AX observers (AXObserverHost).
    private func startWindowFitter() {
        let fitter = WindowFitter.shared
        fitter.isActive = { [unowned self] in settings.keepWindowsAbove }
        fitter.areas = { [unowned self] in
            // A bar that hides doesn't take room, like the Dock with auto-hide.
            bars.filter { !$0.isFullScreen && settings.barVisibility.reservesSpace }.compactMap { $0.screen }
                .map { FitArea.of($0, barHeight: settings.metrics.height) }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { WindowFitter.shared.scan(pid: pid) } }
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid else { return }
                // The first window often appears a moment after launch.
                Task {
                    for delay in [0.5, 1.5] {
                        try? await Task.sleep(for: .seconds(delay))
                        WindowFitter.shared.scan(pid: pid)
                    }
                }
            }
        }
        fitter.scanAll()
    }

    /// The ⌃⌥ shortcuts snap the front window.
    private func startSnapping() {
        HotkeyCenter.shared.onSnap = { WindowSnapper.shared.snapFrontWindow($0) }
        HotkeyCenter.shared.registerSnaps(settings.snapShortcuts)
    }

    func toggleStart() {
        calendar.close()
        trayPopovers.close()
        preview.hide()
        startMenu.toggle()
    }

    /// Full width along the bottom of every screen, or tucked below it while that
    /// screen shows a full-screen app (BarPresenter).
    func layoutBar() {
        syncBars()
    }

    /// A bar for each connected display: new displays get one, removed ones lose theirs.
    private func syncBars() {
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.displayID))
        for presenter in bars where !ids.contains(presenter.displayID) { presenter.stop() }
        bars.removeAll { !ids.contains($0.displayID) }
        for screen in screens where !bars.contains(where: { $0.displayID == screen.displayID }) {
            let panel = GlassPanel(content: TaskbarView(model: model, tray: tray, settings: settings, barID: screen.displayID),
                                   size: NSSize(width: screen.frame.width, height: settings.metrics.height),
                                   cornerRadius: 0, level: .statusBar)
            let presenter = BarPresenter(panel: panel, settings: settings, displayID: screen.displayID)
            presenter.heldOpen = { [unowned self] in
                startMenu.isOpen || preview.isVisible || calendar.isOpen || trayPopovers.isOpen || model.drag != nil
            }
            presenter.onFullScreenChange = { WindowFitter.shared.scanAll() }
            bars.append(presenter)
            if barsStarted { presenter.start() }
        }
        for presenter in bars { presenter.layout() }
    }

    private func observeBarSize() {
        withObservationTracking { _ = settings.barSize } onChange: {
            Task { @MainActor in
                SuperbarMain.delegate.layoutBar()
                WindowFitter.shared.scanAll()
                SuperbarMain.delegate.observeBarSize()
            }
        }
    }

    /// Auto-hide, always hide, and the hide delay take effect at once on every bar.
    private func observeVisibility() {
        withObservationTracking { _ = (settings.barVisibility, settings.autoHideDelay) } onChange: {
            Task { @MainActor in
                let app = SuperbarMain.delegate
                for presenter in app.bars { presenter.applyVisibility() }
                WindowFitter.shared.scanAll()
                app.observeVisibility()
            }
        }
    }

    /// Hidden, but it gives text fields ⌘C, ⌘V, ⌘A, and ⌘Z.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Superbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettings() { settingsWindow.show() }

    func applicationWillTerminate(_ notification: Notification) {
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}
