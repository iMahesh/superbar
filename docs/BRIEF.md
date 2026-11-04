# Superbar

A taskbar for the Mac that works like the one in Windows 7: Start, app buttons, previews, clock.

## Replaces
The Dock, for people who think in taskbars. Also uBar.

## Main jobs
1. See every running app and pinned app as a button along the bottom; click to switch,
   click the active one to minimize it, click a grouped app to pick one of its windows.
2. Hover a button to see live previews of that app's windows, and close one from there.
3. Press the Start button (or ⌃⎋) to search and open apps, reach common folders, and
   sleep, restart, or shut down. The button next to it opens Mission Control.
4. Read the time and date, volume, network, and battery at a glance on the right, and click
   each to change it: Wi-Fi on or off, volume and mute, battery details.

## Data
- Pinned apps: ordered list of bundle IDs. UserDefaults.
- Settings: height (small 30 pt / normal 40 pt, default normal), labels (always combine and
  hide labels, default on), hide the macOS Dock (default off), Start hotkey (default ⌃⎋),
  clock format (follows system). UserDefaults.
- Recent apps for the Start menu: last 10 bundle IDs opened from Superbar. UserDefaults.
- Preview cache: window ID to image. Memory only.

## Shape
A borderless, non-activating panel docked to the bottom of every connected screen, full width,
above normal windows. A Start menu panel and preview popovers that open from it. A
Settings window. macOS 26 or later. No Dock icon (LSUIElement). Local data. Works
offline. No accounts.

## System hooks
Accessibility (list, focus, minimize, close windows), Screen Recording (previews and
window titles), global hotkey (Carbon ⌃⎋), NSWorkspace launch/quit/activate
notifications, Automation of System Events (restart, shut down, log out), launch at login.

## Reference
Windows 7 taskbar (the "Superbar"), uBar.

## Look
Aero-style glass, not Liquid Glass: a dark translucent bar (NSVisualEffectView, .hudWindow,
plus a 30% #1C2B3A tint and a 1 pt white 25% top highlight). App buttons 56 by 40 pt,
icon 32 pt. Running apps get a soft raised frame; the active app a brighter one. On hover
the button glows in the icon's main color. Start orb 40 pt, round, blue glossy gradient,
original glyph. Clock shows time over date in two lines. A 10 pt "show desktop" strip at
the far right edge.

## Not in version one
- Jump Lists with an app's recent documents
- Aero Peek (fade all windows to glass on hover)
- Aero Snap and Aero Shake (see window-snapper.md)
- Taskbar on the top, left, or right edge
- Dock badges and progress bars on buttons
- Uncombined buttons with window titles as labels
