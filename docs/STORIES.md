Status key: `built` means the code is in and every [unit] and [snap] line passes
(tools/test.sh, tools/selftest.sh, tools/snap.sh). A story becomes `done` once its
[manual] lines are tried by hand with Accessibility and Screen Recording granted.

## M1 Core loop

### S-001 Show the taskbar
As the user, I launch Superbar and a glass bar sits along the bottom of each screen
with the Start orb, my running apps, and the clock.
Screens: taskbar.png
Acceptance:
- [snap] The bar is full width, 40 pt tall, with the orb on the left and the clock on the right, in light and dark mode.
- [unit] The app list holds only apps with activationPolicy .regular, Finder first.
- [manual] The bar stays put when switching Spaces; in a full-screen app it hides until the pointer rests on the bottom edge (S-017).
Status: built

### S-002 Track running apps
As the user, I open and quit apps and the bar updates right away.
Depends: S-001
Acceptance:
- [manual] A launched app gets a button within half a second; a quit app's button goes away (or goes back to plain if pinned).
- [snap] The active app's button has the bright frame, other running apps the soft frame, pinned-only apps none.
Status: built

### S-003 Click to switch and minimize
As the user, I click a button to bring that app forward, and click the active one again to minimize it.
Depends: S-002
Acceptance:
- [manual] Clicking a background app brings its last window to the front with keyboard focus.
- [manual] Clicking the active app with one window minimizes it; clicking again restores it.
- [manual] Clicking an app whose only window is minimized restores that window.
- [unit] The click resolver returns launch / focus / minimize / pick / reopen for each state in the Behaviors list.
Status: built

### S-004 Pin and unpin apps
As the user, I right-click a button and choose "Pin to taskbar", and the app stays on the bar after it quits.
Depends: S-002
Acceptance:
- [unit] Pinning and unpinning keep the saved order; Finder cannot be unpinned.
- [manual] Pins survive a relaunch of Superbar.
- [manual] Dragging a pinned button moves it, and the new order is saved.
Status: built

### S-005 Open apps from Start
As the user, I click the orb or press ⌃⎋, type part of an app's name, and press Return to open it.
Screens: start-menu.png
Acceptance:
- [snap] The menu shows pinned and recent apps on the left, places on the right, and the search field focused.
- [unit] "saf" ranks Safari above anything that only contains "saf".
- [manual] Esc, a click outside, or ⌃⎋ again closes the menu.
Status: built

### S-006 Shut down, restart, sleep from Start
As the user, I use the power button in the Start menu.
Depends: S-005
Acceptance:
- [manual] Sleep puts the Mac to sleep with no prompt.
- [manual] Restart with an unsaved TextEdit document shows the usual save prompt.
- [snap] Settings shows the Automation permission row with a Grant button when it is off.
Status: built

### S-007 Clock
As the user, I read the time and date on the right and click it to see a calendar.
Acceptance:
- [snap] Two lines, time over date, in the system's 12 or 24 hour format.
- [unit] The next tick is scheduled for the start of the next minute.
Status: built

### S-008 Grant Accessibility and Screen Recording
As the user, I open Superbar the first time and Settings shows each permission with a Grant button.
Screens: settings-permissions.png
Acceptance:
- [snap] Each row shows On or Off, one line on what breaks without it, and a Grant button.
- [manual] Within 2 seconds of a grant, the row shows On and minimize works without a restart.
- [manual] Settings opens by itself at launch while Accessibility is off.
Status: built

### S-017 Taskbar over full-screen apps
As the user, I move the pointer to the bottom edge in a full-screen app and the bar slides up, so I can switch apps without leaving full screen.
Depends: S-001
Acceptance:
- [unit] EdgeReveal shows after a 0.2 s rest on the edge, ignores a quick pass, holds while a menu is open, and hides 0.6 s after the pointer leaves.
- [self-test] In full screen the bar hides, slides up from the edge, hides again, stays up with the Start menu open, and comes back when full screen ends.
- [manual] Verified with a real full-screen window on 2026-11-04: hidden, a 0.1 s touch does nothing, a rest shows it over the app at the status-bar level, moving away hides it, it returns after full screen ends.
- [manual] ⌃⎋ in a full-screen app opens the Start menu with the bar under it.
Status: built

## M2 Windows, previews, and tray

### S-009 Hover for previews
As the user, I hover a running app's button and see a live picture of each of its windows.
Depends: S-003
Screens: preview-popover.png
Acceptance:
- [manual] The popover shows after about 400 ms and switches at once when I move to the next button.
- [manual] Clicking a thumbnail focuses that window, including the second window of the same app.
- [snap] Without Screen Recording, thumbnails show the big app icon and the AX title.
Status: built

### S-010 Close a window from its preview
As the user, I hover a thumbnail and click its × to close that window.
Depends: S-009
Acceptance:
- [manual] The window closes the normal way (an unsaved document still asks) and the thumbnail goes away.
Status: built

### S-011 Pick a window of a grouped app
As the user, I click the active app's button when it has several windows and pick one.
Depends: S-009
Acceptance:
- [manual] The preview popover opens on click with no hover delay.
- [unit] An app with minimized windows lists them after visible ones.
Status: built

### S-012 Hover glow
As the user, I hover a button and it glows in the color of its icon.
Depends: S-001
Acceptance:
- [unit] The color for a mostly blue icon is blue, and an all-gray icon falls back to the accent color.
- [snap] Hovered state for three different icons.
Status: built

### S-013 Tray: volume, network, battery
As the user, I see volume, network, and battery icons left of the clock.
Screens: tray.png
Acceptance:
- [manual] Changing volume with the keyboard updates the icon within a second.
- [manual] Turning Wi-Fi off shows the offline icon.
- [snap] A Mac with no battery shows no battery icon.
- [self-test] Each tray icon is its own clickable view and opens its popover; a second click closes it. The volume slider sets the volume.
- [snap] tray-network, tray-sound, and tray-battery popovers.
- [manual] Dragging the slider changes the volume; the Wi-Fi switch turns Wi-Fi off and on.
Status: built

### S-014 Show desktop
As the user, I click the strip at the far right edge to see the desktop, and click again to get my windows back.
Acceptance:
- [manual] One click shows the desktop; a second click restores the same windows.
Status: built

### S-015 Hide the macOS Dock
As the user, I turn on "Hide the macOS Dock" in Settings so only Superbar is at the bottom.
Screens: settings-general.png
Acceptance:
- [manual] Turning it on asks first, then the Dock no longer appears at the bottom edge.
- [manual] "Restore Dock" and turning it off put back the exact settings I had before.
- [unit] DockControl saves the old autohide and autohide-delay values before it changes them.
Status: built

### S-016 Launch at login and small size
As the user, I set Superbar to start with my Mac and pick the small 30 pt size.
Acceptance:
- [manual] After logging out and in, the bar is there.
- [snap] Small size with 24 pt icons.
Status: built

### S-021 A bar on every display
As the user with a second display connected, each display has its own Superbar along its bottom, with the same apps.
Depends: S-001, S-017, S-019, S-020
Acceptance:
- [self-test] One bar per connected display, each spanning the bottom of its display.
- [unit] WorkArea keeps a window on a second screen above that screen's bar, and the main screen's area leaves it alone.
- [manual] Verified 2026-11-04 with the built-in display and an LG UltraFine: two bars (1440 and 1920 pt wide) listing the same apps and window counts in the same order.
- [manual] Start opens on the display whose orb was clicked (verified on both). A hover preview on the LG bar opens centered over its button (verified). Not yet tried: the calendar and tray popovers on the LG.
- [manual] A full-screen app on one display hides only that display's bar. Verified on the LG: its bar hid, the main bar stayed and listed the app, and the LG bar came back when the app quit.
- [manual] A window under the LG's bar moves up to end above it. Verified: bottom 0 to 40 pt, height unchanged.
- [manual] Unplugging a display removes its bar; plugging it in adds one.
Status: built

### S-020 Which apps get a button
As the user, the bar shows my pinned apps always and other apps only while they have a window, so apps with nothing open don't clutter it.
Depends: S-001, S-003
Acceptance:
- [unit] AppVisibility: pinned apps always show; unpinned running apps show only with a live window, and stay while their windows are unknown. WindowListResolver dedupes, skips auxiliary windows, falls back to the focused then the main window when the list is empty, and treats a failed read as unknown.
- [manual] Verified 2026-11-04 through the bar's own accessibility tree, with a test app:
  - unpinned with a window: shown, "1 window"; its last window closed: gone at once.
  - unpinned, only window minimized: shown, "1 window".
  - unpinned, only window in native full screen, after switching back to the desktop Space: shown, "1 window" (kAXWindowsAttribute was empty; the focused-window fallback found it). Auto-hide still hid the bar on the full-screen Space and brought it back on the desktop.
  - a window plus a floating panel: "1 window".
  - pinned: "1 window", then "0 windows" after its last window closed, then "Not running" after it quit, and after Superbar restarted.
  - Accessibility off: unpinned running apps keep their buttons ("Running").
- [snap] Only an app with a window (or a running app whose windows are unknown) gets the raised button frame; a running app with no window, like Finder with only the desktop, looks like a plain pin.
- Multiple displays: see S-021.
Status: built

### S-019 Keep windows above Superbar
As the user, my windows end at the top of Superbar, so nothing at the bottom of an app (like Google Sheets' sheet tabs) hides behind it.
Depends: S-001, S-008
Acceptance:
- [unit] WorkArea moves a window with room above up unchanged, trims a zoomed window to end at the bar, and leaves windows that fit, sit on other screens, or would get too short alone.
- [manual] A window whose bottom is under the bar moves up within 2 s of opening, and a zoomed browser window ends at the bar. Verified 2026-11-04 with test windows: a 400 pt window moved up to end at the bar; a full-height window kept its top and was trimmed from 869 to 829 pt.
- [manual] Dragging a window partly under the bar is not fought; resizing it under the bar is. Verified 2026-11-04 for a plain move: the window stayed where it was put.
- [manual] Turning off "Keep windows above Superbar" stops it.
Status: built

### S-018 Mission Control from the bar
As the user, I click the button right after the Start orb and Mission Control opens.
Depends: S-001
Acceptance:
- [self-test] A click there reaches the Mission Control button, the first app button still gets its own clicks, and Mission Control's app exists.
- [snap] The button sits between the orb and the first app, on the normal and the small bar.
- [manual] One click opens Mission Control; Esc or a second click closes it.
Status: built

## Dropped
- Jump Lists with recent documents per app
- Aero Peek
- Taskbar on other edges
- Uncombined buttons with labels
- Badges and progress from the Dock
