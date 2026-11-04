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
    var autohide: Bool?
    var autohideDelay: Double?
    var restarts = 0
    init(autohide: Bool?, delay: Double?) { self.autohide = autohide; self.autohideDelay = delay }
    func write(autohide: Bool?, autohideDelay: Double?) { self.autohide = autohide; self.autohideDelay = autohideDelay }
    func restartDock() { restarts += 1 }
}

@Test func dockControlSavesOldValuesFirstAndRestoresThem() {
    let store = UserDefaults(suiteName: "superbar.tests.\(UUID().uuidString)")!
    let dock = FakeDock(autohide: false, delay: nil)
    let control = DockControl(prefs: dock, store: store)
    control.hideDock()
    #expect(control.hasSavedState)
    #expect(control.savedAutohide == false && control.savedDelay == nil)
    #expect(dock.autohide == true && dock.autohideDelay == 1000)
    // Hiding twice must not overwrite the saved originals with our own values.
    control.hideDock()
    #expect(control.savedAutohide == false)
    control.restoreDock()
    #expect(dock.autohide == false && dock.autohideDelay == nil)
    #expect(!control.hasSavedState)
    #expect(dock.restarts == 3)
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
