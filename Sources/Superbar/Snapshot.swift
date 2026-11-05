import AppKit
import ApplicationServices
import IOKit.pwr_mgt
import SwiftUI
import SuperbarKit

/// Screenshot mode for agents (tools/snap.sh):
///   APP_STORE=test APP_SNAPSHOT=/tmp/Superbar-shots ~/Applications/Superbar.app/Contents/MacOS/Superbar
/// writes <page>-light.png and <page>-dark.png for the bar (normal, small, three hover glows),
/// the Start menu (open and searching), the preview popover, the calendar, and each Settings tab,
/// with sample data, then quits. APP_SNAPSHOT_PAGES=bar,start limits the pages.
enum Snapshot {
    static var directory: String? {
        let dir = ProcessInfo.processInfo.environment["APP_SNAPSHOT"] ?? ""
        return dir.isEmpty ? nil : dir
    }

    static func runIfRequested(_ app: AppDelegate) -> Bool {
        guard let dir = directory else { return false }
        guard Store.isOverridden else {
            print("SNAPSHOT refused: set APP_STORE so real pins are never touched")
            NSApp.terminate(nil)
            return true
        }
        let only = ProcessInfo.processInfo.environment["APP_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        func wanted(_ page: String) -> Bool { only?.contains { page.hasPrefix($0) } ?? true }

        Task {
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Snapshots" as CFString, kIOPMUserActiveLocal, &activity)
            var awake: IOPMAssertionID = 0
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Snapshots" as CFString, &awake)
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            seed(app)
            try? await Task.sleep(for: .seconds(1.5))

            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                @MainActor func shot(_ page: String, _ window: NSWindow?) async {
                    guard wanted(page), let window else { return }
                    try? await Task.sleep(for: .seconds(0.6))
                    capture(window, to: "\(dir)/\(page)-\(mode).png")
                }

                app.settings.barSize = .normal
                app.layoutBar()
                await shot("bar", app.bar)
                for id in ["com.apple.Safari", "com.apple.mail", "com.apple.Notes"] {
                    app.model.hoveredID = id
                    await shot("bar-hover-\(id.split(separator: ".").last!.lowercased())", app.bar)
                }
                app.model.hoveredID = nil
                app.settings.barSize = .small
                app.layoutBar()
                await shot("bar-small", app.bar)
                app.settings.barSize = .normal
                app.layoutBar()

                if wanted("start") {
                    app.startMenu.open()
                    await shot("start-menu", NSApp.windows.first { $0.isVisible && $0.canBecomeKey && $0 is GlassPanel })
                    app.startMenu.model.query = "saf"
                    await shot("start-search", NSApp.windows.first { $0.isVisible && $0.canBecomeKey && $0 is GlassPanel })
                    app.startMenu.close()
                }

                if wanted("preview") {
                    let rect = buttonRect(app, index: 1)
                    app.preview.showNow("com.apple.Safari", anchor: rect)
                    await shot("preview", popover(app))
                    app.preview.hide()
                }

                if wanted("tray") {
                    let x = (app.bar?.frame.maxX ?? 1440) - 170
                    for item in TrayItem.allCases {
                        app.trayPopovers.open(item, anchor: NSRect(x: x, y: 0, width: 28, height: 40))
                        await shot("tray-\(item.rawValue)", popover(app))
                    }
                    app.trayPopovers.close()
                }

                if wanted("calendar") {
                    app.calendar.open()
                    await shot("calendar", app.calendar.panelForSnapshot)
                    app.calendar.close()
                }

                if wanted("settings") {
                    for tab in SettingsTab.allCases {
                        app.settingsWindow.show(tab: tab)
                        scrollToTop(app.settingsWindow.settingsWindow)
                        await shot("settings-\(tab.rawValue)", app.settingsWindow.settingsWindow)
                        // The rest of a long tab, a window height at a time: settings-general-2, -3, ...
                        if let scroll = scrollView(in: app.settingsWindow.settingsWindow?.contentView) {
                            var page = 2
                            while scrollDown(scroll) {
                                await shot("settings-\(tab.rawValue)-\(page)", app.settingsWindow.settingsWindow)
                                page += 1
                            }
                        }
                    }
                    // Auto-hide shows its delay row.
                    app.settings.barVisibility = .autoHide
                    app.settingsWindow.show(tab: .general)
                    scrollToTop(app.settingsWindow.settingsWindow)
                    await shot("settings-autohide", app.settingsWindow.settingsWindow)
                    app.settings.barVisibility = .alwaysShow
                    app.settingsWindow.settingsWindow?.close()
                }
            }
            print("SNAPSHOT done \(dir)")
            NSApp.terminate(nil)
        }
        return true
    }

    /// Sample apps: Finder, Safari (active, two windows), Mail (one window), Notes and
    /// Music (pinned, not running), Terminal (running, not pinned).
    private static func seed(_ app: AppDelegate) {
        let element = AXUIElementCreateApplication(getpid())
        let cache = IconCache.shared
        func make(_ id: String, pid: pid_t?, pinned: Bool, active: Bool = false, windows: [AppWindow] = []) -> TaskbarApp? {
            guard let url = cache.url(forBundleID: id) else { return nil }
            let icon = cache.icon(for: id, url: url, running: nil)
            return TaskbarApp(id: id, bundleID: id, pid: pid, name: TaskbarModel.displayName(url), icon: icon, url: url,
                              isPinned: pinned, isActive: active, isHidden: false, windows: windows,
                              glowColor: cache.glow(for: id, icon: icon))
        }
        let safariWindows = [
            AppWindow(windowID: 0, element: element, title: "Superbar – Release notes", isMinimized: false),
            AppWindow(windowID: 0, element: AXUIElementCreateApplication(1), title: "Weather in Lisbon", isMinimized: true),
        ]
        app.model.staticApps = [
            make("com.apple.finder", pid: 10, pinned: true, windows: [AppWindow(windowID: 0, element: element, title: "Downloads", isMinimized: false)]),
            make("com.apple.Safari", pid: 11, pinned: true, active: true, windows: safariWindows),
            make("com.apple.mail", pid: 12, pinned: true, windows: [AppWindow(windowID: 0, element: element, title: "Inbox", isMinimized: false)]),
            make("com.apple.Notes", pid: nil, pinned: true),
            make("com.apple.Music", pid: nil, pinned: true),
            make("com.apple.Terminal", pid: 13, pinned: false, windows: [AppWindow(windowID: 0, element: element, title: "zsh", isMinimized: false)]),
        ].compactMap { $0 }

        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 4; parts.hour = 9; parts.minute = 41
        app.tray.setForTesting(now: Calendar.current.date(from: parts) ?? .now, volume: 0.6, network: .wifi,
                               battery: .init(percent: 76, charging: false, onPower: false, minutesLeft: 312),
                               wifiName: "Home")
        for id in ["com.apple.TextEdit", "com.apple.Preview", "com.apple.calculator"] { app.model.noteRecent(id) }
        app.appIndex.start()
    }

    /// The tallest scroll view in a window: the Settings form.
    private static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { found.append(s) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found.max { $0.frame.height < $1.frame.height }
    }

    private static func scrollToTop(_ window: NSWindow?) {
        guard let scroll = scrollView(in: window?.contentView) else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Scrolls down by most of a page (keeping a little overlap). False at the bottom.
    private static func scrollDown(_ scroll: NSScrollView) -> Bool {
        let clip = scroll.contentView
        guard let doc = scroll.documentView else { return false }
        let maxY = max(doc.frame.height - clip.bounds.height, 0)
        let y = clip.bounds.origin.y
        let next = min(y + clip.bounds.height - 60, maxY)
        guard next > y + 1 else { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: next))
        scroll.reflectScrolledClipView(clip)
        return true
    }

    private static func buttonRect(_ app: AppDelegate, index: Int) -> NSRect {
        let m = app.settings.metrics
        let x = (app.bar?.frame.minX ?? 0) + m.appStripStart + CGFloat(index) * m.buttonWidth
        return NSRect(x: x, y: app.bar?.frame.minY ?? 0, width: m.buttonWidth, height: m.height)
    }

    private static func popover(_ app: AppDelegate) -> NSWindow? {
        // Not a bar (there is one per display) and not the Start menu, which can take focus.
        let bars = Set(app.bars.map { ObjectIdentifier($0.panel) })
        return NSApp.windows.first { $0.isVisible && $0 is GlassPanel && !bars.contains(ObjectIdentifier($0)) && $0 !== app.startMenu.panelForSnapshot }
    }

    /// Captures the real window with screencapture, so glass looks as on screen. That needs
    /// Screen Recording for the app that started this one (your terminal, or Claude).
    /// Without it, falls back to drawing the view hierarchy, which leaves the glass blank.
    private static func capture(_ window: NSWindow, to path: String) {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        try? FileManager.default.removeItem(atPath: path)
        for _ in 1...3 {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? shot.run()
            shot.waitUntilExit()
            if FileManager.default.fileExists(atPath: path) {
                print("SNAPSHOT \(path)")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("SNAPSHOT \(path) (fallback: no Screen Recording permission, glass is blank)")
        }
    }
}
