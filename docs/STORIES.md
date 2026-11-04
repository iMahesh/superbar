## M1 Core loop

### S-001 Show the taskbar
As the user, I launch Superbar and a glass bar sits along the bottom of the main screen
with the Start orb, my running apps, and the clock.
Screens: taskbar.png
Acceptance:
- [snap] The bar is full width, 40 pt tall, with the orb on the left and the clock on the right, in light and dark mode.
- [unit] The app list holds only apps with activationPolicy .regular, Finder first.
- [manual] The bar stays put when switching Spaces and is gone in a full-screen app.
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

## Dropped
- Jump Lists with recent documents per app
- Aero Peek
- Taskbar on other edges and on every screen
- Uncombined buttons with labels
- Badges and progress from the Dock
