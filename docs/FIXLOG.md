# Fix log

## Start menu opened without focus in the search field
- Symptom: the Start menu opened and took keys, but typing went nowhere. Seen once in the self-test, on the first run after a fresh install.
- Cause: on the first open the search field is created during SwiftUI layout, after `open()` returned, so `makeFirstResponder` had no field. One async retry was sometimes still too early on a cold launch.
- Fix: retry focusing every 50 ms until the field has an editor, up to 0.5 s. The self-test checks "typing goes to the search field".
- Rule: never assume an NSViewRepresentable's view exists right after its panel is ordered front; retry until it does, and test it.

## Start menu could stay open after a click in another app
- Symptom: closing on an outside click relied only on the panel losing key, which a non-activating panel does not always do.
- Fix: a global mouse-down monitor closes the menu while it is open, as the calendar does.
- Rule: every transient panel closes on a global mouse-down monitor, not on resignKey alone.

## The bar and popovers sat at the floating level, not the status-bar level
- Symptom: the window server listed the bar at layer 3 instead of 25, so it was lower than intended.
- Cause: `GlassPanel` set `level`, then `isFloatingPanel = true`, which resets the level to `.floating`.
- Fix: set `isFloatingPanel` first. The self-test checks `bar.level == .statusBar`.
- Rule: set `isFloatingPanel` before `level`, and check the level the window server reports.

## Full screen not detected without Accessibility
- Symptom: with a real full-screen window, the bar stayed up.
- Cause: the fallback looked for a window covering the whole screen, but this Mac's full-screen windows start 30 pt down, the same bounds as a zoomed window. The ad hoc build had no Accessibility, so the AXFullScreen check could not run.
- Fix: ask SkyLight for the main display's Space type (4 = full screen) first; AX and bounds are fallbacks.
- Rule: detect full screen from the Space, never from window bounds alone.

## Superbar crashed when its own Settings window came to the front (2026-11-04)
- Symptom: with Accessibility granted and Settings open, Superbar quit with SIGTRAP in `NSWMWindowCoordinator` under `FitWorker.fitNow`.
- Cause: activating Superbar (opening Settings) sent `didActivateApplication` for its own pid, so WindowFitter scanned and resized Superbar's own window through AX on a background thread. AppKit traps on that.
- Fix: WindowFitter skips Superbar's own pid in `scan(pid:)` and `windowChanged`.

## Settings sometimes opened behind other apps (2026-11-04)
- Symptom: "Superbar Settings…" from the bar menu sometimes left the window behind the app in front, so it looked like nothing happened.
- Cause: Superbar is an accessory app (no Dock icon). Since macOS 14 `NSApp.activate()` is only a request, and for an accessory app started from a non-activating panel it is often refused.
- Fix: while Settings is open Superbar becomes a regular app (`setActivationPolicy(.regular)`), and `show()` also asks the window server to front the window (`Private.bringToFront`). It goes back to accessory when Settings closes.
