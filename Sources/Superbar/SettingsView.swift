import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI
import SuperbarKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, permissions
    var id: String { rawValue }
    var title: String { self == .general ? "General" : "Permissions" }
    var symbol: String { self == .general ? "gearshape" : "lock.shield" }
}

@Observable
final class SettingsState {
    var tab: SettingsTab = .general
    /// The window's state, for its button on the bar (TaskbarModel).
    var isOpen = false
    var isMinimized = false
    var windowNumber = 0
}

/// The Settings window, made by hand: an accessory app has no Settings scene to open.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let state: SettingsState
    private var window: NSWindow?
    private let content: () -> AnyView

    init(state: SettingsState, content: @escaping () -> AnyView) {
        self.state = state
        self.content = content
    }

    var settingsWindow: NSWindow? { window }

    /// While Settings is open Superbar is a regular app, so macOS lets it come to the
    /// front (an accessory app's activate() is often refused, leaving the window behind
    /// other apps), and the window can be minimized and switched to like any app's.
    func show(tab: SettingsTab? = nil) {
        if let tab { state.tab = tab }
        let window = self.window ?? make()
        self.window = window
        Permissions.shared.settingsVisible = true
        Permissions.shared.refresh()
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Ask the window server too: activate() alone is only a request.
        _ = Private.bringToFront(pid: getpid(), windowID: CGWindowID(window.windowNumber))
        state.isOpen = true
        state.isMinimized = false
        state.windowNumber = window.windowNumber
    }

    /// Is it the window in front, in the active app?
    var isFrontmost: Bool { NSApp.isActive && window?.isKeyWindow == true && window?.isMiniaturized == false }

    func minimize() { window?.miniaturize(nil) }

    func close() { window?.performClose(nil) }

    /// A click on its bar button, like any app's: front it, or minimize it when it is in front.
    func toggleFromBar() {
        isFrontmost ? minimize() : show()
    }

    private func make() -> NSWindow {
        let host = NSHostingController(rootView: content())
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = "Superbar Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        Permissions.shared.settingsVisible = false
        state.isOpen = false
        state.isMinimized = false
        // Back to a bar-only app: no Dock icon, no menu bar.
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidMiniaturize(_ notification: Notification) { state.isMinimized = true }
    func windowDidDeminiaturize(_ notification: Notification) { state.isMinimized = false }
    func windowDidBecomeKey(_ notification: Notification) { state.isMinimized = false }
}

struct SettingsView: View {
    @Bindable var state: SettingsState
    let settings: AppSettings
    let dock: DockController
    let permissions: Permissions

    var body: some View {
        TabView(selection: $state.tab) {
            GeneralSettings(settings: settings, dock: dock)
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)
            PermissionsSettings(permissions: permissions)
                .tabItem { Label(SettingsTab.permissions.title, systemImage: SettingsTab.permissions.symbol) }
                .tag(SettingsTab.permissions)
        }
        .frame(width: 520)
        .noInitialFocus()
    }
}

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let dock: DockController
    private let hotkeys = HotkeyCenter.shared

    private var visibilityNote: String {
        switch settings.barVisibility {
        case .alwaysShow: "The bar stays up. It still hides over full-screen apps until you point at the bottom edge."
        case .autoHide: "The bar hides when the pointer leaves it. Rest the pointer on the bottom edge to bring it back. Windows can use the whole screen."
        case .alwaysHide: "The bar stays out of sight. Press the Start shortcut to bring it up with the Start menu. Windows can use the whole screen."
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: Space.md) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Superbar").font(.title3.weight(.semibold))
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Layout") {
                Picker("Size", selection: $settings.barSize) {
                    ForEach(BarSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Visibility", selection: $settings.barVisibility) {
                    ForEach(BarVisibility.allCases) { Text($0.title).tag($0) }
                }
                if settings.barVisibility != .alwaysShow {
                    Stepper(value: $settings.autoHideDelay, in: 0...10, step: 0.5) {
                        LabeledContent("Hide after", value: "\(settings.autoHideDelay.formatted(.number.precision(.fractionLength(1)))) s")
                    }
                }
                Text(visibilityNote)
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Combine buttons and hide labels", isOn: .constant(true))
                    .disabled(true)
                Text("Superbar always groups an app's windows on one button.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep windows above Superbar", isOn: $settings.keepWindowsAbove)
                Toggle("Hide the macOS Dock", isOn: Binding(
                    get: { dock.isHidden },
                    set: { $0 ? dock.requestHide() : dock.restore() }))
                if dock.isHidden {
                    Button("Restore Dock") { dock.restore() }
                }
            } header: {
                Text("Windows and Dock")
            } footer: {
                Text("macOS can't reserve the bottom of the screen, so Superbar moves or trims windows that reach under it, like zoomed windows. This needs Accessibility. Hiding the Dock keeps the bottom edge for Superbar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(TrayIcon.allCases) { icon in
                    Toggle(icon.title, isOn: Binding(get: { settings.shows(icon) }, set: { settings.setShows(icon, $0) }))
                }
            } header: {
                Text("System tray")
            } footer: {
                Text("The icons left of the clock. The clock always shows. Battery appears only on a Mac with a battery.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Snap shortcuts", isOn: $settings.snapShortcuts)
                if settings.snapShortcuts {
                    ForEach(Snap.allCases) { snap in
                        LabeledContent(snap.title) {
                            HStack(spacing: Space.xs) {
                                if hotkeys.snapFailures.contains(snap) {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                        .help("Another app uses this shortcut")
                                }
                                Text(snap.shortcut.display).monospaced()
                            }
                        }
                    }
                }
            } header: {
                Text("Window snapping")
            } footer: {
                Text("Snaps the front window. Right-click an app's button for the same choices under Snap Window. Snapped windows stay above Superbar while it's set to Always show. Needs Accessibility.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Start menu") {
                LabeledContent("Shortcut") {
                    ShortcutRecorder(combo: $settings.startHotkey)
                }
                if hotkeys.failed {
                    Label("Another app uses this shortcut. Pick a different one.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Startup") {
                Toggle("Open Superbar at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Clock") {
                Text("The clock follows your Mac's 12 or 24 hour setting in System Settings > General > Date & Time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fitsContent()
    }
}

struct PermissionsSettings: View {
    let permissions: Permissions

    var body: some View {
        Form {
            Section {
                PermissionRow(name: "Accessibility", isOn: permissions.accessibility,
                              detail: "Without it, Superbar can't list, focus, minimize, or close windows, or keep them out from under the bar.",
                              grant: permissions.grantAccessibility)
                PermissionRow(name: "Screen Recording", isOn: permissions.screenRecording,
                              detail: "Without it, previews show the app icon and some window titles are missing.",
                              grant: permissions.grantScreenRecording)
                PermissionRow(name: "Automation of System Events", isOn: permissions.automation == .on,
                              detail: "Without it, Restart, Shut Down, and Log Out in the Start menu don't work.",
                              grant: permissions.grantAutomation)
            } footer: {
                Text("Each row turns On within a few seconds of a grant. No restart needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fitsContent()
    }
}

private struct PermissionRow: View {
    let name: String
    let isOn: Bool
    let detail: String
    let grant: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.sm) {
                    Text(name)
                    Text(isOn ? "On" : "Off")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(isOn ? Color.green.opacity(0.2) : Color.orange.opacity(0.2)))
                        .foregroundStyle(isOn ? .green : .orange)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isOn {
                Button("Grant…", action: grant)
            }
        }
    }
}

/// Click, then press the new shortcut. Esc cancels.
private struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press a shortcut…" : combo.display) {
            recording ? stop() : start()
        }
        .frame(minWidth: 120)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotkeyCenter.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    stop()
                    return nil
                }
                let flags = event.modifierFlags
                var mods: UInt32 = 0
                if flags.contains(.control) { mods |= KeyCombo.control }
                if flags.contains(.option) { mods |= KeyCombo.option }
                if flags.contains(.shift) { mods |= KeyCombo.shift }
                if flags.contains(.command) { mods |= KeyCombo.command }
                guard mods != 0 else { NSSound.beep(); return nil }
                combo = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods)
                stop()
                return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotkeyCenter.shared.register(combo) }
        recording = false
    }
}
