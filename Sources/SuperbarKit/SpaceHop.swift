/// How far to move, one Space at a time, from a full-screen Space to the nearest desktop
/// Space on the same display. Full-screen Spaces sit to the right of the desktops they came
/// from, so the left is tried first. Negative is left.
public enum SpaceHop {
    /// Space types as SkyLight reports them: 0 is a desktop, 4 a full-screen app.
    public static let desktopType = 0

    /// `types` are the display's Spaces in Mission Control order; `current` an index into them.
    /// Nil when there's no desktop to go to, or the current Space already is one.
    public static func steps(types: [Int], current: Int) -> Int? {
        guard types.indices.contains(current), types[current] != desktopType else { return nil }
        let left = types[..<current].lastIndex(of: desktopType)
        let right = types[(current + 1)...].firstIndex(of: desktopType)
        if let left { return left - current }
        if let right { return right - current }
        return nil
    }
}
