import AppKit
import SuperbarKit

/// Self-test for agents: runs the app's real functions on a test UserDefaults suite,
/// prints PASS or FAIL per check, and quits with exit code 0 or 1 (tools/selftest.sh).
/// It never touches the real Dock, real pins, or other apps' windows.
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(_ app: AppDelegate) -> Bool {
        guard requested else { return false }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE so real pins are never touched")
            finish(code: 1)
            return true
        }
        Task {
            let model = app.model
            model.reloadRunning()
            try? await Task.sleep(for: .seconds(0.5))

            // S-001, S-002
            let apps = model.apps
            check("Finder is the first button", apps.first?.id == PinList.finderID)
            let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
            check("every running button is a regular app", apps.filter(\.isRunning).allSatisfy { regular.contains($0.id) || $0.id.hasPrefix("pid:") })
            check("the bar is full width at the bottom of the main screen",
                  app.bar.frame.minY == NSScreen.screens.first?.frame.minY && app.bar.frame.width == NSScreen.screens.first?.frame.width)
            check("the bar is 40 pt tall", app.bar.frame.height == 40)
            // S-021: one bar per display, along its bottom edge, all from the same app list.
            check("every display has its own bar", app.bars.count == NSScreen.screens.count
                  && NSScreen.screens.allSatisfy { s in app.bars.contains { $0.displayID == s.displayID } },
                  "\(app.bars.count) bars for \(NSScreen.screens.count) displays")
            check("each bar spans the bottom of its display", app.bars.allSatisfy { b in
                guard let f = b.screen?.frame else { return false }
                return b.panel.frame.minX == f.minX && b.panel.frame.minY == f.minY && b.panel.frame.width == f.width
            })
            check("the bar cannot take focus", !app.bar.canBecomeKey)
            check("the bar sits above normal windows", app.bar.level == .statusBar, "level \(app.bar.level.rawValue)")
            check("the private focus and show-desktop calls exist", Private.missing.isEmpty, Private.missing.joined(separator: ", "))

            // Which view a click lands on: SwiftUI for the orb and clock, a button's own
            // mouse view for an app, and the bar's mouse view (its right-click menu) on empty space.
            if let content = app.bar.contentView {
                let m = app.settings.metrics
                let y = m.height / 2
                @MainActor func hit(_ x: CGFloat) -> NSView? { content.hitTest(NSPoint(x: x, y: y)) }
                let orb = hit(Space.xs + m.orb / 2)
                check("a click on the orb reaches the orb", !(orb is MouseCatcher.CatcherView), "\(type(of: orb))")
                let mission = hit(m.orb + Space.xs * 2 + m.missionControlWidth / 2)
                check("a click on Mission Control reaches its button", !(mission is MouseCatcher.CatcherView), "\(type(of: mission))")
                check("Mission Control's app is there to open", FileManager.default.fileExists(atPath: TaskbarModel.missionControlURL.path))
                let button = hit(m.appStripStart + m.buttonWidth / 2)
                check("a click on the first app reaches its button",
                      button is MouseCatcher.CatcherView && button?.frame.width == m.buttonWidth, "\(type(of: button)) \(button?.frame.width ?? 0)")
                let empty = hit(content.bounds.width * 0.6)
                check("a right click on empty bar space reaches the bar menu",
                      empty is MouseCatcher.CatcherView && empty?.frame.width == content.bounds.width, "\(type(of: empty)) \(empty?.frame.width ?? 0)")
                let clock = hit(content.bounds.width - m.showDesktopWidth - 30)
                check("a click on the clock reaches the clock", !(clock is MouseCatcher.CatcherView), "\(type(of: clock))")
            }

            // S-004
            model.pin("com.apple.TextEdit")
            check("pinning adds the app to the bar", model.apps.contains { $0.id == "com.apple.TextEdit" && $0.isPinned })
            let reloaded = TaskbarModel(defaults: Store.defaults)
            check("pins survive a relaunch", reloaded.pins.contains("com.apple.TextEdit"))
            model.unpin(PinList.finderID)
            check("Finder cannot be unpinned", model.pins.contains(PinList.finderID))
            model.unpin("com.apple.TextEdit")
            check("unpinning removes a pinned app that is not running",
                  !model.apps.contains { $0.id == "com.apple.TextEdit" } || model.apps.contains { $0.id == "com.apple.TextEdit" && $0.isRunning })

            // S-005
            app.appIndex.start()
            try? await Task.sleep(for: .seconds(1))
            let start = app.startMenu.model
            start.query = "saf"
            check("\"saf\" finds Safari first", start.results.first?.bundleID == "com.apple.Safari", "got \(start.results.first?.name ?? "nothing")")
            start.query = ""
            app.startMenu.open()
            try? await Task.sleep(for: .seconds(0.3))
            check("the Start menu opens and takes keys", app.startMenu.isOpen && NSApp.keyWindow is GlassPanel,
                  "open \(app.startMenu.isOpen), key window \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none"), active \(NSApp.isActive)")
            check("typing goes to the search field", app.startMenu.searchHasFocus,
                  "field \(app.startMenu.model.field == nil ? "missing" : "exists"), first responder \(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
            app.startMenu.toggle()
            check("pressing the Start shortcut again closes it", !app.startMenu.isOpen)

            // S-007
            check("the clock ticks at the start of the next minute",
                  Calendar.current.component(.second, from: app.tray.nextTick) == 0 && app.tray.nextTick.timeIntervalSinceNow <= 60)
            check("the clock shows time and date", !app.tray.timeText.isEmpty && !app.tray.dateText.isEmpty)

            // S-012
            if let safari = IconCache.shared.url(forBundleID: "com.apple.Safari") {
                let icon = NSWorkspace.shared.icon(forFile: safari.path)
                let hue = IconCache.mainColor(of: icon)?.hsb.h ?? -1
                check("Safari's glow is blue", (180...250).contains(hue), "hue \(hue)")
            }

            // S-015: a fake Dock, never the real one.
            final class FakeDock: DockPreferences {
                var autohide: Bool? = false
                var autohideDelay: Double? = 0.2
                func write(autohide: Bool?, autohideDelay: Double?) { self.autohide = autohide; self.autohideDelay = autohideDelay }
                func restartDock() {}
            }
            let fake = FakeDock()
            let control = DockControl(prefs: fake, store: Store.defaults)
            control.hideDock()
            control.restoreDock()
            check("Restore Dock puts back the exact settings", fake.autohide == false && fake.autohideDelay == 0.2)

            // S-017: full screen, driven by hand so no real app has to go full screen.
            if let presenter = app.barPresenter, let screen = NSScreen.screens.first?.frame {
                let panels: [NSWindow] = [app.bar] + NSApp.windows.filter { $0 is GlassPanel && $0 !== app.bar }
                check("the bar and its popovers can appear over full-screen apps",
                      panels.allSatisfy { $0.collectionBehavior.contains(.fullScreenAuxiliary) })
                let detected = await FullScreenDetector.isFullScreen(
                    display: CGMainDisplayID(), screen: CGRect(origin: .zero, size: screen.size),
                    frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
                print("INFO full screen detected right now: \(detected)")

                presenter.detectionEnabled = false
                let edge = NSPoint(x: screen.midX, y: screen.minY)
                let away = NSPoint(x: screen.midX, y: screen.midY)
                let t = ProcessInfo.processInfo.systemUptime
                presenter.setFullScreen(true)
                try? await Task.sleep(for: .seconds(0.4))
                check("in full screen the bar hides", !presenter.isShown && !app.bar.isVisible,
                  "shown \(presenter.isShown) visible \(app.bar.isVisible) start \(app.startMenu.isOpen) preview \(app.preview.isVisible) calendar \(app.calendar.isOpen)")
                presenter.poll(pointer: away, now: t + 1)
                presenter.poll(pointer: edge, now: t + 2)
                presenter.poll(pointer: edge, now: t + 2.1)
                check("a quick touch of the bottom edge does not show it", !presenter.isShown)
                presenter.poll(pointer: edge, now: t + 2.3)
                try? await Task.sleep(for: .seconds(0.4))
                check("resting on the bottom edge slides the bar up",
                      presenter.isShown && app.bar.isVisible && abs(app.bar.frame.minY - screen.minY) < 1)
                presenter.poll(pointer: away, now: t + 3)
                presenter.poll(pointer: away, now: t + 3.7)
                try? await Task.sleep(for: .seconds(0.4))
                check("moving away hides it again", !presenter.isShown && !app.bar.isVisible)
                app.startMenu.open()
                presenter.poll(pointer: away, now: t + 4)
                presenter.poll(pointer: away, now: t + 6)
                check("the bar stays up while the Start menu is open", presenter.isShown)
                app.startMenu.close()
                presenter.setFullScreen(false)
                try? await Task.sleep(for: .seconds(0.4))
                check("leaving full screen brings the bar back",
                      presenter.isShown && app.bar.isVisible && abs(app.bar.frame.minY - screen.minY) < 1 && app.bar.alphaValue > 0.99)
                presenter.detectionEnabled = true
            }

            // Tray: each icon is its own clickable view, and each opens its popover.
            if let content = app.bar.contentView {
                @MainActor func catchers(_ v: NSView) -> [NSView] { (v is MouseCatcher.CatcherView ? [v] : []) + v.subviews.flatMap(catchers) }
                let trayButtons = catchers(content).filter { $0.frame.width < app.settings.metrics.buttonWidth }
                let expected = app.tray.battery == nil ? 2 : 3
                check("each tray icon is clickable", trayButtons.count == expected, "\(trayButtons.count) of \(expected)")
            }
            for item in TrayItem.allCases where item != .battery || app.tray.battery != nil {
                let anchor = NSRect(x: (NSScreen.screens.first?.frame.maxX ?? 800) - 160, y: 0, width: 28, height: 40)
                app.model.onTrayClick(item, anchor)
                try? await Task.sleep(for: .seconds(0.2))
                let opened = app.trayPopovers.isOpen && app.trayPopovers.item == item
                app.model.onTrayClick(item, anchor)
                check("the \(item.rawValue) icon opens its popover, and a second click closes it", opened && !app.trayPopovers.isOpen)
            }
            if let volume = app.tray.volume, app.tray.volumeSettable {
                // Writes the volume it already has, so nothing audible changes.
                check("the volume slider can set the volume", app.tray.setVolume(volume))
            }

            // App icon
            check("the app has its icon", Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil)

            // S-016
            app.settings.barSize = .small
            app.layoutBar()
            check("the small bar is 30 pt with 24 pt icons", app.bar.frame.height == 30 && app.settings.metrics.icon == 24)
            app.settings.barSize = .normal
            app.layoutBar()

            // S-022: Settings is a window like any app's.
            app.settingsWindow.show()
            try? await Task.sleep(for: .milliseconds(300))
            let settingsWindow = app.settingsWindow.settingsWindow
            check("Settings can be minimized", settingsWindow?.styleMask.contains(.miniaturizable) == true)
            check("while Settings is open Superbar is a regular app", NSApp.activationPolicy() == .regular)
            check("open Settings has a button on the bar", model.apps.contains { $0.id == TaskbarModel.settingsID })
            settingsWindow?.miniaturize(nil)
            try? await Task.sleep(for: .milliseconds(800))
            check("minimized Settings keeps its button, shown minimized",
                  model.apps.first { $0.id == TaskbarModel.settingsID }?.windows.first?.isMinimized == true)
            app.settingsWindow.toggleFromBar()
            try? await Task.sleep(for: .milliseconds(800))
            check("its button restores it", settingsWindow?.isMiniaturized == false && settingsWindow?.isVisible == true)
            app.settingsWindow.close()
            try? await Task.sleep(for: .milliseconds(300))
            check("closing Settings removes its button and the Dock icon",
                  !model.apps.contains { $0.id == TaskbarModel.settingsID } && NSApp.activationPolicy() == .accessory)

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
        return true
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    static func finish(code: Int32) {
        exitCode = code
        NSApp.terminate(nil)
    }
}
