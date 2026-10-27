import CoreText
import SwiftUI

/// Every table, drawn directly in one layer each frame: cards, grid lines, text and sockets, in canvas points under
/// the zoom, so they're sharp at any size. It stays cheap however many tables there are:
/// - Only tables in view are drawn; when text would be too small to read, it's left out.
/// - Shapes of one color are gathered into one path and filled once, for every table together; all the cards'
///   shadows are one pass. Tables that overlap are drawn in layers, so the one on top covers the one beneath; most
///   models are one layer.
/// - Text is laid out once per string and style (`TextLayouts`) and drawn from that with Core Text.
///
/// Each table is a grid like a small spreadsheet: a name header, then a row per column with its key, name and type.
/// The cell being edited gets a `CellEditor` laid over it in the same place and type.
struct TableLayer: View {
    let tables: [Table]
    /// Where tables being dragged have got to, not yet saved.
    let offsets: [Table.ID: CGPoint]
    let zoom: CGFloat
    let viewOffset: CGPoint
    let viewSize: CGSize
    let selected: Set<Table.ID>
    let cursor: CanvasController.Cell?
    /// The row a wire being dragged would connect to.
    let targetColumn: Column.ID?
    /// Foreign key columns, in the color of the table each references.
    let foreignKeys: [Column.ID: Color]
    /// Sockets with wires plugged in, in their wires' colors.
    let socketColors: [Routing.Socket: Color]
    let hoveredSocket: Routing.Socket?
    let layouts: TextLayouts
    /// In focus mode, the tables in focus; the rest fade, under them.
    var focused: Set<Table.ID>? = nil
    /// The table whose name is being edited, over its header: its name isn't drawn.
    var renaming: Table.ID? = nil

    /// How faint what's out of focus is.
    static let fadedOpacity = 0.22

    @Environment(\.displayScale) private var displayScale

    /// Below this zoom, text would be under about three points tall, and isn't drawn.
    private static let textZoom: CGFloat = 0.27

    var body: some View {
        let visible = visibleTables
        Canvas { context, _ in
            // Faded tables first, so those in focus are on top.
            let faded = focused.map { focused in visible.filter { !focused.contains($0.table.id) } } ?? []
            let clear = focused.map { focused in visible.filter { focused.contains($0.table.id) } } ?? visible
            for (tables, opacity) in [(faded, Self.fadedOpacity), (clear, 1)] {
                for layer in Self.layered(tables) {
                    var context = context
                    context.opacity = opacity
                    draw(layer, in: &context)
                }
            }
        }
        .accessibilityChildren {
            ForEach(visible, id: \.table.id) { table, frame in
                Rectangle()
                    .frame(width: frame.width * zoom, height: frame.height * zoom)
                    .position(CGPoint(x: frame.midX, y: frame.midY) * zoom + viewOffset)
                    .accessibilityLabel("Table \(table.name), \(table.columns.count) columns")
            }
        }
    }

    /// The tables on screen, with where they are now, in canvas points.
    private var visibleTables: [(table: Table, frame: CGRect)] {
        // Wide enough for shadows and sockets.
        let margin: CGFloat = 24
        let view = CGRect(origin: CGPoint(x: -viewOffset.x / zoom, y: -viewOffset.y / zoom), size: viewSize * (1 / zoom))
            .insetBy(dx: -margin, dy: -margin)
        return tables.compactMap { table in
            let offset = offsets[table.id] ?? .zero
            let frame = Metrics.frame(of: table).offsetBy(dx: offset.x, dy: offset.y)
            return frame.intersects(view) ? (table, frame) : nil
        }
    }

    // MARK: Drawing

    /// The tables in layers, bottom first: each goes one above the highest earlier table it overlaps (sockets and
    /// selection ring included), so no two in a layer overlap and they can be drawn together, and a later table covers
    /// an earlier one, as it would as a view.
    static func layered(_ tables: [(table: Table, frame: CGRect)]) -> [[(table: Table, frame: CGRect)]] {
        let margin = Metrics.selectionGap + Metrics.selectionWidth + 1
        let reaches = tables.map { $0.frame.insetBy(dx: -margin, dy: -margin) }
        var levels: [Int] = [], layers: [[(table: Table, frame: CGRect)]] = []
        for (index, table) in tables.enumerated() {
            var level = 0
            for earlier in 0..<index where levels[earlier] >= level && reaches[earlier].intersects(reaches[index]) {
                level = levels[earlier] + 1
            }
            levels.append(level)
            if layers.count == level { layers.append([]) }
            layers[level].append(table)
        }
        return layers
    }

    private func draw(_ visible: [(table: Table, frame: CGRect)], in context: inout GraphicsContext) {
        let radius = Metrics.cornerRadius
        let cards = visible.map { Path(roundedRect: $0.frame, cornerRadius: radius, style: .circular) }

        // The cards and their shadows, all at once. Filters work in the view's points, so this layer is scaled inside.
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.09), radius: 14 * zoom, y: 6 * zoom))
            layer.addFilter(.shadow(color: .black.opacity(0.07), radius: 1.5 * zoom, y: 0.5 * zoom))
            layer.translateBy(x: viewOffset.x, y: viewOffset.y)
            layer.scaleBy(x: zoom, y: zoom)
            var all = Path()
            for card in cards { all.addPath(card) }
            layer.fill(all, with: .color(Theme.card))
        }

        context.translateBy(x: viewOffset.x, y: viewOffset.y)
        context.scaleBy(x: zoom, y: zoom)
        let hairline = 1 / (zoom * displayScale)

        // Shapes gathered by color, to fill once each.
        var lines = Path(), headers: [TableColor: Path] = [:], edges: [TableColor: Path] = [:], borders = Path()
        var highlights = Path(), rings = Path(), cursors = Path()
        let edgeWidth = max(Metrics.headerBorderWidth, hairline)
        for (table, frame) in visible {
            let header = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Metrics.headerHeight)
            headers[table.color, default: Path()].addPath(Path(roundedRect: header, cornerRadii: .init(topLeading: radius, topTrailing: radius), style: .circular))
            edges[table.color, default: Path()].addPath(Self.headerEdge(header, cornerRadius: radius, inset: edgeWidth / 2))
            borders.addPath(Path(roundedRect: frame.insetBy(dx: hairline / 2, dy: hairline / 2),
                                 cornerRadius: radius - hairline / 2, style: .circular))

            let runs = table.compoundPrimaryKeyRuns
            let rows = frame.minY + Metrics.headerHeight
            // The key and type columns' edges, down through the rows.
            for x in [Metrics.keyColumnWidth, Metrics.tableWidth - Metrics.typeColumnWidth - hairline] {
                lines.addRect(CGRect(x: frame.minX + x, y: rows, width: hairline, height: frame.maxY - rows))
            }
            for (index, column) in table.columns.enumerated() {
                let y = rows + CGFloat(index) * Metrics.rowHeight
                if column.id == targetColumn {
                    highlights.addRect(CGRect(x: frame.minX, y: y, width: frame.width, height: Metrics.rowHeight))
                }
                // Between rows; within a compound key the key cells are one, so the line stops short of them.
                guard index > 0 else { continue }
                let merged = runs.contains { $0.contains(index) && $0.lowerBound < index }
                let start = merged ? Metrics.keyColumnWidth + hairline : 0
                lines.addRect(CGRect(x: frame.minX + start, y: y, width: frame.width - start, height: hairline))
            }

            if selected.contains(table.id) {
                // A ring `selectionGap` out from the card, concentric with its corners.
                let inner = Metrics.selectionGap, width = Metrics.selectionWidth
                rings.addPath(Path(roundedRect: frame.insetBy(dx: -inner - width / 2, dy: -inner - width / 2),
                                   cornerRadius: radius + inner + width / 2, style: .circular))
            }
            // Not on a header: it's a name, not a cell in the grid, and its selection is the table's.
            if let cursor, cursor.table == table.id, cursor.row != .header, let rect = cellRect(cursor, of: table, in: frame) {
                // Just inside the cell, as in a spreadsheet, a point clear of its edges on screen.
                let width = max(2, 1.5 / zoom), inset = 1 / zoom + width / 2
                cursors.addPath(Path(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerRadius: max(2 - inset, 0)))
            }
        }

        for (color, path) in headers { context.fill(path, with: .color(color.headerFill)) }
        context.fill(highlights, with: .color(Color.accentColor.opacity(0.14)))
        context.fill(lines, with: .color(Theme.cardBorder))
        context.stroke(borders, with: .color(Theme.cardBorder), lineWidth: hairline)
        for (color, path) in edges { context.stroke(path, with: .color(color.headerBorder), lineWidth: edgeWidth) }
        if zoom >= Self.textZoom { drawText(visible, in: &context) }
        context.stroke(cursors, with: .color(.accentColor), lineWidth: max(2, 1.5 / zoom))
        context.stroke(rings, with: .color(.accentColor), lineWidth: Metrics.selectionWidth)
        drawSockets(visible, in: &context)
    }

    /// Every cell's text, and the badges and key labels, drawn with Core Text from laid-out lines.
    private func drawText(_ visible: [(table: Table, frame: CGRect)], in context: inout GraphicsContext) {
        // Resolved as SwiftUI would, for this light or dark appearance.
        let environment = context.environment
        let primary = Color.primary.resolve(in: environment).cgColor
        let secondary = Color(nsColor: .secondaryLabelColor).resolve(in: environment).cgColor
        let quaternary = Color(nsColor: .quaternaryLabelColor).resolve(in: environment).cgColor
        var badges = Path(), grips = Path()
        var runs: [(line: CTLine, at: CGPoint, color: CGColor)] = []

        func text(_ string: String, _ style: TableText, width: CGFloat, in rect: CGRect, alignment: HorizontalAlignment = .leading,
                  color: CGColor) {
            let line = layouts.line(string, style, width: width)
            let x = alignment == .center ? rect.midX - line.width / 2 : rect.minX
            runs.append((line.ctLine, CGPoint(x: x, y: rect.midY + line.baselineOffset), color))
        }

        let inset = Metrics.cellInset
        for (table, frame) in visible {
            let header = Metrics.cell(row: nil, part: .name, in: frame)
            // The grip at the header's left end, where the table's grabbed to move it, and the name after it.
            if table.id != renaming {
                let name = CGRect(x: header.minX + Metrics.gripWidth, y: header.minY, width: header.width - Metrics.gripWidth - inset, height: header.height)
                text(table.name, .header, width: name.width, in: name, color: primary)
            }
            let dot: CGFloat = 3, gap: CGFloat = 4.5
            let grip = CGPoint(x: header.minX + inset + dot / 2, y: header.midY - gap)
            for column in 0..<2 { for row in 0..<3 {
                let center = grip + CGPoint(x: CGFloat(column) * gap, y: CGFloat(row) * gap)
                grips.addEllipse(in: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot))
            } }
            let runsOfKeys = table.compoundPrimaryKeyRuns
            for run in runsOfKeys {
                let top = Metrics.cell(row: run.lowerBound, part: .key, in: frame)
                let merged = CGRect(x: top.minX, y: top.minY, width: top.width, height: CGFloat(run.count) * Metrics.rowHeight)
                text("PK", .key, width: merged.width, in: merged, alignment: .center, color: secondary)
            }
            for (row, column) in table.columns.enumerated() {
                let key = Metrics.cell(row: row, part: .key, in: frame)
                if !runsOfKeys.contains(where: { $0.contains(row) }) {
                    if column.isPrimaryKey {
                        text("PK", .key, width: key.width, in: key, alignment: .center, color: secondary)
                    } else if let color = foreignKeys[column.id] {
                        text("FK", .key, width: key.width, in: key, alignment: .center, color: color.resolve(in: environment).cgColor)
                    } else {
                        text("·", .key, width: key.width, in: key, alignment: .center, color: quaternary)
                    }
                }
                var name = Metrics.cell(row: row, part: .name, in: frame).insetBy(dx: inset, dy: 0)
                if column.isUnique && !column.isPrimaryKey {
                    // A capsule at the cell's end; the name gives way to it.
                    let badge = layouts.line("UQ", .badge, width: .infinity)
                    let size = CGSize(width: badge.width + 7, height: badge.height + 3)
                    let capsule = CGRect(x: name.maxX - size.width, y: name.midY - size.height / 2, width: size.width, height: size.height)
                    badges.addPath(Path(roundedRect: capsule, cornerRadius: size.height / 2))
                    text("UQ", .badge, width: .infinity, in: capsule, alignment: .center, color: secondary)
                    name.size.width -= size.width + 4
                }
                text(column.name, column.isPrimaryKey ? .keyName : .name, width: name.width, in: name, color: primary)
                let type = Metrics.cell(row: row, part: .type, in: frame).insetBy(dx: inset, dy: 0)
                text(column.typeLabel, .type, width: type.width, in: type, color: secondary)
            }
        }
        context.fill(badges, with: .color(Color.secondary.opacity(0.16)))
        context.fill(grips, with: .color(Color(cgColor: secondary).opacity(0.75)))
        context.withCGContext { cg in
            // Core Text draws upward; the canvas runs down.
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            for run in runs {
                cg.setFillColor(run.color)
                cg.textPosition = run.at
                CTLineDraw(run.line, cg)
            }
        }
    }

    /// Every socket, both sides of every row: an empty ring until a wire plugs in, then filled with its color. The one
    /// under the pointer is drawn larger, to show it can be grabbed.
    private func drawSockets(_ visible: [(table: Table, frame: CGRect)], in context: inout GraphicsContext) {
        let line: CGFloat = 1.5
        var empty = Path(), rings = Path(), colored: [Color: Path] = [:]
        var hovered: (center: CGPoint, color: Color?)?
        for (table, frame) in visible {
            for (row, column) in table.columns.enumerated() {
                for side in Side.allCases {
                    let socket = Routing.Socket(column: column.id, side: side)
                    let center = Metrics.socket(row: row, side: side, in: frame)
                    let color = socketColors[socket]
                    if socket == hoveredSocket { hovered = (center, color); continue }
                    let circle = Self.circle(at: center, diameter: Metrics.socketDiameter)
                    if let color {
                        colored[color, default: Path()].addPath(circle)
                    } else {
                        empty.addPath(circle)
                        // Inside the circle's edge, as a border is.
                        rings.addPath(Self.circle(at: center, diameter: Metrics.socketDiameter - line))
                    }
                }
            }
        }
        context.fill(empty, with: .color(Theme.card))
        context.stroke(rings, with: .color(Theme.socket), lineWidth: line)
        for (color, path) in colored { context.fill(path, with: .color(color)) }
        if let hovered {
            let diameter = Metrics.socketDiameter * 1.45
            context.fill(Self.circle(at: hovered.center, diameter: diameter), with: .color(hovered.color ?? Theme.card))
            context.stroke(Self.circle(at: hovered.center, diameter: diameter - line), with: .color(hovered.color ?? Theme.socket),
                           lineWidth: line)
        }
    }

    // MARK: Geometry

    private static func circle(at center: CGPoint, diameter: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter))
    }

    private func cellRect(_ cell: CanvasController.Cell, of table: Table, in frame: CGRect) -> CGRect? {
        switch cell.row {
        case .header: Metrics.cell(row: nil, part: .name, in: frame)
        case .column(let id): table.columns.firstIndex { $0.id == id }.map { Metrics.cell(row: $0, part: cell.part, in: frame) }
        }
    }

    /// The header's left, top and right edges, open at the bottom: stroked `inset` inside the card, along a radius that
    /// much smaller, so it's concentric with the card's corners.
    private static func headerEdge(_ rect: CGRect, cornerRadius: CGFloat, inset: CGFloat) -> Path {
        let left = rect.minX + inset, right = rect.maxX - inset, top = rect.minY + inset
        let radius = cornerRadius - inset
        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: right, y: top), radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: right, y: rect.maxY))
        return path
    }
}

/// The type styles of a table's text.
enum TableText: Hashable {
    case header, name, keyName, type, key, badge

    var font: NSFont {
        switch self {
        case .header: .systemFont(ofSize: 13, weight: .semibold)
        case .name: .systemFont(ofSize: 11)
        case .keyName: .systemFont(ofSize: 11, weight: .medium)
        case .type: .monospacedSystemFont(ofSize: 10, weight: .regular)
        case .key: Self.rounded(9)
        case .badge: Self.rounded(8)
        }
    }

    /// For the cell editor, which matches the text it replaces, at the canvas's zoom.
    func swiftUIFont(zoom: CGFloat) -> Font {
        Font(font.withSize(font.pointSize * zoom))
    }

    private static func rounded(_ size: CGFloat) -> NSFont {
        let bold = NSFont.systemFont(ofSize: size, weight: .bold)
        return bold.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? bold
    }
}

/// Text laid out for drawing, kept by string, style and width: laying text out is the costly part of drawing it, and
/// the same names are drawn every frame.
@MainActor
final class TextLayouts {
    struct Line {
        let ctLine: CTLine
        let width: CGFloat
        let height: CGFloat
        /// From the middle of the line's box down to its baseline, to center it on a cell.
        let baselineOffset: CGFloat
    }

    private struct Key: Hashable {
        var string: String
        var style: TableText
        var width: CGFloat
    }

    private var lines: [Key: Line] = [:]

    /// `string` in `style`, cut short with an ellipsis if it's wider than `width`.
    func line(_ string: String, _ style: TableText, width: CGFloat) -> Line {
        let key = Key(string: string, style: style, width: width)
        if let line = lines[key] { return line }
        // ponytail: forgets everything past a limit; an LRU if typing a long session's worth of names ever matters.
        if lines.count > 20_000 { lines.removeAll() }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            // Colored by the drawing, so one layout serves every color and appearance.
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        var ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        if CTLineGetTypographicBounds(ctLine, nil, nil, nil) > width,
           let truncated = CTLineCreateTruncatedLine(ctLine, width, .end,
                                                     CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))) {
            ctLine = truncated
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
        let line = Line(ctLine: ctLine, width: lineWidth, height: ascent + descent, baselineOffset: (ascent - descent) / 2)
        lines[key] = line
        return line
    }
}

extension Column {
    /// The type as shown and typed: "uuid", or "text?" when nullable.
    var typeLabel: String { type.rawValue + (isNullable ? "?" : "") }
}
