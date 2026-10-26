import CoreGraphics

/// Sizes on the canvas, in canvas points (multiply by the zoom for the screen). Tables are laid out from these alone,
/// so sockets can be placed without measuring views.
enum Metrics {
    static let tableWidth: CGFloat = 236
    /// The grid's key column (PK, FK) and type column; names get the rest.
    static let keyColumnWidth: CGFloat = 30
    static let typeColumnWidth: CGFloat = 86
    static let headerHeight: CGFloat = 24
    static let rowHeight: CGFloat = 22
    /// From a cell's edges to its text, the same on both sides.
    static let cellInset: CGFloat = 8
    static let cornerRadius: CGFloat = 10
    /// Between a selected card and its ring; the ring's inner radius is `cornerRadius + selectionGap`.
    static let selectionGap: CGFloat = 3
    static let selectionWidth: CGFloat = 2
    /// The header's tinted edge.
    static let headerBorderWidth: CGFloat = 1

    /// Sockets sit centered on the card's side edges.
    static let socketDiameter: CGFloat = 8
    /// How close the pointer has to come to a socket to grab it or drop a wire on it.
    static let socketHitRadius: CGFloat = 9
    /// How close a click has to come to a wire to land on it, in screen points.
    static let wireHitRadius: CGFloat = 6
    /// The smallest a grabbable thing gets on screen, in screen points, so zooming out doesn't make it unclickable.
    static let minimumTarget: CGFloat = 24

    static let wireWidth: CGFloat = 2.25
    /// A port's bus, standing for many wires.
    static let busWidth: CGFloat = wireWidth * 2
    /// The outline around a selected wire: a point and a half each side of it.
    static let selectedWireWidth: CGFloat = wireWidth + 3
    /// Between neighboring wires in a zip tie. Each wire is drawn over a halo this wide, so a bundle reads as separate
    /// strands and crossings show which wire is on top.
    static let tieSpacing: CGFloat = 4
    static let tieThickness: CGFloat = 5
    /// How far a tie reaches past its outermost wires.
    static let tieOverhang: CGFloat = 4.5
    static let bendPointDiameter: CGFloat = 7

    /// Between a group's boundary and its tables.
    static let groupPadding: CGFloat = 24
    /// Above its tables, for its name.
    static let groupLabelHeight: CGFloat = 22
    static let groupCornerRadius: CGFloat = cornerRadius + groupPadding
    /// A port's pill on a group's edge, as much as is kept clear for it (its label may make it longer).
    static let portWidth: CGFloat = 96
    static let portHeight: CGFloat = 20
    /// The + for adding a port by a group's edge, on screen.
    static let portHintRadius: CGFloat = 10

    /// How far apart wires plugging into a port's inside end are: as a zip tie holds them.
    static let portSlotSpacing: CGFloat = tieSpacing

    /// Which grid column a point on a table falls in, by its distance from the table's left edge.
    enum GridColumn { case key, name, type }

    static func gridColumn(atX x: CGFloat) -> GridColumn {
        x < keyColumnWidth ? .key : x < tableWidth - typeColumnWidth ? .name : .type
    }

    static func size(of table: Table) -> CGSize {
        CGSize(width: tableWidth, height: headerHeight + CGFloat(table.columns.count) * rowHeight)
    }

    static func frame(of table: Table) -> CGRect {
        CGRect(origin: table.position, size: size(of: table))
    }

    /// A cell of a table at `frame`: in the header (`row` nil), which spans the table, or a column's row.
    static func cell(row: Int?, part: GridColumn, in frame: CGRect) -> CGRect {
        guard let row else { return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: headerHeight) }
        let y = frame.minY + headerHeight + CGFloat(row) * rowHeight
        let (x, width): (CGFloat, CGFloat) = switch part {
        case .key: (0, keyColumnWidth)
        case .name: (keyColumnWidth, tableWidth - keyColumnWidth - typeColumnWidth)
        case .type: (tableWidth - typeColumnWidth, typeColumnWidth)
        }
        return CGRect(x: frame.minX + x, y: y, width: width, height: rowHeight)
    }

    /// How far around a socket the pointer grabs it, in canvas points: at least a comfortable target on screen, but no
    /// taller than its row, so neighbors don't overlap.
    static func socketReach(zoom: CGFloat) -> CGFloat {
        max(socketHitRadius * 2 * zoom, min(minimumTarget, rowHeight * zoom)) / 2 / zoom
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
