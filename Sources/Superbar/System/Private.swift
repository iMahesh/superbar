import AppKit
import ApplicationServices

/// Private calls looked up at run time with dlsym, the same ones AltTab and yabai use.
/// Each caller falls back to a public API when a symbol is missing.
nonisolated enum Private {
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordTo = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias CoreDockSendNotification = @convention(c) (CFString, Int32) -> Void
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias DisplayCurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias SpaceGetType = @convention(c) (Int32, UInt64) -> Int32

    private static func symbol<T>(_ name: String, in path: String? = nil, as type: T.Type) -> T? {
        // RTLD_DEFAULT searches every loaded image; SkyLight is opened by path first.
        let handle = path.flatMap { dlopen($0, RTLD_LAZY) } ?? UnsafeMutableRawPointer(bitPattern: -2)
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let getProcessForPID = symbol("GetProcessForPID", as: GetProcessForPID.self)
    private static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", in: skyLight, as: SetFrontProcess.self)
    private static let postEventRecordTo = symbol("SLPSPostEventRecordTo", in: skyLight, as: PostEventRecordTo.self)
    private static let axGetWindow = symbol("_AXUIElementGetWindow", as: AXGetWindow.self)
    private static let coreDockSend = symbol("CoreDockSendNotification", as: CoreDockSendNotification.self)
    private static let mainConnectionID = symbol("SLSMainConnectionID", in: skyLight, as: MainConnectionID.self)
    private static let displayCurrentSpace = symbol("SLSManagedDisplayGetCurrentSpace", in: skyLight, as: DisplayCurrentSpace.self)
    private static let spaceGetType = symbol("SLSSpaceGetType", in: skyLight, as: SpaceGetType.self)

    /// Private calls this macOS lacks, for the self-test. Each falls back, but less well.
    static var missing: [String] {
        [("GetProcessForPID", getProcessForPID != nil),
         ("_SLPSSetFrontProcessWithOptions", setFrontProcess != nil),
         ("SLPSPostEventRecordTo", postEventRecordTo != nil),
         ("_AXUIElementGetWindow", axGetWindow != nil),
         ("CoreDockSendNotification", coreDockSend != nil),
         ("SLSManagedDisplayGetCurrentSpace", displayCurrentSpace != nil && mainConnectionID != nil),
         ("SLSSpaceGetType", spaceGetType != nil)].filter { !$0.1 }.map(\.0)
    }

    /// Whether the main display's current Space is a full-screen one (Space type 4),
    /// as yabai reads it. No permission needed. Nil when the calls are missing.
    static func mainDisplayIsInFullScreenSpace() -> Bool? {
        guard let mainConnectionID, let displayCurrentSpace, let spaceGetType,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue(),
              let name = CFUUIDCreateString(nil, uuid) else { return nil }
        let connection = mainConnectionID()
        let space = displayCurrentSpace(connection, name)
        guard space != 0 else { return nil }
        return spaceGetType(connection, space) == 4
    }

    /// The CGWindowID behind an AX window, or nil.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow else { return nil }
        var id: CGWindowID = 0
        return axGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// Brings one window (or, with no ID, the app) to the front with keyboard focus.
    /// Returns false when SkyLight is missing, so the caller can use `activate()`.
    static func bringToFront(pid: pid_t, windowID: CGWindowID?) -> Bool {
        guard let getProcessForPID, let setFrontProcess else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        if let windowID, windowID != 0 {
            _ = setFrontProcess(&psn, windowID, 0x200)  // kCPSUserGenerated
            makeKeyWindow(&psn, windowID)
        } else {
            _ = setFrontProcess(&psn, 0, 0x400)         // kCPSNoWindows
        }
        return true
    }

    /// Two synthetic event records that make the window key, as AltTab does.
    private static func makeKeyWindow(_ psn: inout ProcessSerialNumber, _ windowID: CGWindowID) {
        guard let postEventRecordTo else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID) { id in
            for i in 0..<4 { bytes[0x3c + i] = id[i] }
        }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEventRecordTo(&psn, &bytes)
    }

    /// Toggles the Dock's "show desktop". Returns false when the call is missing.
    static func toggleShowDesktop() -> Bool {
        guard let coreDockSend else { return false }
        coreDockSend("com.apple.showdesktop.awake" as CFString, 0)
        return true
    }
}
