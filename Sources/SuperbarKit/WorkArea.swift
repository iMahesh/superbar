import CoreGraphics

/// Keeps windows out from under Superbar, the way Windows keeps them above its
/// taskbar. macOS has no API to reserve screen space, so Superbar moves or trims
/// windows itself. AX coordinates: origin at the top left of the main screen.
public enum WorkArea {
    /// The smallest height Superbar will trim a window to. Shorter than this, it leaves the window alone.
    public static let minimumHeight: CGFloat = 120

    /// The frame that keeps `window` above `bottom`, or nil when it already fits or is not
    /// on this screen.
    /// - Parameters:
    ///   - top: the bottom of the menu bar (the highest a window may go).
    ///   - bottom: the top of Superbar.
    ///   - screenWidth: the main screen's width.
    public static func fit(_ window: CGRect, top: CGFloat, bottom: CGFloat, screenWidth: CGFloat) -> CGRect? {
        fit(window, top: top, bottom: bottom, minX: 0, maxX: screenWidth)
    }

    /// The same for any screen: `minX`...`maxX` is its horizontal range in AX coordinates.
    public static func fit(_ window: CGRect, top: CGFloat, bottom: CGFloat, minX: CGFloat, maxX: CGFloat) -> CGRect? {
        // Only windows on this screen: their middle lies within it.
        guard window.midX >= minX, window.midX <= maxX, window.minY < bottom, window.maxY > bottom + 0.5 else { return nil }
        let overlap = window.maxY - bottom
        // Room above: move it up, size unchanged.
        if window.minY - overlap >= top {
            return CGRect(x: window.minX, y: window.minY - overlap, width: window.width, height: window.height)
        }
        // No room: pin the top under the menu bar and trim the bottom.
        let y = max(window.minY, top)
        let height = bottom - y
        guard height >= minimumHeight else { return nil }
        return CGRect(x: window.minX, y: y, width: window.width, height: height)
    }
}
