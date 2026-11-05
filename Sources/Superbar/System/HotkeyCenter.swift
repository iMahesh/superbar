import Carbon.HIToolbox
import Observation
import SuperbarKit

/// The Start shortcut and the ⌃⌥ snap shortcuts, Carbon hotkeys: no permission, and the
/// key never reaches the front app.
@Observable
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    /// True when RegisterEventHotKey failed, usually because another app owns the combo.
    private(set) var failed = false
    @ObservationIgnored var onStart: () -> Void = {}
    /// Snap shortcuts another app already owns.
    private(set) var snapFailures: [Snap] = []
    @ObservationIgnored var onSnap: (Snap) -> Void = { _ in }
    @ObservationIgnored private var ref: EventHotKeyRef?
    @ObservationIgnored private var snapRefs: [EventHotKeyRef] = []
    private static let snapBase: UInt32 = 100
    @ObservationIgnored private var handlerInstalled = false

    func register(_ combo: KeyCombo) {
        unregister()
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x5342_5354), id: 1)  // 'SBST'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        failed = status != noErr
    }

    /// While Settings records a new shortcut.
    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// Turns the snap shortcuts on or off. Each is registered alone, so one taken
    /// combo doesn't stop the rest.
    func registerSnaps(_ on: Bool) {
        for ref in snapRefs { UnregisterEventHotKey(ref) }
        snapRefs.removeAll()
        snapFailures.removeAll()
        guard on else { return }
        installHandler()
        for (i, snap) in Snap.allCases.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5342_5354), id: Self.snapBase + UInt32(i))
            let combo = snap.shortcut
            if RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                snapRefs.append(ref)
            } else {
                snapFailures.append(snap)
            }
        }
    }

    func fire(_ id: UInt32) {
        if id == 1 { onStart() }
        let i = Int(id) - Int(Self.snapBase)
        if Snap.allCases.indices.contains(i) { onSnap(Snap.allCases[i]) }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in HotkeyCenter.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
