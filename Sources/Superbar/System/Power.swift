import AppKit

enum PowerAction: String, CaseIterable, Identifiable {
    case shutDown, restart, logOut, sleep, lock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shutDown: "Shut Down"
        case .restart: "Restart"
        case .logOut: "Log Out"
        case .sleep: "Sleep"
        case .lock: "Lock Screen"
        }
    }
}

/// Sleep, lock, and the System Events commands. Restart, shut down, and log out
/// go through System Events, so apps with unsaved documents still ask.
enum Power {
    /// Called when Automation of System Events is off: open Settings on that row.
    static var onAutomationDenied: () -> Void = {}

    static func perform(_ action: PowerAction) {
        switch action {
        case .sleep:
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            task.arguments = ["sleepnow"]
            try? task.run()
        case .lock:
            // ⌃⌘Q, the system's Lock Screen shortcut.
            WindowActions.postKey(12, flags: [.maskControl, .maskCommand], to: nil)
        case .shutDown: systemEvents("shut down")
        case .restart: systemEvents("restart")
        case .logOut: systemEvents("log out")
        }
    }

    private static func systemEvents(_ verb: String) {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"System Events\" to \(verb)")?.executeAndReturnError(&error)
        guard let error else { return }
        let number = error[NSAppleScript.errorNumber] as? Int
        // -1743: not allowed; -128: someone cancelled (an app's save prompt), which is fine.
        if number == -1743 || number == -1744 {
            Permissions.shared.refreshAutomation(ask: false)
            onAutomationDenied()
        }
    }
}
