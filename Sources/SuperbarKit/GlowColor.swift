/// An RGB color with 0...1 components.
public struct RGB: Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    /// Hue in degrees (0..<360), saturation and brightness in 0...1.
    public var hsb: (h: Double, s: Double, b: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    public init(h: Double, s: Double, b v: Double) {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r1, g1, b1): (Double, Double, Double)
        switch h {
        case ..<60: (r1, g1, b1) = (c, x, 0)
        case ..<120: (r1, g1, b1) = (x, c, 0)
        case ..<180: (r1, g1, b1) = (0, c, x)
        case ..<240: (r1, g1, b1) = (0, x, c)
        case ..<300: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        self.init(r: r1 + m, g: g1 + m, b: b1 + m)
    }
}

/// The hover glow: the icon's main color.
public enum GlowColor {
    /// Averages premultiplied RGBA8 pixels (the icon drawn at 16 by 16), skipping
    /// near-transparent and near-gray ones, then boosts saturation and brightness.
    /// Returns nil when nothing colorful is left: use the accent color then.
    public static func from(premultipliedRGBA px: [UInt8]) -> RGB? {
        var sr = 0.0, sg = 0.0, sb = 0.0, weight = 0.0
        var i = 0
        while i + 3 < px.count {
            let a = Double(px[i + 3]) / 255
            if a >= 0.5 {
                let r = Double(px[i]) / 255 / a, g = Double(px[i + 1]) / 255 / a, b = Double(px[i + 2]) / 255 / a
                let c = RGB(r: min(r, 1), g: min(g, 1), b: min(b, 1))
                let s = c.hsb.s
                if s >= 0.2 && c.hsb.b >= 0.15 {
                    // Strong colors count more than pale ones.
                    sr += c.r * s; sg += c.g * s; sb += c.b * s; weight += s
                }
            }
            i += 4
        }
        // Fewer than ~4 colorful pixels out of 256: treat the icon as gray.
        guard weight > 1.0 else { return nil }
        let avg = RGB(r: sr / weight, g: sg / weight, b: sb / weight).hsb
        return RGB(h: avg.h, s: min(1, avg.s * 1.4 + 0.15), b: max(avg.b, 0.85))
    }
}
