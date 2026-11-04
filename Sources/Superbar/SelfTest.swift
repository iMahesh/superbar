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
            check("the bar cannot take focus", !app.bar.canBecomeKey)

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
            check("the Start menu opens and takes keys", app.startMenu.isOpen && NSApp.keyWindow is GlassPanel)
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

            // S-016
            app.settings.barSize = .small
            app.layoutBar()
            check("the small bar is 30 pt with 24 pt icons", app.bar.frame.height == 30 && app.settings.metrics.icon == 24)
            app.settings.barSize = .normal
            app.layoutBar()

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
