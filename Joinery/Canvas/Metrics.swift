import CoreGraphics

/// Sizes on the canvas, in canvas points (multiply by the zoom for the screen). Tables are laid out from these alone,
/// so sockets can be placed without measuring views.
enum Metrics {
    static let tableWidth: CGFloat = 248
    static let headerHeight: CGFloat = 40
    static let rowHeight: CGFloat = 28
    /// Below the last row, so it doesn't sit on the card's rounded bottom edge.
    static let bottomPadding: CGFloat = 6
    /// From the card's side edges to its text, the same on both sides.
    static let contentInset: CGFloat = 16
    static let cornerRadius: CGFloat = 12
    /// Between a selected card and its ring; the ring's inner radius is `cornerRadius + selectionGap`.
    static let selectionGap: CGFloat = 3
    static let selectionWidth: CGFloat = 2

    /// Sockets sit centered on the card's side edges.
    static let socketDiameter: CGFloat = 9
    /// How close the pointer has to come to a socket to grab it or drop a wire on it.
    static let socketHitRadius: CGFloat = 10

    static let wireWidth: CGFloat = 2.25
    /// Between neighboring wires in a zip tie. Each wire is drawn over a halo this wide, so a bundle reads as separate
    /// strands and crossings show which wire is on top.
    static let tieSpacing: CGFloat = 4
    static let tieThickness: CGFloat = 5
    /// How far a tie reaches past its outermost wires.
    static let tieOverhang: CGFloat = 4.5

    static func size(of table: Table) -> CGSize {
        CGSize(width: tableWidth, height: headerHeight + CGFloat(table.columns.count) * rowHeight + bottomPadding)
    }

    static func frame(of table: Table) -> CGRect {
        CGRect(origin: table.position, size: size(of: table))
    }

    static func socket(row: Int, side: Side, in frame: CGRect) -> CGPoint {
        CGPoint(x: side == .leading ? frame.minX : frame.maxX,
                y: frame.minY + headerHeight + (CGFloat(row) + 0.5) * rowHeight)
    }

    /// From the center of a tie to either end.
    static func tieHalfLength(holding count: Int) -> CGFloat {
        CGFloat(count - 1) * tieSpacing / 2 + tieOverhang
    }
}

enum Side: CaseIterable {
    case leading, trailing

    /// The way a wire leaves a socket on this side.
    var outward: CGPoint { CGPoint(x: self == .leading ? -1 : 1, y: 0) }
}
