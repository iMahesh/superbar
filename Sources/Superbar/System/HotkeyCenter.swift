import Carbon.HIToolbox
import Observation
import SuperbarKit

/// The Start shortcut, a Carbon hotkey: no permission, and the key never reaches the front app.
@Observable
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    /// True when RegisterEventHotKey failed, usually because another app owns the combo.
    private(set) var failed = false
    @ObservationIgnored var onStart: () -> Void = {}
    @ObservationIgnored private var ref: EventHotKeyRef?
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

    func fire(_ id: UInt32) {
        if id == 1 { onStart() }
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
