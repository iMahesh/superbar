import AppKit
import Observation
import SwiftUI

enum TrayItem: String, CaseIterable, Identifiable {
    case network, sound, battery
    var id: String { rawValue }
}

/// The popovers that open from the tray icons. One at a time; a second click on
/// the same icon, or a click anywhere else, closes it.
@Observable
final class TrayPopoverController {
    private(set) var item: TrayItem?
    @ObservationIgnored private let tray: TrayModel
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var panel: GlassPanel?
    @ObservationIgnored private var monitor: Any?

    init(tray: TrayModel, settings: AppSettings) {
        self.tray = tray
        self.settings = settings
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(_ item: TrayItem, anchor: NSRect) {
        if isOpen && self.item == item { close() } else { open(item, anchor: anchor) }
    }

    func open(_ item: TrayItem, anchor: NSRect) {
        self.item = item
        if item == .network { tray.readWiFi() }
        if item == .battery { tray.readBattery() }
        let size = Self.size(for: item)
        let panel = self.panel ?? GlassPanel(content: TrayPopoverView(controller: self, tray: tray),
                                             size: size, cornerRadius: 8, level: .popUpMenu)
        self.panel = panel
        guard let screen = NSScreen.of(anchor)?.frame else { return }
        let x = min(max(anchor.midX - size.width / 2, screen.minX + Space.xs), screen.maxX - size.width - Space.xs)
        let y = screen.minY + settings.metrics.height + Space.xs
        panel.setFrame(NSRect(x: x.rounded(), y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        if monitor == nil {
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                MainActor.assumeIsolated { [weak self] in self?.close() }
            }
        }
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel?.orderOut(nil)
    }

    static func size(for item: TrayItem) -> NSSize {
        switch item {
        case .network: NSSize(width: 280, height: 136)
        case .sound: NSSize(width: 280, height: 124)
        case .battery: NSSize(width: 280, height: 136)
        }
    }

    /// Opens a System Settings pane, then closes the popover.
    func openSettings(_ pane: String) {
        close()
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}

struct TrayPopoverView: View {
    let controller: TrayPopoverController
    let tray: TrayModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            switch controller.item {
            case .network: NetworkPopover(controller: controller, tray: tray)
            case .sound: SoundPopover(controller: controller, tray: tray)
            case .battery: BatteryPopover(controller: controller, tray: tray)
            case nil: EmptyView()
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Glass.tint)
        .environment(\.colorScheme, .dark)
    }
}

private struct PopoverHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.headline)
    }
}

private struct SettingsLink: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Text(title)
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(hovered ? 0.16 : 0)))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

private struct NetworkPopover: View {
    let controller: TrayPopoverController
    let tray: TrayModel
    @State private var error: String?

    var body: some View {
        if let on = tray.wifiOn {
            Toggle(isOn: Binding(get: { on }, set: { error = tray.setWiFi($0) })) {
                PopoverHeader(title: "Wi-Fi")
            }
            .toggleStyle(.switch)
        } else {
            PopoverHeader(title: "Network")
        }
        Label(tray.networkStatus, systemImage: tray.networkSymbol)
            .foregroundStyle(.secondary)
        if let error {
            Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
        Divider()
        SettingsLink(title: tray.wifiOn == nil ? "Network Settings…" : "Wi-Fi Settings…") {
            controller.openSettings(tray.wifiOn == nil ? "com.apple.Network-Settings.extension" : "com.apple.wifi-settings-extension")
        }
    }
}

private struct SoundPopover: View {
    let controller: TrayPopoverController
    let tray: TrayModel

    var body: some View {
        PopoverHeader(title: "Sound")
        if let volume = tray.volume {
            HStack(spacing: Space.sm) {
                Button { tray.setMuted(!tray.muted) } label: {
                    Image(systemName: tray.volumeSymbol).frame(width: 24)
                }
                .buttonStyle(.plain)
                .help(tray.muted ? "Unmute" : "Mute")
                .accessibilityLabel(tray.muted ? "Unmute" : "Mute")
                Slider(value: Binding(get: { Double(tray.muted ? 0 : volume) },
                                      set: { tray.setVolume(Float($0)) }), in: 0...1)
                    .disabled(!tray.volumeSettable)
                    .accessibilityLabel("Volume")
                Text("\(Int(((tray.muted ? 0 : volume) * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            if !tray.volumeSettable {
                Text("This output's volume can't be changed here.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("No sound output").foregroundStyle(.secondary)
        }
        Divider()
        SettingsLink(title: "Sound Settings…") { controller.openSettings("com.apple.Sound-Settings.extension") }
    }
}

private struct BatteryPopover: View {
    let controller: TrayPopoverController
    let tray: TrayModel

    var body: some View {
        PopoverHeader(title: "Battery")
        if let battery = tray.battery, let symbol = tray.batterySymbol {
            HStack(spacing: Space.sm) {
                Image(systemName: symbol).font(.title2)
                Text("\(battery.percent)%").font(.title2.monospacedDigit())
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(tray.batteryStatus)
                    if let time = tray.batteryTimeText { Text(time).foregroundStyle(.secondary) }
                }
                .font(.caption)
            }
        }
        Divider()
        SettingsLink(title: "Battery Settings…") { controller.openSettings("com.apple.Battery-Settings.extension") }
    }
}
