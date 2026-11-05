import Foundation
import Testing
@testable import SuperbarKit

// S-001
@Test func barHoldsOnlyRegularAppsFinderFirst() {
    let running = [
        AppOrdering.Running(id: "com.apple.Safari", isRegular: true, launchOrder: 3),
        AppOrdering.Running(id: "com.apple.controlcenter", isRegular: false, launchOrder: 1),
        AppOrdering.Running(id: "com.apple.finder", isRegular: true, launchOrder: 2),
        AppOrdering.Running(id: "com.apple.Notes", isRegular: true, launchOrder: 0),
    ]
    let ids = AppOrdering.order(pinned: PinList(), running: running)
    #expect(ids == ["com.apple.finder", "com.apple.Notes", "com.apple.Safari"])
}

@Test func pinnedAppKeepsItsSlotWhenItLaunches() {
    let pins = PinList(["com.apple.mail", "com.apple.Safari"])
    let ids = AppOrdering.order(pinned: pins, runningInLaunchOrder: ["com.apple.Notes", "com.apple.Safari"])
    #expect(ids == ["com.apple.finder", "com.apple.mail", "com.apple.Safari", "com.apple.Notes"])
}

// S-003
@Test func clickResolverCoversEveryState() {
    #expect(ClickResolver.resolve(.init(isRunning: false)) == .launch)
    #expect(ClickResolver.resolve(.init(isRunning: true, visibleWindows: 2)) == .focus)
    #expect(ClickResolver.resolve(.init(isRunning: true, isHidden: true, visibleWindows: 1)) == .unhide)
    #expect(ClickResolver.resolve(.init(isRunning: true, minimizedWindows: 1)) == .restoreMinimized)
    #expect(ClickResolver.resolve(.init(isRunning: true, isActive: true, visibleWindows: 1)) == .minimize)
    #expect(ClickResolver.resolve(.init(isRunning: true, isActive: true, minimizedWindows: 1)) == .restoreMinimized)
    #expect(ClickResolver.resolve(.init(isRunning: true, isActive: true, visibleWindows: 2)) == .pick)
    #expect(ClickResolver.resolve(.init(isRunning: true, isActive: true, visibleWindows: 1, minimizedWindows: 1)) == .pick)
    #expect(ClickResolver.resolve(.init(isRunning: true)) == .reopen)
    #expect(ClickResolver.resolve(.init(isRunning: true, isActive: true)) == .reopen)
}

// S-004
@Test func pinningKeepsOrderAndFinderStays() {
    var pins = PinList(["com.apple.mail"])
    pins.pin("com.apple.Safari")
    pins.pin("com.apple.Notes", at: 1)
    #expect(pins.ids == ["com.apple.finder", "com.apple.Notes", "com.apple.mail", "com.apple.Safari"])
    #expect(pins.unpin("com.apple.finder") == false)
    pins.unpin("com.apple.mail")
    #expect(pins.ids == ["com.apple.finder", "com.apple.Notes", "com.apple.Safari"])
    pins.move("com.apple.Safari", to: 0)
    #expect(pins.ids == ["com.apple.finder", "com.apple.Safari", "com.apple.Notes"])
    #expect(PinList(["com.apple.Notes", "com.apple.finder", "com.apple.Notes"]).ids == ["com.apple.finder", "com.apple.Notes"])
}

@Test func recentListKeepsTenNewestFirst() {
    var recent = RecentList()
    for i in 0..<12 { recent.note("app\(i)") }
    recent.note("app5")
    #expect(recent.ids.count == 10)
    #expect(recent.ids.first == "app5")
    #expect(!recent.ids.contains("app0"))
}

// S-005
@Test func searchRanksPrefixThenWordStartThenContains() {
    let names = ["Mosaffa", "Safari", "Unsafe Notes", "Calendar"]
    let ranked = SearchRanker.rank(names, query: "saf") { $0 }
    #expect(ranked == ["Safari", "Unsafe Notes", "Mosaffa"] || ranked == ["Safari", "Mosaffa", "Unsafe Notes"])
    #expect(ranked.first == "Safari")
    #expect(SearchRanker.match(name: "Visual Studio Code", query: "stu") == .wordStart)
    #expect(SearchRanker.match(name: "FaceTime", query: "time") == .wordStart)
    #expect(SearchRanker.match(name: "Mosaffa", query: "saf") == .contains)
    #expect(SearchRanker.match(name: "Calendar", query: "saf") == nil)
}

// S-007
@Test func clockTicksAtTheStartOfTheNextMinute() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9, minute: 41, second: 27))!
    let next = ClockTick.nextMinute(after: date, calendar: cal)
    let parts = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: next)
    #expect(parts.hour == 9 && parts.minute == 42 && parts.second == 0)
    #expect(next.timeIntervalSince(date) == 33)
}

// S-011
@Test func minimizedWindowsListAfterVisibleOnes() {
    let windows = [("a", true), ("b", false), ("c", true), ("d", false)]
    #expect(WindowOrder.pickerOrder(windows) { $0.1 }.map(\.0) == ["b", "d", "a", "c"])
}

// S-012
private func icon(_ fill: (Int) -> (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
    (0..<256).flatMap { i -> [UInt8] in let p = fill(i); return [p.0, p.1, p.2, p.3] }
}

@Test func mostlyBlueIconGlowsBlue() {
    let px = icon { i in i % 5 == 0 ? (200, 200, 200, 255) : (i % 7 == 0 ? (0, 0, 0, 0) : (30, 90, 220, 255)) }
    let glow = try! #require(GlowColor.from(premultipliedRGBA: px))
    #expect((200...250).contains(glow.hsb.h))
    #expect(glow.hsb.s > 0.6)
}

@Test func grayIconFallsBackToAccent() {
    #expect(GlowColor.from(premultipliedRGBA: icon { i in let v = UInt8(i % 256); return (v, v, v, 255) }) == nil)
    #expect(GlowColor.from(premultipliedRGBA: icon { _ in (0, 0, 0, 0) }) == nil)
}

// S-015
private final class FakeDock: DockPreferences {
    var prefs: [String: Any]
    var restarts = 0
    init(_ prefs: [String: Any]) { self.prefs = prefs }
    func value(_ key: String) -> Any? { prefs[key] }
    func write(_ values: [String: Any?]) { for (k, v) in values { prefs[k] = v } }
    func restartDock() { restarts += 1 }
}

@Test func dockControlSavesOldValuesFirstAndRestoresThem() {
    let store = UserDefaults(suiteName: "superbar.tests.\(UUID().uuidString)")!
    let dock = FakeDock(["autohide": false, "orientation": "left", "tilesize": 64.0])
    let control = DockControl(prefs: dock, store: store)
    control.hideDock()
    #expect(control.hasSavedState && !control.needsUpgrade)
    #expect(control.savedValue("autohide") as? Bool == false && control.savedValue("autohide-delay") == nil)
    #expect(dock.prefs["autohide"] as? Bool == true && dock.prefs["autohide-delay"] as? Double == 1000)
    // At the bottom with small icons: minimizing goes toward the bar, Mission Control's Dock fits under it.
    #expect(dock.prefs["orientation"] as? String == "bottom" && dock.prefs["tilesize"] as? Double == 16)
    // Hiding twice must not overwrite the saved originals with our own values.
    control.hideDock()
    #expect(control.savedValue("orientation") as? String == "left")
    control.restoreDock()
    #expect(dock.prefs["autohide"] as? Bool == false && dock.prefs["autohide-delay"] == nil)
    #expect(dock.prefs["orientation"] as? String == "left" && dock.prefs["tilesize"] as? Double == 64)
    #expect(dock.prefs["magnification"] == nil)
    #expect(!control.hasSavedState)
    #expect(dock.restarts == 3)
}

@Test func dockControlUpgradesTheFirstSavedFormat() {
    let store = UserDefaults(suiteName: "superbar.tests.\(UUID().uuidString)")!
    // Saved by the first version: only autohide and its delay, which were then unset.
    store.set(["saved": true], forKey: "dockControl.saved")
    let dock = FakeDock(["autohide": true, "autohide-delay": 1000.0, "orientation": "left", "tilesize": 16.0])
    let control = DockControl(prefs: dock, store: store)
    #expect(control.needsUpgrade)
    control.hideDock()
    #expect(!control.needsUpgrade && dock.prefs["orientation"] as? String == "bottom")
    control.restoreDock()
    #expect(dock.prefs["autohide"] == nil && dock.prefs["autohide-delay"] == nil)   // the true originals
    #expect(dock.prefs["orientation"] as? String == "left")
}

@Test func keyComboShowsSymbols() {
    #expect(KeyCombo.startDefault.display == "⌃⎋")
    #expect(KeyCombo(keyCode: 49, modifiers: KeyCombo.command | KeyCombo.option).display == "⌥⌘Space")
}

// S-017
@Test func edgeRevealShowsAfterRestingOnTheEdge() {
    var r = EdgeReveal()
    #expect(r.update(pointerHeight: 300, barHeight: 40, heldOpen: false, now: 0) == .none)
    #expect(r.update(pointerHeight: 0, barHeight: 40, heldOpen: false, now: 1.0) == .none)
    #expect(r.update(pointerHeight: 1, barHeight: 40, heldOpen: false, now: 1.1) == .none)
    #expect(r.update(pointerHeight: 0, barHeight: 40, heldOpen: false, now: 1.25) == .show)
    #expect(r.isRevealed)
}

@Test func edgeRevealIgnoresAQuickPass() {
    var r = EdgeReveal()
    _ = r.update(pointerHeight: 0, barHeight: 40, heldOpen: false, now: 0)
    _ = r.update(pointerHeight: 80, barHeight: 40, heldOpen: false, now: 0.1)
    #expect(r.update(pointerHeight: 0, barHeight: 40, heldOpen: false, now: 0.25) == .none)
    #expect(!r.isRevealed)
}

@Test func edgeRevealStaysOverTheBarAndHidesAfterLeaving() {
    var r = EdgeReveal()
    _ = r.update(pointerHeight: 0, barHeight: 40, heldOpen: false, now: 0)
    #expect(r.update(pointerHeight: 0, barHeight: 40, heldOpen: false, now: 0.3) == .show)
    #expect(r.update(pointerHeight: 30, barHeight: 40, heldOpen: false, now: 5) == .none)
    #expect(r.update(pointerHeight: 400, barHeight: 40, heldOpen: false, now: 6) == .none)
    #expect(r.update(pointerHeight: 30, barHeight: 40, heldOpen: false, now: 6.4) == .none)  // came back: timer resets
    #expect(r.update(pointerHeight: 400, barHeight: 40, heldOpen: false, now: 7) == .none)
    #expect(r.update(pointerHeight: 400, barHeight: 40, heldOpen: false, now: 7.7) == .hide)
    #expect(!r.isRevealed)
}

@Test func edgeRevealHoldsWhileAMenuIsOpen() {
    var r = EdgeReveal()
    #expect(r.update(pointerHeight: 500, barHeight: 40, heldOpen: true, now: 0) == .show)
    #expect(r.update(pointerHeight: 500, barHeight: 40, heldOpen: true, now: 10) == .none)
    #expect(r.update(pointerHeight: 500, barHeight: 40, heldOpen: false, now: 10.1) == .none)
    #expect(r.update(pointerHeight: 500, barHeight: 40, heldOpen: false, now: 10.8) == .hide)
}

@Test func edgeRevealUsesTheChosenHideDelay() {
    var r = EdgeReveal()
    r.hideDelay = 3
    _ = r.update(pointerHeight: 0, barHeight: 40, heldOpen: false, now: 0)
    #expect(r.update(pointerHeight: 0, barHeight: 40, heldOpen: false, now: 0.3) == .show)
    #expect(r.update(pointerHeight: 500, barHeight: 40, heldOpen: false, now: 1) == .none)
    #expect(r.update(pointerHeight: 500, barHeight: 40, heldOpen: false, now: 3.9) == .none)
    #expect(r.update(pointerHeight: 500, barHeight: 40, heldOpen: false, now: 4.0) == .hide)
    r.reset()
    #expect(r.hideDelay == 3)   // reset keeps the delay
}

@Test func alwaysHideIgnoresTheEdgeButShowsForTheStartMenu() {
    var r = EdgeReveal()
    r.edgeEnabled = false
    _ = r.update(pointerHeight: 0, barHeight: 40, heldOpen: false, now: 0)
    #expect(r.update(pointerHeight: 0, barHeight: 40, heldOpen: false, now: 5) == .none)
    #expect(r.update(pointerHeight: 500, barHeight: 40, heldOpen: true, now: 6) == .show)
    #expect(r.update(pointerHeight: 500, barHeight: 40, heldOpen: false, now: 6.1) == .none)
    #expect(r.update(pointerHeight: 500, barHeight: 40, heldOpen: false, now: 6.8) == .hide)
}

@Test func barVisibilityModes() {
    #expect(!BarVisibility.alwaysShow.hides(fullScreen: false))
    #expect(BarVisibility.alwaysShow.hides(fullScreen: true))
    #expect(BarVisibility.autoHide.hides(fullScreen: false))
    #expect(BarVisibility.alwaysHide.hides(fullScreen: false))
    #expect(BarVisibility.autoHide.edgeReveals && !BarVisibility.alwaysHide.edgeReveals)
    #expect(BarVisibility.alwaysShow.reservesSpace && !BarVisibility.autoHide.reservesSpace)
    #expect(BarVisibility.clampDelay(-1) == 0 && BarVisibility.clampDelay(42) == 10 && BarVisibility.clampDelay(1.5) == 1.5)
}

@Test func screenCoverFindsOnlyWholeScreenWindowsOfTheFrontApp() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let full = ScreenCover.Window(bounds: screen, layer: 0, ownerPID: 7)
    let zoomed = ScreenCover.Window(bounds: CGRect(x: 0, y: 33, width: 1512, height: 949), layer: 0, ownerPID: 7)
    let menuBar = ScreenCover.Window(bounds: screen, layer: 25, ownerPID: 7)
    #expect(ScreenCover.isFullScreen([full], frontPID: 7, screen: screen))
    #expect(!ScreenCover.isFullScreen([full], frontPID: 8, screen: screen))
    #expect(!ScreenCover.isFullScreen([zoomed, menuBar], frontPID: 7, screen: screen))
}

// S-019
@Test func zoomedWindowIsTrimmedToEndAboveTheBar() {
    // 1440 by 900 screen, 24 pt menu bar, 40 pt bar: windows must end at 860.
    let zoomed = CGRect(x: 0, y: 24, width: 1440, height: 876)
    #expect(WorkArea.fit(zoomed, top: 24, bottom: 860, screenWidth: 1440) == CGRect(x: 0, y: 24, width: 1440, height: 836))
}

@Test func windowWithRoomAboveMovesUpUnchanged() {
    let low = CGRect(x: 100, y: 500, width: 600, height: 380)
    #expect(WorkArea.fit(low, top: 24, bottom: 860, screenWidth: 1440) == CGRect(x: 100, y: 480, width: 600, height: 380))
}

@Test func windowsThatFitOrAreElsewhereAreLeftAlone() {
    #expect(WorkArea.fit(CGRect(x: 0, y: 24, width: 800, height: 836), top: 24, bottom: 860, screenWidth: 1440) == nil)
    // On a screen to the right.
    #expect(WorkArea.fit(CGRect(x: 1600, y: 24, width: 800, height: 900), top: 24, bottom: 860, screenWidth: 1440) == nil)
    // Parked below the bar entirely.
    #expect(WorkArea.fit(CGRect(x: 0, y: 870, width: 800, height: 400), top: 24, bottom: 860, screenWidth: 1440) == nil)
    // Would become too short.
    #expect(WorkArea.fit(CGRect(x: 0, y: 800, width: 800, height: 900), top: 790, bottom: 860, screenWidth: 1440) == nil)
}

// S-020
@Test func pinnedAppsAlwaysShowUnpinnedOnlyWithLiveWindows() {
    #expect(AppVisibility.isShown(isPinned: true, isRunning: false, windows: .unknown))
    #expect(AppVisibility.isShown(isPinned: true, isRunning: true, windows: .known(count: 0)))
    #expect(!AppVisibility.isShown(isPinned: false, isRunning: true, windows: .known(count: 0)))
    #expect(AppVisibility.isShown(isPinned: false, isRunning: true, windows: .known(count: 1)))
    #expect(!AppVisibility.isShown(isPinned: false, isRunning: false, windows: .known(count: 2)))
    // Accessibility off or no successful read yet: keep the button.
    #expect(AppVisibility.isShown(isPinned: false, isRunning: true, windows: .unknown))
}

/// Windows as ints; negative ones are auxiliary panels.
private func resolve(_ list: AXQuery<[Int]>, focused: AXQuery<Int> = .none, main: AXQuery<Int> = .none) -> [Int]? {
    WindowListResolver.resolve(windows: list, focused: { focused }, main: { main }, isLive: { $0 > 0 }, same: ==)
}

@Test func windowListIsDedupedAndSkipsAuxiliaryWindows() {
    #expect(resolve(.value([1, 2, 1, -5])) == [1, 2])
    #expect(resolve(.value([-5]), focused: .value(-5), main: .value(-5)) == [])
    #expect(resolve(.none) == [])
}

@Test func emptyWindowListFallsBackToFocusedThenMain() {
    // A window in native full screen on another Space.
    #expect(resolve(.value([]), focused: .value(7)) == [7])
    #expect(resolve(.value([]), focused: .none, main: .value(8)) == [8])
    #expect(resolve(.value([]), focused: .value(-1), main: .value(8)) == [8])
    // The fallback is only for an empty list.
    #expect(resolve(.value([3]), focused: .value(7)) == [3])
}

@Test func failedReadsAreUnknownNotEmpty() {
    #expect(resolve(.failed, focused: .value(7)) == nil)
    #expect(resolve(.value([]), focused: .failed, main: .none) == nil)
    // A fallback that does find a window wins over another that failed.
    #expect(resolve(.value([]), focused: .failed, main: .value(8)) == [8])
}

// S-021
@Test func windowsOnASecondScreenFitAboveThatScreensBar() {
    // A 1920 by 1080 screen to the right of a 1440 wide main screen, its bar top at 1040.
    let low = CGRect(x: 1600, y: 700, width: 800, height: 380)
    #expect(WorkArea.fit(low, top: 25, bottom: 1040, minX: 1440, maxX: 3360) == CGRect(x: 1600, y: 660, width: 800, height: 380))
    // The main screen's area ignores it.
    #expect(WorkArea.fit(low, top: 24, bottom: 860, minX: 0, maxX: 1440) == nil)
}

@Test func snapFramesTileTheAreaWithoutGaps() {
    // A 1440 × 900 screen: 33 pt menu bar, 40 pt Superbar.
    let area = SnapArea.of(screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
                           visible: CGRect(x: 0, y: 33, width: 1440, height: 867), barHeight: 40)
    #expect(area == CGRect(x: 0, y: 33, width: 1440, height: 827))
    #expect(Snap.fill.frame(in: area) == area)
    #expect(Snap.leftHalf.frame(in: area) == CGRect(x: 0, y: 33, width: 720, height: 827))
    #expect(Snap.rightHalf.frame(in: area) == CGRect(x: 720, y: 33, width: 720, height: 827))
    let top = Snap.topHalf.frame(in: area), bottom = Snap.bottomHalf.frame(in: area)
    #expect(top.minY == 33 && top.maxY == bottom.minY && bottom.maxY == 860)
    #expect(Snap.bottomRight.frame(in: area).maxX == 1440 && Snap.bottomRight.frame(in: area).maxY == 860)
    #expect(Snap.topLeft.frame(in: area).union(Snap.bottomRight.frame(in: area)) == area)
    let thirds = [Snap.leftThird, .centerThird, .rightThird].map { $0.frame(in: area) }
    #expect(thirds.map(\.width) == [480, 480, 480])
    #expect(thirds[0].maxX == thirds[1].minX && thirds[1].maxX == thirds[2].minX)
    // Nothing reaches under the bar.
    #expect(Snap.allCases.allSatisfy { $0.frame(in: area).maxY <= 860 })
}

@Test func snapAreaRespectsTheDockAndOtherScreens() {
    // A second screen right of the main one, with the Dock (60 pt) visible at its bottom.
    let screen = CGRect(x: 1440, y: -200, width: 2560, height: 1440)
    let visible = CGRect(x: 1440, y: -175, width: 2560, height: 1355)
    #expect(SnapArea.of(screen: screen, visible: visible, barHeight: 40).maxY == 1180)   // the Dock is taller
    #expect(SnapArea.of(screen: screen, visible: CGRect(x: 1440, y: -175, width: 2560, height: 1415), barHeight: 40).maxY == 1200)
    let thirds = Snap.rightThird.frame(in: SnapArea.of(screen: screen, visible: visible, barHeight: 40))
    #expect(thirds.maxX == 4000)
}

@Test func snapShortcutsAreDistinct() {
    #expect(Set(Snap.allCases.map(\.shortcut)).count == Snap.allCases.count)
    #expect(Snap.leftHalf.shortcut.display == "⌃⌥←")
}
