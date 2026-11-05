import AppKit
import CoreAudio
import CoreLocation
import CoreWLAN
import IOKit.ps
import Network
import Observation
import SuperbarKit

/// Time, volume, network, and battery for the right side of the bar.
@Observable
final class TrayModel {
    enum NetworkState { case wifi, wired, other, offline }
    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
        var onPower: Bool
        /// Minutes to empty on battery, or to full while charging. Nil while macOS is still estimating.
        var minutesLeft: Int? = nil
    }

    private(set) var now = Date()
    private(set) var volume: Float?
    private(set) var muted = false
    private(set) var network: NetworkState = .other
    private(set) var battery: Battery?
    /// Nil on a Mac without Wi-Fi.
    private(set) var wifiOn: Bool?
    /// The network name. macOS hides it from apps without Location access.
    private(set) var wifiName: String?
    private(set) var wifiRSSI: Int?
    /// Other networks in range, from the last scan.
    private(set) var nearby: [WiFiNetwork] = []
    private(set) var scanning = false
    /// The network being joined, while it is.
    private(set) var joining: String?
    /// Network names need Location access: nil until the user has been asked.
    private(set) var locationAllowed: Bool?
    private(set) var volumeSettable = false
    /// When the clock redraws next: the start of the next minute.
    private(set) var nextTick = Date()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var location: LocationAccess?
    /// Snapshots: keep the seeded Wi-Fi instead of reading the real one.
    @ObservationIgnored private var seeded = false
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var batterySource: CFRunLoopSource?
    @ObservationIgnored private var volumeDevice: AudioDeviceID = 0
    @ObservationIgnored private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    nonisolated(unsafe) private static weak var current: TrayModel?  // read only from the IOPS callback hop

    func start() {
        Self.current = self
        readWiFi()
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
            Task { @MainActor in
                TrayModel.current?.network = state
                TrayModel.current?.readWiFi()
            }
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
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = desc[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            let value = Battery(percent: max > 0 ? current * 100 / max : current,
                                charging: charging,
                                onPower: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                minutesLeft: (minutes ?? -1) > 0 ? minutes : nil)
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

        var settable: DarwinBoolean = false
        volumeSettable = AudioObjectIsPropertySettable(volumeDevice, &address, &settable) == noErr && settable.boolValue

        address.mSelector = kAudioDevicePropertyMute
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        muted = AudioObjectGetPropertyData(volumeDevice, &address, 0, nil, &size, &mute) == noErr && mute != 0
    }

    /// Sets the output volume, 0...1, and unmutes when it goes above zero.
    @discardableResult
    func setVolume(_ value: Float) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: Self.virtualMainVolume, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var v = Float32(min(max(value, 0), 1))
        let ok = AudioObjectSetPropertyData(volumeDevice, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
        if ok {
            volume = v
            if muted && v > 0 { setMuted(false) }
        }
        return ok
    }

    func setMuted(_ on: Bool) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = UInt32(on ? 1 : 0)
        if AudioObjectSetPropertyData(volumeDevice, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
            muted = on
        }
    }

    // MARK: Wi-Fi

    func readWiFi() {
        readLocationAccess()
        guard let interface = CWWiFiClient.shared().interface() else { wifiOn = nil; wifiName = nil; wifiRSSI = nil; return }
        wifiOn = interface.powerOn()
        wifiName = interface.ssid()
        wifiRSSI = interface.ssid() == nil ? nil : interface.rssiValue()
    }

    /// Turns Wi-Fi on or off. Returns an error message, or nil.
    func setWiFi(_ on: Bool) -> String? {
        guard let interface = CWWiFiClient.shared().interface() else { return "This Mac has no Wi-Fi." }
        do {
            try interface.setPower(on)
            readWiFi()
            if on { scanWiFi() } else { nearby = [] }
            return nil
        } catch {
            readWiFi()
            return error.localizedDescription
        }
    }

    /// When the popover opens: ask for Location the first time, then look for networks.
    func openedNetwork() {
        guard !seeded else { return }
        readWiFi()
        if locationAllowed == nil { requestLocation() }
        scanWiFi()
    }

    func scanWiFi() {
        guard wifiOn == true, !scanning else { return }
        scanning = true
        Task {
            let found = await WiFiWorker.scan()
            scanning = false
            readWiFi()
            if let found { nearby = WiFiList.rows(found, connected: wifiName) }
        }
    }

    /// Joins a network; a password only for a new secured one. Returns an error message, or nil.
    func join(_ network: WiFiNetwork, password: String?) async -> String? {
        joining = network.name
        let error = await WiFiWorker.join(network.name, password: password)
        joining = nil
        readWiFi()
        if error == nil { nearby = WiFiList.rows(nearby, connected: wifiName) }
        return error
    }

    func disconnect() {
        CWWiFiClient.shared().interface()?.disassociate()
        readWiFi()
        scanWiFi()
    }

    private func readLocationAccess() {
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: locationAllowed = nil
        case .authorizedAlways: locationAllowed = true
        default: locationAllowed = false
        }
    }

    private func requestLocation() {
        let access = location ?? LocationAccess { [weak self] in
            self?.readWiFi()
            self?.scanWiFi()
        }
        location = access
        access.request()
    }

    var networkStatus: String {
        switch network {
        case .offline: return wifiOn == false ? "Wi-Fi is off" : "Not connected"
        case .wired: return "Connected over Ethernet"
        case .wifi: return wifiName ?? "Connected over Wi-Fi"
        case .other: return "Connected"
        }
    }

    var batteryStatus: String {
        guard let battery else { return "" }
        if battery.charging { return "Charging" }
        return battery.onPower ? "On power adapter" : "On battery"
    }

    var batteryTimeText: String? {
        guard let battery, let minutes = battery.minutesLeft else { return nil }
        let time = "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
        return battery.charging ? "\(time) until full" : "\(time) remaining"
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
    func setForTesting(now: Date, volume: Float?, network: NetworkState, battery: Battery?, wifiName: String? = nil) {
        self.wifiOn = true
        self.wifiName = wifiName
        self.wifiRSSI = wifiName == nil ? nil : -52
        self.locationAllowed = true
        self.nearby = WiFiList.rows([WiFiNetwork(name: "Home 5G", rssi: -48, secure: true, known: true),
                                     WiFiNetwork(name: "Cafe Guest", rssi: -63, secure: false),
                                     WiFiNetwork(name: "Neighbors", rssi: -71, secure: true),
                                     WiFiNetwork(name: "Printer-Direct", rssi: -80, secure: true)], connected: wifiName)
        self.seeded = true
        self.volumeSettable = true
        self.now = now
        self.volume = volume
        self.muted = false
        self.network = network
        self.battery = battery
    }
}

/// Asks for Location access, which macOS requires before it tells an app Wi-Fi network names.
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
        manager.delegate = self
    }

    func request() { manager.requestWhenInUseAuthorization() }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.onChange() }
    }
}

/// CoreWLAN calls that take seconds (a scan is 1 to 3), off the main thread.
nonisolated enum WiFiWorker {
    @concurrent
    static func scan() async -> [WiFiNetwork]? {
        guard let interface = CWWiFiClient.shared().interface(),
              let found = try? interface.scanForNetworks(withName: nil) else { return nil }
        let known = Set((interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []).compactMap(\.ssid))
        return found.compactMap { network in
            guard let name = network.ssid else { return nil }
            return WiFiNetwork(name: name, rssi: network.rssiValue, secure: !network.supportsSecurity(.none), known: known.contains(name))
        }
    }

    @concurrent
    static func join(_ name: String, password: String?) async -> String? {
        guard let interface = CWWiFiClient.shared().interface() else { return "This Mac has no Wi-Fi." }
        do {
            let found = try interface.scanForNetworks(withName: name)
            guard let network = found.max(by: { $0.rssiValue < $1.rssiValue }) else { return "\(name) is out of range." }
            try interface.associate(to: network, password: password)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
