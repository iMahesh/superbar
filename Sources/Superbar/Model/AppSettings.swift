import AppKit
import Observation
import ServiceManagement
import SuperbarKit

/// The icons left of the clock. Any of them can be hidden in Settings.
enum TrayIcon: String, CaseIterable, Identifiable {
    case trash, network, sound, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trash: "Trash"
        case .network: "Wi-Fi"
        case .sound: "Sound"
        case .battery: "Battery"
        }
    }
}

extension BarVisibility: Identifiable {
    public var id: String { rawValue }
    var title: String {
        switch self {
        case .alwaysShow: "Always show"
        case .autoHide: "Auto-hide"
        case .alwaysHide: "Always hide"
        }
    }
}

enum BarSize: String, CaseIterable, Identifiable {
    case small, normal
    var id: String { rawValue }
    var title: String { self == .small ? "Small" : "Normal" }
}

/// Sizes of the bar's parts, from the brief: normal 40 pt with 56 by 40 buttons and
/// 32 pt icons; small 30 pt with 24 pt icons.
struct BarMetrics {
    let height: CGFloat
    let buttonWidth: CGFloat
    let icon: CGFloat
    let orb: CGFloat
    let clockFont: CGFloat
    let showDesktopWidth: CGFloat = 10

    /// The Mission Control button after the orb.
    var missionControlWidth: CGFloat { height < 40 ? 32 : 40 }
    /// Where the first app button starts: after the orb, its padding, and Mission Control.
    var appStripStart: CGFloat { orb + Space.xs * 2 + missionControlWidth }

    static func of(_ size: BarSize) -> BarMetrics {
        switch size {
        case .normal: BarMetrics(height: 40, buttonWidth: 56, icon: 32, orb: 40, clockFont: 12)
        case .small: BarMetrics(height: 30, buttonWidth: 44, icon: 24, orb: 30, clockFont: 10)  // grid: ok 30 pt is the small size in the brief
        }
    }
}

@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = Store.defaults

    var barSize: BarSize {
        didSet { defaults.set(barSize.rawValue, forKey: Store.Key.barSize) }
    }

    /// Always show, auto-hide, or always hide (only the Start shortcut brings it up).
    var barVisibility: BarVisibility {
        didSet { defaults.set(barVisibility.rawValue, forKey: Store.Key.barVisibility) }
    }

    /// Seconds the bar waits after the pointer leaves it before it hides.
    var autoHideDelay: Double {
        didSet {
            let clamped = BarVisibility.clampDelay(autoHideDelay)
            if clamped != autoHideDelay { autoHideDelay = clamped; return }
            defaults.set(autoHideDelay, forKey: Store.Key.autoHideDelay)
        }
    }

    /// Move or trim windows so nothing hides under the bar. Default on.
    var keepWindowsAbove: Bool {
        didSet {
            defaults.set(keepWindowsAbove, forKey: Store.Key.keepWindowsAbove)
            if keepWindowsAbove { WindowFitter.shared.scanAll() }
        }
    }

    /// Tray icons the user turned off. Stored as the ones hidden, so a new icon shows by default.
    var hiddenTrayIcons: Set<TrayIcon> {
        didSet { defaults.set(hiddenTrayIcons.map(\.rawValue).sorted(), forKey: Store.Key.hiddenTrayIcons) }
    }

    func shows(_ icon: TrayIcon) -> Bool { !hiddenTrayIcons.contains(icon) }

    func setShows(_ icon: TrayIcon, _ on: Bool) {
        if on { hiddenTrayIcons.remove(icon) } else { hiddenTrayIcons.insert(icon) }
    }

    /// The ⌃⌥ shortcuts that snap the front window. Default on.
    var snapShortcuts: Bool {
        didSet {
            defaults.set(snapShortcuts, forKey: Store.Key.snapShortcuts)
            HotkeyCenter.shared.registerSnaps(snapShortcuts)
        }
    }

    var startHotkey: KeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(startHotkey) { defaults.set(data, forKey: Store.Key.startHotkey) }
            HotkeyCenter.shared.register(startHotkey)
        }
    }

    /// Mirrors SMAppService; only the real app bundle can register.
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var launchAtLoginError: String?

    var metrics: BarMetrics { .of(barSize) }

    init() {
        barSize = BarSize(rawValue: defaults.string(forKey: Store.Key.barSize) ?? "") ?? .normal
        barVisibility = BarVisibility(rawValue: defaults.string(forKey: Store.Key.barVisibility) ?? "") ?? .alwaysShow
        autoHideDelay = BarVisibility.clampDelay(defaults.object(forKey: Store.Key.autoHideDelay) as? Double ?? 0.5)
        keepWindowsAbove = defaults.object(forKey: Store.Key.keepWindowsAbove) as? Bool ?? true
        hiddenTrayIcons = Set((defaults.stringArray(forKey: Store.Key.hiddenTrayIcons) ?? []).compactMap(TrayIcon.init))
        snapShortcuts = defaults.object(forKey: Store.Key.snapShortcuts) as? Bool ?? true
        startHotkey = defaults.data(forKey: Store.Key.startHotkey)
            .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .startDefault
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
