import CoreGraphics

/// Where a window can snap: the whole free area, a half, a quarter, or a third.
public enum Snap: String, CaseIterable, Sendable, Identifiable {
    case fill
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fill: "Fill Screen"
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left Quarter"
        case .topRight: "Top Right Quarter"
        case .bottomLeft: "Bottom Left Quarter"
        case .bottomRight: "Bottom Right Quarter"
        case .leftThird: "Left Third"
        case .centerThird: "Center Third"
        case .rightThird: "Right Third"
        }
    }

    /// Column, number of columns, row, number of rows.
    private var cell: (col: Int, cols: Int, row: Int, rows: Int) {
        switch self {
        case .fill: (0, 1, 0, 1)
        case .leftHalf: (0, 2, 0, 1)
        case .rightHalf: (1, 2, 0, 1)
        case .topHalf: (0, 1, 0, 2)
        case .bottomHalf: (0, 1, 1, 2)
        case .topLeft: (0, 2, 0, 2)
        case .topRight: (1, 2, 0, 2)
        case .bottomLeft: (0, 2, 1, 2)
        case .bottomRight: (1, 2, 1, 2)
        case .leftThird: (0, 3, 0, 1)
        case .centerThird: (1, 3, 0, 1)
        case .rightThird: (2, 3, 0, 1)
        }
    }

    /// The window's frame inside `area`: the screen below the menu bar, beside the Dock,
    /// and above Superbar. Top-left origin (AX coordinates). Edges are rounded to whole
    /// points so neighbours meet without a gap or an overlap.
    public func frame(in area: CGRect) -> CGRect {
        let c = cell
        func edge(_ start: CGFloat, _ length: CGFloat, _ i: Int, _ n: Int) -> CGFloat {
            (start + length * CGFloat(i) / CGFloat(n)).rounded()
        }
        let x0 = edge(area.minX, area.width, c.col, c.cols), x1 = edge(area.minX, area.width, c.col + 1, c.cols)
        let y0 = edge(area.minY, area.height, c.row, c.rows), y1 = edge(area.minY, area.height, c.row + 1, c.rows)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The default shortcut keys, all with ⌃⌥: arrows for halves, ↩ to fill, U I J K for
    /// quarters (laid out like the screen), D F G for thirds.
    public var defaultKey: UInt32 {
        switch self {
        case .fill: 36          // ↩
        case .leftHalf: 123     // ←
        case .rightHalf: 124    // →
        case .bottomHalf: 125   // ↓
        case .topHalf: 126      // ↑
        case .topLeft: 32       // U
        case .topRight: 34      // I
        case .bottomLeft: 38    // J
        case .bottomRight: 40   // K
        case .leftThird: 2      // D
        case .centerThird: 3    // F
        case .rightThird: 5     // G
        }
    }

    public var shortcut: KeyCombo { KeyCombo(keyCode: defaultKey, modifiers: KeyCombo.control | KeyCombo.option) }
}

/// The free area of one screen for snapping, in AX coordinates.
public enum SnapArea {
    /// - Parameters:
    ///   - screen: the whole screen.
    ///   - visible: the part macOS leaves free (below the menu bar, beside a visible Dock).
    ///   - barHeight: Superbar's height when it keeps its space, else 0.
    public static func of(screen: CGRect, visible: CGRect, barHeight: CGFloat) -> CGRect {
        let bottom = min(visible.maxY, screen.maxY - barHeight)
        return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: max(bottom - visible.minY, 0))
    }
}
