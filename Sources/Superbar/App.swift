import AppKit
import ApplicationServices
import SwiftUI
import SuperbarKit

// Superbar
//   Superbar                         the taskbar
//   APP_STORE=<x> Superbar           use a separate, emptied UserDefaults suite (tests, snapshots)
//   APP_SNAPSHOT=<dir> Superbar      save PNGs of the bar, Start menu, previews, calendar, and Settings, then quit
//   Superbar --render-icon <dir>     write the app icon's PNGs (tools/make_flat_icon.sh)
//   Superbar --selftest              run the self-test and quit with 0 or 1 (tools/selftest.sh)

@main
enum SuperbarMain {
    static let delegate = AppDelegate()

    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), CommandLine.arguments.count > i + 1 {
            exit(AppIconArt.render(to: CommandLine.arguments[i + 1]) ? 0 : 1)
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
    private(set) var bar: GlassPanel!
    private(set) var barPresenter: BarPresenter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        installMainMenu()
        wire()
        bar = GlassPanel(content: TaskbarView(model: model, tray: tray, settings: settings),
                         size: NSSize(width: 800, height: settings.metrics.height), cornerRadius: 0, level: .statusBar)
        let presenter = BarPresenter(panel: bar, settings: settings)
        presenter.heldOpen = { [unowned self] in
            startMenu.isOpen || preview.isVisible || calendar.isOpen || trayPopovers.isOpen || model.drag != nil
        }
        barPresenter = presenter
        layoutBar()
        tray.start()

        if Snapshot.runIfRequested(self) { return }
        if SelfTest.runIfRequested(self) { return }

        model.startWatching()
        presenter.start()
        HotkeyCenter.shared.onStart = { [weak self] in self?.toggleStart() }
        HotkeyCenter.shared.register(settings.startHotkey)
        permissions.onAccessibilityGranted = { [weak self] in self?.model.accessibilityGranted() }
        permissions.start()
        if !permissions.accessibility { settingsWindow.show(tab: .permissions) }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SuperbarMain.delegate.layoutBar() }
        }
        observeBarSize()

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
        model.onButtonHover = { [weak self] id, inside, rect in self?.preview.buttonHover(id, inside: inside, rect: rect) }
        model.onPick = { [weak self] id, rect in self?.preview.showNow(id, anchor: rect) }
        model.onCloseTransient = { [weak self] in
            self?.startMenu.close()
            self?.calendar.close()
            self?.preview.hide()
            self?.trayPopovers.close()
        }
        Power.onAutomationDenied = { [weak self] in self?.settingsWindow.show(tab: .permissions) }
    }

    func toggleStart() {
        calendar.close()
        trayPopovers.close()
        preview.hide()
        startMenu.toggle()
    }

    /// Full width along the bottom of the main screen (the one with the menu bar),
    /// or tucked below it while a full-screen app is showing (BarPresenter).
    func layoutBar() {
        barPresenter?.layout()
    }

    private func observeBarSize() {
        withObservationTracking { _ = settings.barSize } onChange: {
            Task { @MainActor in
                SuperbarMain.delegate.layoutBar()
                SuperbarMain.delegate.observeBarSize()
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
