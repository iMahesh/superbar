# Superbar

A Windows 7 style taskbar for the Mac: a glass bar along the bottom of the main
screen with a Start orb, one button per app, hover previews, a tray, and a clock.
An accessory app (LSUIElement, no Dock icon). Data lives in UserDefaults; no server.

The brief is `docs/BRIEF.md`, the stories `docs/STORIES.md`, and the APIs,
behaviors, and gotchas `docs/SPEC.md`. Read SPEC.md before changing behavior.

## Layout

- `Sources/SuperbarKit/` rules with no AppKit: click resolver, pin order, search ranking, clock tick, glow color, Dock save/restore, key combos. Tests in `Tests/SuperbarKitTests/`.
- `Sources/Superbar/App.swift` the app delegate: builds the bar, wires the panels, the hotkey, and permissions.
- `Sources/Superbar/Model/` `TaskbarModel` (apps, clicks, pins, drag, menus), `TrayModel`, `AppSettings`.
- `Sources/Superbar/Windows/` AX window list and observers, window actions, ScreenCaptureKit thumbnails, icon and glow cache.
- `Sources/Superbar/System/` private calls (SkyLight, `_AXUIElementGetWindow`, CoreDock) looked up with dlsym, permissions, Carbon hotkey, power actions, Dock preferences, `Store` (UserDefaults).
- `Sources/Superbar/UI/` panels (`GlassPanel`, `MouseCatcher`), the bar, Start menu, preview popover, calendar.
- `build.sh` builds, signs, and installs `~/Applications/Superbar.app`.

## Build and check

- Build and install: `./build.sh`. `--open` restarts the app with the new build. Fix every warning except the `ld: warning: search path ... not found` lines, which come from the Command Line Tools.
- `tools/sdk.sh` (sourced by build.sh and tools/test.sh): with only the Command Line Tools, builds use the newest macOS 26.x SDK, because the 27.x SDK makes SwiftUI's `@State` a macro whose plugin only Xcode ships. For a bare `swift build`, run `source tools/sdk.sh` first.
- Unit tests: `tools/test.sh` (adds the Testing macro plugin path the Command Line Tools leave out).
- Self-test (real app functions on a test UserDefaults suite): `tools/selftest.sh`. Exit 0 when every check passes. Add a check for every story with logic in `SelfTest.swift`.
- Snapshots: `tools/snap.sh` writes `/tmp/Superbar-shots/<page>-light.png` and `-dark.png` for the bar (normal, small, hover glows), Start menu, preview, calendar, and Settings tabs, then quits. `APP_SNAPSHOT_PAGES=bar,start tools/snap.sh` limits the pages. Without Screen Recording for the launching app the glass is blank in the PNGs.
- Grid: `tools/grid-lint.sh` prints PASS. Silence a line with `// grid: ok <why>`.
- Snapshots and the self-test refuse to run without `APP_STORE`; they use the `com.maheshporeddy.superbar.test` suite, never the real pins, and never touch the real Dock.
- A change is done when the build has no errors, the tests, self-test, and grid lint pass, and you looked at the light and dark snapshots.

## Rules

- The look is Aero-style glass, not Liquid Glass: `GlassPanel` (HUD blur), `Glass.tint`, `Glass.highlight`. Spacing from `Space` in `UI/Grid.swift`.
- Never use Microsoft's name, logo, or sounds. The orb glyph (`Spark`) is original.
- AX and SkyLight calls run off the main thread (`@concurrent` in `WindowActions`, `AXReader`, `AXObserverHost`). Never call AX on the main actor.
- The bar and popovers never become key. Only the Start panel does.
- Never change the Dock's defaults without the confirmation in `DockController.requestHide()`.
- Ad hoc builds lose Accessibility and Screen Recording grants on every rebuild. Sign with an Apple Development certificate to keep them.

## Git

- Commit after each working change, with a message that says what the user can now do.
