import AppKit
import SwiftUI

/// The app icon: the Start orb over a small glass Superbar, on a deep blue tile.
/// Drawn on Apple's 1024 pt icon grid (an 824 pt tile with a 100 pt margin).
///   Superbar --render-icon <dir>     writes AppIcon.iconset PNGs (tools/make_flat_icon.sh)
struct AppIconArt: View {
    let size: CGFloat

    var body: some View {
        let u = size / 1024           // one point on the 1024 grid
        let tile = 824 * u
        let shape = RoundedRectangle(cornerRadius: 185 * u, style: .continuous)  // grid: ok Apple icon grid corner
        ZStack {
            shape.fill(LinearGradient(colors: [Color(red: 0.16, green: 0.42, blue: 0.86),
                                               Color(red: 0.04, green: 0.12, blue: 0.32)],
                                      startPoint: .top, endPoint: .bottom))
            // A soft sheen across the top, like glass.
            shape.fill(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0)],
                                      startPoint: .top, endPoint: .center))
            shape.strokeBorder(.white.opacity(0.18), lineWidth: max(1, 6 * u))

            // The bar: glass strip with three app tiles.
            let barShape = RoundedRectangle(cornerRadius: 40 * u, style: .continuous)
            barShape
                .fill(LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.10)], startPoint: .top, endPoint: .bottom))
                .overlay(barShape.strokeBorder(.white.opacity(0.45), lineWidth: max(1, 5 * u)))
                .overlay(alignment: .trailing) {
                    HStack(spacing: 22 * u) {  // grid: ok icon grid spacing
                        ForEach(0..<3, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 16 * u, style: .continuous)
                                .fill(.white.opacity(i == 0 ? 0.85 : 0.5))
                                .frame(width: 64 * u, height: 64 * u)
                        }
                    }
                    .padding(.trailing, 44 * u)
                }
                .frame(width: 620 * u, height: 112 * u)
                .offset(y: 250 * u)  // grid: ok icon grid position

            OrbArt(size: 420 * u)
                .shadow(color: Color(red: 0.35, green: 0.75, blue: 1).opacity(0.7), radius: 40 * u)
                .offset(y: -70 * u)  // grid: ok icon grid position
        }
        .frame(width: tile, height: tile)
        .shadow(color: .black.opacity(0.35), radius: 18 * u, y: 10 * u)
        .frame(width: size, height: size)
    }

    /// Writes the PNGs iconutil turns into AppIcon.icns.
    static func render(to dir: String) -> Bool {
        let set = URL(fileURLWithPath: dir).appending(path: "AppIcon.iconset")
        try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                let renderer = ImageRenderer(content: AppIconArt(size: CGFloat(px)))
                renderer.scale = 1
                guard let cg = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return false }
                let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
                do { try png.write(to: set.appending(path: name)) } catch { return false }
            }
        }
        return true
    }
}
