import AppKit
import CoreAudio
import IOKit.ps
import Network
import Observation
import SuperbarKit

/// Time, volume, network, and battery for the right side of the bar.
@Observable
final class TrayModel {
    enum NetworkState { case wifi, wired, other, offline }
    struct Battery: Equatable { var percent: Int; var charging: Bool; var onPower: Bool }

    private(set) var now = Date()
    private(set) var volume: Float?
    private(set) var muted = false
    private(set) var network: NetworkState = .other
    private(set) var battery: Battery?
    /// When the clock redraws next: the start of the next minute.
    private(set) var nextTick = Date()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var batterySource: CFRunLoopSource?
    @ObservationIgnored private var volumeDevice: AudioDeviceID = 0
    @ObservationIgnored private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    nonisolated(unsafe) private static weak var current: TrayModel?  // read only from the IOPS callback hop

    func start() {
        Self.current = self
        tick()
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TrayModel.current?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TrayModel.current?.tick() }
        }
        startNetwork()
        startBattery()
        startVolume()
    }

    // MARK: Clock

    func tick() {
        now = Date()
        nextTick = ClockTick.nextMinute(after: now)
        timer?.invalidate()
        let t = Timer(fire: nextTick, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { TrayModel.current?.tick() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    var timeText: String { Self.time.string(from: now) }
    var dateText: String { Self.date.string(from: now) }

    // Formatters follow the system's 12 or 24 hour setting and date order.
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()
    private static let date: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f }()

    // MARK: Network

    private func startNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable path in
            let state: NetworkState
            if path.status != .satisfied { state = .offline }
            else if path.usesInterfaceType(.wifi) { state = .wifi }
            else if path.usesInterfaceType(.wiredEthernet) { state = .wired }
            else { state = .other }
            Task { @MainActor in TrayModel.current?.network = state }
        }
        monitor.start(queue: DispatchQueue(label: "superbar.network"))
        self.monitor = monitor
    }

    // MARK: Battery

    private func startBattery() {
        readBattery()
        let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in TrayModel.current?.readBattery() }
        }, nil)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            batterySource = source
        }
    }

    func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { battery = nil; return }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let value = Battery(percent: max > 0 ? current * 100 / max : current,
                                charging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                                onPower: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
            if value != battery { battery = value }
            return
        }
        battery = nil
    }

    // MARK: Volume

    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663  // 'vmvc', kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    private func startVolume() {
        var defaultDevice = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        let onDeviceChange: AudioObjectPropertyListenerBlock = { @Sendable _, _ in
            Task { @MainActor in TrayModel.current?.attachVolumeDevice() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultDevice, .main, onDeviceChange)
        attachVolumeDevice()
    }

    func attachVolumeDevice() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners.removeAll()

        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { volume = nil; return }
        volumeDevice = device

        let onChange: AudioObjectPropertyListenerBlock = { @Sendable _, _ in
            Task { @MainActor in TrayModel.current?.readVolume() }
        }
        for selector in [Self.virtualMainVolume, kAudioDevicePropertyMute] {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                               mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(device, &a, .main, onChange) == noErr {
                listeners.append((device, a, onChange))
            }
        }
        readVolume()
    }

    func readVolume() {
        var address = AudioObjectPropertyAddress(mSelector: Self.virtualMainVolume, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        volume = AudioObjectGetPropertyData(volumeDevice, &address, 0, nil, &size, &value) == noErr ? value : nil

        address.mSelector = kAudioDevicePropertyMute
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        muted = AudioObjectGetPropertyData(volumeDevice, &address, 0, nil, &size, &mute) == noErr && mute != 0
    }

    // MARK: Icons

    var volumeSymbol: String {
        guard let volume, !muted, volume > 0.001 else { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var volumeHelp: String {
        guard let volume else { return "No sound output" }
        return muted ? "Muted" : "Volume \(Int((volume * 100).rounded()))%"
    }

    var networkSymbol: String {
        switch network {
        case .wifi: "wifi"
        case .wired: "cable.connector.horizontal"
        case .other: "network"
        case .offline: "wifi.slash"
        }
    }

    var networkHelp: String {
        switch network {
        case .wifi: "Connected over Wi-Fi"
        case .wired: "Connected over Ethernet"
        case .other: "Connected"
        case .offline: "Not connected"
        }
    }

    var batterySymbol: String? {
        guard let battery else { return nil }
        if battery.charging || battery.onPower { return "battery.100percent.bolt" }
        switch battery.percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    /// For snapshots.
    func setForTesting(now: Date, volume: Float?, network: NetworkState, battery: Battery?) {
        self.now = now
        self.volume = volume
        self.muted = false
        self.network = network
        self.battery = battery
    }
}
