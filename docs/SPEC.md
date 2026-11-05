# Superbar spec

A Windows 7 style taskbar along the bottom of the screen: a Start button, one button per app,
window previews on hover, and a clock and tray on the right. For people who moved from Windows
to the Mac and miss the taskbar. Replaces: the Dock (for these users), uBar, Taskbar.

Keep Microsoft's name and logo out of the app: the Start button is an original glossy orb, not
the Windows flag.

The brief is in [BRIEF.md](BRIEF.md) and the stories in [STORIES.md](STORIES.md).

## How it works

| Part | API | Permission |
| --- | --- | --- |
| The bar | `NSPanel` with `[.borderless, .nonactivatingPanel]`, level `.statusBar` (set after `isFloatingPanel`, which resets the level), `collectionBehavior` `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]` | None |
| Full-screen check | private SkyLight `SLSManagedDisplayGetCurrentSpace` + `SLSSpaceGetType` (4 = full screen) for each display; fallbacks: AX `AXFullScreen`, then a window covering the whole screen | None (AX fallback: Accessibility) |
| Running apps | `NSWorkspace.shared.runningApplications` filtered to `.regular`, plus `didLaunch`, `didTerminate`, `didActivate`, `didHide`, `didUnhide` notifications | None |
| Windows per app | AX `kAXWindowsAttribute` on `AXUIElementCreateApplication(pid)` (includes minimized), matched to `CGWindowListCopyWindowInfo` IDs with private `_AXUIElementGetWindow` | Accessibility |
| Window titles | AX `kAXTitleAttribute` first, `kCGWindowName` second | Accessibility; Screen Recording for the CG name |
| Focus one window | as in window-switcher.md: SkyLight `_SLPSSetFrontProcessWithOptions`, then AX `kAXRaiseAction` and `kAXMainAttribute` | Accessibility |
| Minimize / restore | AX `kAXMinimizedAttribute` set true / false | Accessibility |
| Close a window | AX `kAXCloseButtonAttribute`, then `kAXPressAction` | Accessibility |
| Previews | `SCScreenshotManager.captureImage` with `SCContentFilter(desktopIndependentWindow:)` | Screen Recording |
| Launch an app | `NSWorkspace.shared.openApplication(at:configuration:)` | None |
| Find apps for Start search | `NSMetadataQuery` for `kMDItemContentType == "com.apple.application-bundle"` in /Applications, /System/Applications, ~/Applications | None |
| Start hotkey ⌃⎋ | Carbon `RegisterEventHotKey` | None |
| Sleep | `pmset sleepnow` via `Process`, or IOKit `IOPMSleepSystem` | None |
| Restart, shut down, log out | `NSAppleScript`: `tell application "System Events" to restart` (and `shut down`, `log out`) | Automation of System Events |
| Lock | ⌃⌘Q posted with `CGEvent` | Accessibility |
| Mission Control | `NSWorkspace.openApplication` on /System/Applications/Mission Control.app, as the Dock does; fallback `CoreDockSendNotification("com.apple.expose.awake")` | None |
| Show desktop | private `CoreDockSendNotification("com.apple.showdesktop.awake")`, looked up with `dlsym`; fallback: hide all other apps with `NSRunningApplication.hide()` | None |
| Volume | CoreAudio `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` on the default output, with a property listener; the Sound popover sets it and `kAudioDevicePropertyMute` | None |
| Wi-Fi on/off | CoreWLAN `CWWiFiClient.shared().interface()`, `powerOn()`, `setPower(_:)`; `ssid()` is nil without Location access | None |
| App icon | `AppIconArt` (SwiftUI) rendered by `Superbar --render-icon`, packed with `iconutil` into `Resources/AppIcon.icns` when Xcode's actool is missing; `Icon/AppIcon.icon` for Xcode builds | None |
| Network | `NWPathMonitor` (connected, Wi-Fi or wired, offline) | None |
| Battery | IOKit `IOPSCopyPowerSourcesInfo`, `IOPSNotificationCreateRunLoopSource` | None |
| Hide the macOS Dock | `com.apple.dock`: `autohide` true, `autohide-delay` 1000, `orientation` bottom, `tilesize` 16, `magnification` false, then `killall Dock`; restore the saved values on "Restore Dock" | None, but ask first |
| Launch at login | `SMAppService.mainApp.register()` | None |

Main types:

- `TaskbarApp`: bundle ID, pid (nil when only pinned), name, icon, isPinned, isRunning, isActive, windows, glowColor.
- `AppWindow`: CG window ID, AX element, title, isMinimized.
- `TaskbarModel`: `@Observable`. Merges pinned and running apps into one ordered list; handles click, middle click, pin, unpin, reorder.
- `WindowIndex`: reads each running app's windows through AX, refreshes on AX notifications (`kAXWindowCreatedNotification`, `kAXUIElementDestroyedNotification`, `kAXWindowMiniaturizedNotification`, `kAXWindowDeminiaturizedNotification`, `kAXTitleChangedNotification`) with one `AXObserver` per pid.
- `WindowActions`: focus, minimize, restore, close. Runs on a background queue.
- `TaskbarPanel` / `TaskbarView`: the bar. Start orb, button strip, tray, clock, show-desktop strip.
- `StartMenuPanel` / `StartMenuView`: left column of pinned and recent apps with a search field at the bottom; right column of places (Home, Documents, Downloads, Pictures, Music, Applications, System Settings) and a power button with a menu.
- `PreviewPopover`: a non-activating panel above a button with one thumbnail per window.
- `WindowThumbnails`: as in window-switcher.md.
- `TrayModel`: volume, network, battery, time. `@Observable`.
- `DockControl`: reads, saves, changes, and restores the Dock's autohide settings.
- `HotkeyCenter`, `KeyCombo`, `Permissions`: as in the window snapper spec.
- `BarPresenter` / `FullScreenDetector` / `EdgeReveal`: full-screen check, edge reveal, and the slide.

## Behaviors that matter

- **Which apps.** Pinned apps always have a button, running or not. An unpinned app has one only while it has a live window: ordinary, minimized, or in native full screen. Windows come from `kAXWindowsAttribute`; when that is empty (it lists only the current Space, so a full-screen window drops out after you switch away), from the focused window, then the main window. Standard windows and dialogs count, untitled ones too; panels, the Finder desktop, and windows under 20 pt do not. A failed read keeps the last good list until a read succeeds or the app quits. Without Accessibility, unpinned running apps keep their buttons. The active app, the Space, and full-screen auto-hide never change the list.
- **Order.** Pinned apps first, in the saved order. Running apps that are not pinned follow, in launch order. A pinned app that launches stays in its pinned slot. Finder is always first and cannot be unpinned.
- **Click a button.** Not running: launch it. Running, not active: bring its last-used window to the front (or unhide it, or restore its most recent minimized window if it has no visible one). Active with one window: minimize that window. Active with two or more windows: show the preview popover so the user picks one. Running with no windows (Finder with none open, an app left open with its last window closed): activate it, then for Finder open a new window.
- **Middle click or ⇧click.** Open a new window or instance: `openApplication` with `createsNewApplicationInstance = false` and send ⌘N to the app after it activates.
- **Right click.** A menu: the app's windows by title, then "Open new window", "Pin to taskbar" or "Unpin from taskbar", "Close window" (one window) or "Close all windows" (several), and "Quit". A right click on empty bar space shows "Taskbar settings…" and "Quit Superbar".
- **Drag to reorder.** Drag a pinned button along the bar to move it. Drag a running, unpinned app into the pinned area to pin it. Dragging out of the bar does nothing in version one.
- **Hover.** After 400 ms on a running app, show `PreviewPopover` above the button. Each thumbnail has the window title and a close (×) button that appears on hover. Click a thumbnail to focus that window. The popover stays while the pointer is over the button or the popover, and closes 300 ms after it leaves both. Moving to the next button switches popovers at once, no new delay.
- **Glow color.** Average the icon's pixels at 16 by 16, skip near-transparent and near-gray pixels, and boost saturation. Cache per bundle ID. Fallback: system accent color.
- **Start menu.** Opens from the orb or ⌃⎋, focused on the search field (this panel is the one that becomes key). Typing filters apps by name with prefix matches first, then word starts, then contains; Return opens the top hit. Esc, a click outside, or ⌃⎋ again closes it. Shows up to 12 pinned apps (Start pins are separate from taskbar pins) and up to 10 recent apps.
- **Power button.** "Shut down" by default; its arrow opens Sleep, Restart, Log out, Lock. Restart, shut down, and log out ask the system the normal way, so unsaved documents still get their prompt.
- **Name.** Everything the app shows says "Superbar": "Superbar Settings…", "Pin to Superbar", "Unpin from Superbar". Never "Taskbar" or "Windows".
- **Tray.** Each icon opens a popover above it; a second click, a click elsewhere, or any other bar action closes it. Wi-Fi: on/off switch, connection status, Wi-Fi Settings…. Sound: mute button, volume slider, percent, Sound Settings…. Battery: charge, charging or on battery, time left, Battery Settings…. Network shows Network Settings… on a Mac without Wi-Fi.
- **Clock.** Time over the short date, updated at the start of each minute (not on a 1 s timer). Click shows a month calendar in a popover: the picked day written out at the top; a date field to type a date or step its day, month, or year; a Today button (greyed out while today is showing); month arrows; and a grid with all seven weekday letters, today filled and the picked day ringed. Clicking a day picks it. It opens at today each time, takes typing without taking focus from the front app, and Esc closes it.
- **Tray icons.** Settings > System tray turns Trash, Wi-Fi, Sound, and Battery on or off (all on by default; stored as the hidden ones, so new icons show). The clock always shows.
- **Mission Control.** A button right after the Start orb (40 pt wide, 32 pt on the small bar) opens Mission Control and closes any open popover.
- **Show desktop.** Click the strip at the far right to show the desktop; click again to bring the windows back.
- **The bar and other windows.** macOS has no public API to reserve screen space, so Superbar keeps windows out from under the bar itself (`WindowFitter`, rule in `WorkArea.fit`): a window that reaches under it moves up when there is room above, or else keeps its top under the menu bar and has its bottom trimmed to end at the bar. It runs when a window opens or resizes (AX notifications), when an app launches (0.5 and 1.5 s later) or comes to the front, when the bar size or screens change, and when Accessibility is granted. Moves alone never trigger it, so a window being dragged is not fought. Full-screen and minimized windows, other screens, and windows that would end up under 120 pt are left alone. After 3 changes to one window within 2 s it leaves that window alone for 30 s. "Keep windows above Superbar" in Settings, default on.
- **Trash.** A trash icon just left of the tray icons opens Finder's Trash, as the Dock does: an Apple Event to Finder (`open trash`), which shows what was deleted from every drive, with Empty and Put Back. It needs Automation of Finder, asked once; without it Superbar opens the ~/.Trash folder through Launch Services instead, so it never reads the folder and needs no Full Disk Access. The icon does not show whether the Trash is full, and there is no Empty Trash menu: the first would need Full Disk Access, and emptying deletes for good.
- **Settings window.** Opens in front of other apps. While it is open Superbar is a regular app (Dock icon, menu bar) and the window has its own button at the end of the bar: a click fronts it, or minimizes it when it is in front; its menu has Close Window and Quit Superbar; no hover preview. Closing it removes the button and the Dock icon.
- **Every display.** Each connected display has its own bar along its bottom edge, added and removed as displays come and go. Every bar shows the same apps and window counts from one list. Hover and drag stay on the bar under the pointer. Start and the calendar open on the display under the pointer; previews and tray popovers open above the button that was used. Windows are kept above the bar of the screen holding their middle.
- **Full screen.** While a display shows a full-screen Space, its bar hides; the other bars stay. Resting the pointer on the bottom edge for 0.2 s slides it up over the app, like the Dock; it slides away after the pointer leaves it, once the hide delay from Settings has passed (0.5 s by default). It stays up while the Start menu, a preview, the calendar, or a menu is open, and ⌃⎋ shows it with the Start menu. Checked on every Space change and app switch, again 0.7 s later, and every 2 s. The Start menu, previews, and calendar also join full-screen Spaces (`fullScreenAuxiliary`).
- **Taskbar visibility.** Settings > General > Layout > Taskbar picks Always show (default), Auto-hide, or Always hide, for every bar at once. Auto-hide hides the bar when the pointer leaves it and brings it back when the pointer rests 0.2 s on that display's bottom edge. Always hide ignores the edge; the bar comes up only with the Start menu (⌃⎋) or another popover, and goes again when they close. "Hide after" sets the delay, 0 to 10 s in 0.5 s steps (default 0.5 s), and also applies over full-screen apps. A bar that hides doesn't reserve space: "Keep windows above Superbar" applies only in Always show. Full screen hides the bar in every mode.
- **Window snapping.** A window can fill its screen's free area or snap to a half (left, right, top, bottom), a quarter, or a third (left, center, right). The free area is the screen below the menu bar, beside a visible Dock, and above Superbar while it is set to Always show (with auto-hide or always hide, or over full screen, the bar keeps no space). Shortcuts, all ⌃⌥ (Carbon hotkeys, on by default, can be turned off in Settings > Window snapping; one taken by another app is flagged there): ↩ fill; ← → ↑ ↓ halves; U I J K quarters, laid out like the screen; D F G thirds. They snap the front app's focused window. An app button's menu has Snap Window with the same twelve, which snaps that app's focused window (else its first open one) and brings it forward. Edges are rounded to whole points so neighbours meet exactly. A window whose minimum size is bigger than the cell is kept inside the free area. Native full-screen windows are left alone. Needs Accessibility; without it, Settings opens on Permissions.
- **Hidden Dock.** Only the Dock draws the minimize animation, and no public or private API lets another app pick its target, so minimized windows can't fly to their Superbar button. Hiding the Dock therefore also puts it at the bottom: windows shrink toward the bottom of the screen, into the Dock's (hidden) app icon when "Minimize windows into application icon" is on. Mission Control always shows the Dock, even when hidden; at the bottom with 16 pt icons it measures 30 pt and sits under the 40 pt bar, which stays on top there (window level 25 over the Dock's 20). With the small 30 pt bar about 10 pt of it shows; with auto-hide or always hide the bar is down in Mission Control, so the Dock shows. A Dock hidden by an earlier version is moved once on launch; Restore Dock puts back every original value.
- **Prewarm.** 2 s after launch, build the Start menu panel and the preview popover and index apps, so the first open is instant.

## Gotchas

- There is no public way to reserve the bottom of the screen like Windows does. `NSScreen.visibleFrame` only leaves room for the Dock and the menu bar. Superbar moves windows with AX instead; react to opens and resizes, never to moves, or a dragged window fights back.
- Changing the Dock's defaults outlives the app. Save the old values before writing, offer "Restore Dock" in Settings and in the right-click menu, and never change them without asking. Never touch them silently at launch.
- `kAXWindowsAttribute` is the only list that includes minimized windows; `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` does not. Use AX for the list and CG only to get IDs for previews and focus.
- Minimized windows cannot be captured by ScreenCaptureKit. Keep the last picture taken before it minimized, or show the icon.
- An app that hangs blocks AX calls on it. Set `AXUIElementSetMessagingTimeout` to 1.0 and do AX work off the main thread.
- A full-screen window does not always cover the whole screen: on this Mac it starts 30 pt down, below the menu bar area, exactly like a zoomed window. Bounds cannot tell them apart; ask SkyLight for the Space type.
- `isFloatingPanel = true` resets a panel's level to `.floating`. Set it before `level`.
- `NSRunningApplication.activate()` brings the app, not a specific window. Use the SkyLight focus call for "click a thumbnail".
- "Click the active app to minimize" fights with focus: the bar is a non-activating panel; read `NSWorkspace.frontmostApplication` at mouse-down, not mouse-up.
- A hosting view in a panel that is not key eats the first click. Return true from `acceptsFirstMouse`.
- The Start menu must become key to take typing, but the bar must not. Use two panels; only the Start panel returns true from `canBecomeKey`.
- System Events Automation prompts the first time Superbar asks to restart. If the user says no, show the Settings row with a Grant button instead of failing quietly.
- `NSRunningApplication.icon` is slow per call. Cache icons and glow colors per bundle ID.
- Without Screen Recording, `kCGWindowName` is empty. Use the AX title, then the app name. Never show a blank title.
- The Windows logo, the name "Windows", and Windows sounds are Microsoft's. Draw an original orb and keep them out of the app and its icon.

Done when the bar shows pinned and running apps at the bottom of every screen, clicking switches and minimizes the way Windows 7 does, hovering shows a preview of each window, and the Start menu opens apps and can restart the Mac.
