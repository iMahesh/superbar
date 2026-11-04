import AppKit
import SwiftUI

/// The Aero-style glass all of Superbar's panels share: a dark HUD blur.
enum Glass {
    /// #1C2B3A at 30% over the blur.
    static let tint = Color(red: 0x1C / 255, green: 0x2B / 255, blue: 0x3A / 255).opacity(0.3)
    static let highlight = Color.white.opacity(0.25)
}

/// An NSHostingView that takes the first click in a panel that is not key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A borderless, non-activating panel over a glass blur. Only the Start menu
/// sets `canKey`: the bar and popovers must never take focus from the front app.
final class GlassPanel: NSPanel {
    private let canKey: Bool
    var onCancel: () -> Void = {}
    var onResignKey: () -> Void = {}

    init(content: some View, size: NSSize, cornerRadius: CGFloat, level: NSWindow.Level, canKey: Bool = false) {
        self.canKey = canKey
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        self.level = level
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = cornerRadius > 0
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone, .ignoresCycle]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .vibrantDark)
        effect.autoresizingMask = [.width, .height]
        if cornerRadius > 0 { effect.maskImage = Self.roundedMask(radius: cornerRadius) }

        let host = FirstMouseHostingView(rootView: content)
        host.sizingOptions = []          // fixed frame, no resize jumps
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        contentView = effect
    }

    override var canBecomeKey: Bool { canKey }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func resignKey() {
        super.resignKey()
        onResignKey()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Mouse handling SwiftUI lacks: the frontmost app at mouse-down, middle click,
/// ⇧click, right click with an NSMenu, hover with the button's screen rect, and drags.
struct MouseCatcher: NSViewRepresentable {
    struct Handlers {
        var click: (_ frontAtMouseDown: pid_t?, _ shift: Bool, _ rect: NSRect) -> Void = { _, _, _ in }
        var middleClick: () -> Void = {}
        var menu: () -> NSMenu? = { nil }
        var hover: (_ inside: Bool, _ rect: NSRect) -> Void = { _, _ in }
        var drag: ((_ offset: CGFloat) -> Void)?
        var dragEnd: ((_ offset: CGFloat) -> Void)?
    }

    var handlers: Handlers

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handlers = handlers
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.handlers = handlers
    }

    final class CatcherView: NSView {
        var handlers = Handlers()
        private var downX: CGFloat?
        private var downFront: pid_t?
        private var dragging = false
        private var area: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let new = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                     owner: self, userInfo: nil)
            addTrackingArea(new)
            area = new
        }

        private var screenRect: NSRect {
            guard let window else { return .zero }
            return window.convertToScreen(convert(bounds, to: nil))
        }

        override func mouseEntered(with event: NSEvent) { handlers.hover(true, screenRect) }
        override func mouseExited(with event: NSEvent) { handlers.hover(false, screenRect) }

        override func mouseDown(with event: NSEvent) {
            // Read the front app now: by mouse-up a click could have changed it.
            downFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
            downX = event.locationInWindow.x
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let downX, let drag = handlers.drag else { return }
            let offset = event.locationInWindow.x - downX
            if !dragging && abs(offset) > 4 { dragging = true }
            if dragging { drag(offset) }
        }

        override func mouseUp(with event: NSEvent) {
            defer { downX = nil }
            guard let downX else { return }
            let offset = event.locationInWindow.x - downX
            if dragging {
                dragging = false
                handlers.dragEnd?(offset)
            } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
                handlers.click(downFront, event.modifierFlags.contains(.shift), screenRect)
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = handlers.menu() else { return super.rightMouseDown(with: event) }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        override func otherMouseUp(with event: NSEvent) {
            if event.buttonNumber == 2 { handlers.middleClick() }
        }
    }
}
