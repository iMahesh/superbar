import AppKit
import SwiftUI
import SuperbarKit

/// Icons, app URLs, and glow colors per bundle ID. `NSRunningApplication.icon`
/// and icon lookups are slow per call, so each is computed once.
final class IconCache {
    static let shared = IconCache()

    private var icons: [String: NSImage] = [:]
    private var glows: [String: Color] = [:]
    private var urls: [String: URL?] = [:]

    func url(forBundleID id: String) -> URL? {
        if let cached = urls[id] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        urls[id] = url
        return url
    }

    func icon(for key: String, url: URL?, running: NSRunningApplication?) -> NSImage {
        if let cached = icons[key] { return cached }
        let image: NSImage
        if let url { image = NSWorkspace.shared.icon(forFile: url.path) }
        else if let icon = running?.icon { image = icon }
        else { image = NSWorkspace.shared.icon(for: .applicationBundle) }
        icons[key] = image
        return image
    }

    func glow(for key: String, icon: NSImage) -> Color {
        if let cached = glows[key] { return cached }
        let color = Self.mainColor(of: icon).map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? Color.accentColor
        glows[key] = color
        return color
    }

    /// Draws the icon at 16 by 16 and hands the pixels to GlowColor.
    static func mainColor(of icon: NSImage) -> RGB? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            var rect = CGRect(x: 0, y: 0, width: side, height: side)
            guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: rect)
            return true
        }
        return drawn ? GlowColor.from(premultipliedRGBA: pixels) : nil
    }
}
