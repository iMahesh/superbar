/// One Wi-Fi network in the tray's list, whatever CoreWLAN reported for it.
public struct WiFiNetwork: Equatable, Sendable, Identifiable {
    public var name: String
    /// Signal strength in dBm, about -30 (next to the router) to -90 (barely there).
    public var rssi: Int
    public var secure: Bool
    /// Saved on this Mac, so it joins without asking for the password.
    public var known: Bool
    public var id: String { name }

    public init(name: String, rssi: Int, secure: Bool, known: Bool = false) {
        self.name = name
        self.rssi = rssi
        self.secure = secure
        self.known = known
    }

    /// 0 to 1, for the Wi-Fi symbol's bars: three bars from -60 dBm, none below -85.
    public var signal: Double {
        if rssi >= -60 { return 1 }
        if rssi >= -70 { return 0.67 }
        if rssi >= -85 { return 0.33 }
        return 0
    }

    public var signalText: String {
        switch signal {
        case 1: "Excellent signal"
        case 0.67: "Good signal"
        case 0.33: "Weak signal"
        default: "Very weak signal"
        }
    }
}

public enum WiFiList {
    /// One row per name (a network with several access points reports each), the strongest
    /// kept; hidden networks (no name) and the connected one left out; known networks first,
    /// then by signal, then by name.
    public static func rows(_ scan: [WiFiNetwork], connected: String?) -> [WiFiNetwork] {
        var best: [String: WiFiNetwork] = [:]
        for network in scan where !network.name.isEmpty && network.name != connected {
            if let seen = best[network.name], seen.rssi >= network.rssi { continue }
            best[network.name] = network
        }
        return best.values.sorted {
            if $0.known != $1.known { return $0.known }
            if $0.signal != $1.signal { return $0.signal > $1.signal }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
