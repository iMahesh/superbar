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
| Full-screen check | private SkyLight `SLSManagedDisplayGetCurrentSpace` + `SLSSpaceGetType` (4 = full screen) for the main display; fallbacks: AX `AXFullScreen`, then a window covering the whole screen | None (AX fallback: Accessibility) |
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
| Show desktop | private `CoreDockSendNotification("com.apple.showdesktop.awake")`, looked up with `dlsym`; fallback: hide all other apps with `NSRunningApplication.hide()` | None |
| Volume | CoreAudio `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` on the default output, with a property listener | None |
| Network | `NWPathMonitor` (connected, Wi-Fi or wired, offline) | None |
| Battery | IOKit `IOPSCopyPowerSourcesInfo`, `IOPSNotificationCreateRunLoopSource` | None |
| Hide the macOS Dock | `defaults write com.apple.dock autohide -bool true` and `autohide-delay -float 1000`, then `killall Dock`; restore the saved values on "Restore Dock" | None, but ask first |
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

- **Order.** Pinned apps first, in the saved order. Running apps that are not pinned follow, in launch order. A pinned app that launches stays in its pinned slot. Finder is always first and cannot be unpinned.
- **Click a button.** Not running: launch it. Running, not active: bring its last-used window to the front (or unhide it, or restore its most recent minimized window if it has no visible one). Active with one window: minimize that window. Active with two or more windows: show the preview popover so the user picks one. Running with no windows (Finder with none open, an app left open with its last window closed): activate it, then for Finder open a new window.
- **Middle click or ⇧click.** Open a new window or instance: `openApplication` with `createsNewApplicationInstance = false` and send ⌘N to the app after it activates.
- **Right click.** A menu: the app's windows by title, then "Open new window", "Pin to taskbar" or "Unpin from taskbar", "Close window" (one window) or "Close all windows" (several), and "Quit". A right click on empty bar space shows "Taskbar settings…" and "Quit Superbar".
- **Drag to reorder.** Drag a pinned button along the bar to move it. Drag a running, unpinned app into the pinned area to pin it. Dragging out of the bar does nothing in version one.
- **Hover.** After 400 ms on a running app, show `PreviewPopover` above the button. Each thumbnail has the window title and a close (×) button that appears on hover. Click a thumbnail to focus that window. The popover stays while the pointer is over the button or the popover, and closes 300 ms after it leaves both. Moving to the next button switches popovers at once, no new delay.
- **Glow color.** Average the icon's pixels at 16 by 16, skip near-transparent and near-gray pixels, and boost saturation. Cache per bundle ID. Fallback: system accent color.
- **Start menu.** Opens from the orb or ⌃⎋, focused on the search field (this panel is the one that becomes key). Typing filters apps by name with prefix matches first, then word starts, then contains; Return opens the top hit. Esc, a click outside, or ⌃⎋ again closes it. Shows up to 12 pinned apps (Start pins are separate from taskbar pins) and up to 10 recent apps.
- **Power button.** "Shut down" by default; its arrow opens Sleep, Restart, Log out, Lock. Restart, shut down, and log out ask the system the normal way, so unsaved documents still get their prompt.
- **Clock.** Time over the short date, updated at the start of each minute (not on a 1 s timer). Click shows a month calendar in a popover.
- **Show desktop.** Click the strip at the far right to show the desktop; click again to bring the windows back.
- **The bar and other windows.** macOS has no public API to reserve screen space, so zoomed and "Fill" windows reach the bottom of the screen and slide under the bar. Version one draws the bar above them and says so in Settings. With "Hide the macOS Dock" on, nothing else uses the bottom edge.
- **Full screen.** While the main display shows a full-screen Space, the bar hides. Resting the pointer on the bottom edge for 0.2 s slides it up over the app, like the Dock; it slides away 0.6 s after the pointer leaves it. It stays up while the Start menu, a preview, the calendar, or a menu is open, and ⌃⎋ shows it with the Start menu. Checked on every Space change and app switch, again 0.7 s later, and every 2 s. The Start menu, previews, and calendar also join full-screen Spaces (`fullScreenAuxiliary`).
- **Prewarm.** 2 s after launch, build the Start menu panel and the preview popover and index apps, so the first open is instant.

## Gotchas

- There is no public way to reserve the bottom of the screen like Windows does. `NSScreen.visibleFrame` only leaves room for the Dock and the menu bar. Draw the bar above windows and offer to hide the Dock. Nudging every window up with AX observers is a version two idea.
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

Done when the bar shows pinned and running apps at the bottom of the main screen, clicking switches and minimizes the way Windows 7 does, hovering shows a preview of each window, and the Start menu opens apps and can restart the Mac.
