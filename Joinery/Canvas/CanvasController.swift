import SwiftUI

/// One window's view of its model: where it's looking, what's selected, and gestures in progress. None of this is
/// saved; gestures write to the document only when they end, so each is a single undo step.
@MainActor @Observable
final class CanvasController {
    enum Item: Hashable {
        case table(Table.ID)
        case relationship(Relationship.ID)
        case zipTie(ZipTie.ID)
    }

    /// A cell of a table's grid: its name, or a column's key, name or type.
    struct Cell: Hashable {
        enum Row: Hashable { case header, column(Column.ID) }
        var table: Table.ID
        var row: Row
        /// `.name` for the header.
        var part: Metrics.GridColumn

        static func name(of table: Table.ID) -> Cell { Cell(table: table, row: .header, part: .name) }
    }

    /// What a key pressed on the grid asks for; the view carries it out against the model.
    enum CellCommand: Equatable {
        case move(CellMove)
        /// Starts editing, with the text replaced by this (typing over the cell) or kept, caret at the end (F2).
        case edit(replacingWith: String?)
        /// Keeps what was typed, then moves.
        case commit(then: CellMove?)
        /// Drops what was typed.
        case cancel
        case clear
        /// Toggles a key cell's primary key; elsewhere, starts typing with a space.
        case space
        case insertColumn, deleteColumn, toggleKey, toggleUnique, toggleRequired
        /// Off the grid, leaving the table selected.
        case leave
    }

    enum CellMove: Equatable {
        case up, down, left, right
        /// Tab order: across a row, then on to the next row's name.
        case next, previous
        /// Down a row; past the last, a new column.
        case downOrNew
    }

    /// A wire being dragged out of a socket, in canvas points.
    struct Connection {
        var from: Column.ID
        var start: CGPoint
        var end: CGPoint
        var target: DataModel.DropTarget?
    }

    /// A line being drawn across wires to tie them, in canvas points.
    struct Stroke {
        var start: CGPoint
        var end: CGPoint
    }

    static let zoomRange: ClosedRange<CGFloat> = 0.1...4

    var zoom: CGFloat = 1
    /// Where the canvas origin appears in the view.
    var offset = CGPoint.zero
    /// Until the person pans or zooms, the view keeps the whole model fitted as the window resizes.
    private(set) var isFitted = true
    private(set) var viewSize = CGSize.zero
    var selection: Set<Item> = []
    /// The grid's cursor, as in a spreadsheet: the cell that typing goes to.
    var cell: Cell?
    var isEditingCell = false
    /// The edited cell's text. Only its editor reads it, so typing redraws that one cell, not the canvas.
    var draft = ""
    /// Whether editing starts with all of the cell's text selected (double-click) or the caret at the end.
    var selectsAllDraft = false
    var cellCommand: CellCommand?
    /// A cell to start editing as soon as the view can, from outside it (a new table, a menu).
    var editRequest: Cell?
    var isSpaceHeld = false
    #if DEBUG
    /// Clicking a wire starts a correction to it instead of selecting it.
    var isFeedbackMode = false
    var feedback: FeedbackEdit?
    #endif
    var showsPalette = false

    /// The right-click command wheel, while it's open.
    struct Wheel {
        enum Target { case canvas, table(Table.ID), column(Column.ID, in: Table.ID), tie(ZipTie.ID), wire(WireSimulation.Hit) }
        /// In view points.
        var center: CGPoint
        /// What was right-clicked, and where, in canvas points.
        var point: CGPoint
        var target: Target
    }

    var wheel: Wheel?
    /// A right-click to open the wheel for, in view points; the view works out what's under it.
    var wheelRequest: CGPoint?
    /// Which of the palette's matches is highlighted.
    var paletteHighlight = 0

    /// How far the selected tables and ties have been dragged, not yet saved to the document.
    var dragOffset: CGPoint?

    /// A line showing that a dragged table lines up with another: vertical at `position` x, or horizontal at y, from
    /// `start` to `end` along it, in canvas points.
    struct Guide: Equatable {
        var isVertical: Bool
        var position: CGFloat
        var start: CGFloat
        var end: CGFloat
    }

    /// Shown while dragging tables, for every edge or center that lines up with another table's.
    var guides: [Guide] = []

    /// Snaps a drag of the `moving` frames by `offset`, so that if an edge or center of one comes within `tolerance` of
    /// another table's (`others`), across or down, it lines up exactly, as Keynote's guides do. Only along the axes
    /// allowed: with Shift holding a move to one, the other stays put.
    /// - Returns: The snapped offset, and a guide for every line-up it leaves.
    static func snap(_ moving: [CGRect], by offset: CGPoint, to others: [CGRect], tolerance: CGFloat,
                     across: Bool = true, down: Bool = true) -> (offset: CGPoint, guides: [Guide]) {
        func lines(_ rect: CGRect, vertical: Bool) -> [CGFloat] {
            vertical ? [rect.minX, rect.midX, rect.maxX] : [rect.minY, rect.midY, rect.maxY]
        }
        var offset = offset
        for vertical in [true, false] where vertical ? across : down {
            var nearest: CGFloat?
            for frame in moving {
                for line in lines(frame.offsetBy(dx: offset.x, dy: offset.y), vertical: vertical) {
                    for other in others {
                        for target in lines(other, vertical: vertical) where abs(target - line) <= min(tolerance, abs(nearest ?? .infinity)) {
                            nearest = target - line
                        }
                    }
                }
            }
            if let nearest { if vertical { offset.x += nearest } else { offset.y += nearest } }
        }

        // Every line-up there now is, snapped to or not, spanning the tables on it.
        var guides: [Guide] = []
        for vertical in [true, false] {
            var spans: [(position: CGFloat, start: CGFloat, end: CGFloat)] = []
            for frame in moving.map({ $0.offsetBy(dx: offset.x, dy: offset.y) }) {
                for line in lines(frame, vertical: vertical) {
                    for other in others where lines(other, vertical: vertical).contains(where: { abs($0 - line) < 0.5 }) {
                        let start = vertical ? min(frame.minY, other.minY) : min(frame.minX, other.minX)
                        let end = vertical ? max(frame.maxY, other.maxY) : max(frame.maxX, other.maxX)
                        if let index = spans.firstIndex(where: { abs($0.position - line) < 0.5 }) {
                            spans[index].start = min(spans[index].start, start)
                            spans[index].end = max(spans[index].end, end)
                        } else {
                            spans.append((line, start, end))
                        }
                    }
                }
            }
            guides += spans.map { Guide(isVertical: vertical, position: $0.position, start: $0.start, end: $0.end) }
        }
        return (offset, guides)
    }

    /// How far a drag moves things: as far as the pointer, or with the axis locked (Shift), only along whichever of
    /// horizontal and vertical it's gone further.
    static func moveOffset(_ translation: CGPoint, isAxisLocked: Bool) -> CGPoint {
        guard isAxisLocked else { return translation }
        return abs(translation.x) >= abs(translation.y) ? CGPoint(x: translation.x, y: 0) : CGPoint(x: 0, y: translation.y)
    }
    var hoveredTie: ZipTie.ID?
    var connection: Connection?
    var stroke: Stroke?
    /// The zip-tie tool: while it's on, every drag on the canvas draws a line that ties the wires it crosses.
    var isTying = false
    /// Set when the right-drag drawing `stroke` ends, for the view to tie the wires it crossed.
    var isStrokeFinished = false
    /// The selection rectangle being dragged out, in canvas points.
    var marquee: CGRect?
    /// What a drag that started on empty canvas (or on a wire) is doing.
    var backgroundDrag: BackgroundDrag?

    enum BackgroundDrag {
        /// Drawing a line across wires to zip-tie them.
        case stroke
        /// Dragging out a selection rectangle, adding to `base` if Shift was held.
        case marquee(base: Set<Item>)
    }
    var panOrigin: CGPoint?

    /// What aligning lines up: the selected tables, or only if there are none, the selected ties. Ties a selection
    /// rectangle catches along with tables stay put. Nil when there aren't two things to line up.
    var alignable: (tables: Set<Table.ID>, ties: Set<ZipTie.ID>)? {
        let tables = selectedTables, ties = tables.isEmpty ? selectedTies : []
        return tables.count + ties.count >= 2 ? (tables, ties) : nil
    }

    var selectedTables: Set<Table.ID> { Set(selection.compactMap { if case .table(let id) = $0 { id } else { nil } }) }
    var selectedTies: Set<ZipTie.ID> { Set(selection.compactMap { if case .zipTie(let id) = $0 { id } else { nil } }) }

    /// Where dragged items are drawn until the drag ends.
    var tableOffsets: [Table.ID: CGPoint] { dragOffset.map { offset in Dictionary(uniqueKeysWithValues: selectedTables.map { ($0, offset) }) } ?? [:] }
    var tieOffsets: [ZipTie.ID: CGPoint] { dragOffset.map { offset in Dictionary(uniqueKeysWithValues: selectedTies.map { ($0, offset) }) } ?? [:] }

    /// What a selection rectangle selects, given everything it touches. With tables, everything; without, ties take
    /// precedence over the wires through them (which are easy to catch by accident); with neither, the wires.
    static func boxSelection(tables: [Table.ID], ties: [ZipTie.ID], wires: [Relationship.ID]) -> Set<Item> {
        let tables = tables.map(Item.table), ties = ties.map(Item.zipTie), wires = wires.map(Item.relationship)
        if !tables.isEmpty { return Set(tables + ties + wires) }
        return Set(ties.isEmpty ? wires : ties)
    }

    /// Selects `item` on a click: alone, or with Shift added to (or, if already there, taken out of) the selection.
    /// Clicking something already selected keeps the selection, so the whole group can be dragged.
    func click(_ item: Item, extending: Bool) {
        if extending {
            if selection.contains(item) { selection.remove(item) } else { selection.insert(item) }
        } else if !selection.contains(item) {
            selection = [item]
        }
    }

    func canvasPoint(_ viewPoint: CGPoint) -> CGPoint { (viewPoint - offset) / zoom }
    func viewPoint(_ canvasPoint: CGPoint) -> CGPoint { canvasPoint * zoom + offset }

    func resize(to size: CGSize, fitting bounds: CGRect?) {
        let old = viewSize
        viewSize = size
        if isFitted {
            zoomToFit(bounds)
        } else {
            offset += CGPoint(x: size.width - old.width, y: size.height - old.height) / 2
        }
    }

    func pan(by delta: CGPoint) {
        offset += delta
        isFitted = false
    }

    /// Zooms keeping `anchor`, in view points, still; the middle of the view by default.
    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        let anchor = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let newZoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        offset = anchor - (anchor - offset) * (newZoom / zoom)
        zoom = newZoom
        isFitted = false
    }

    /// Pans so `rect` is in the middle of the view, at the current zoom.
    func center(on rect: CGRect) {
        offset = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) - CGPoint(x: rect.midX, y: rect.midY) * zoom
        isFitted = false
    }

    func togglePalette() {
        paletteHighlight = 0
        showsPalette.toggle()
    }

    func zoomToFit(_ bounds: CGRect?) {
        guard let bounds, viewSize.width > 0 else {
            offset = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            return
        }
        // The canvas runs under the toolbar, so leave it room at the top.
        let insets = NSEdgeInsets(top: 100, left: 60, bottom: 60, right: 60)
        let available = CGSize(width: viewSize.width - insets.left - insets.right,
                               height: viewSize.height - insets.top - insets.bottom)
        zoom = min(max(min(available.width / bounds.width, available.height / bounds.height, 1),
                       Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        let middle = CGPoint(x: insets.left + available.width / 2, y: insets.top + available.height / 2)
        offset = middle - CGPoint(x: bounds.midX, y: bounds.midY) * zoom
        isFitted = true
    }

    /// Adds a table in the middle of the view, stepped down and right from any already there, and starts naming it.
    /// Adds a table around `point` (in canvas points), or mid-view, and starts naming it.
    func addTable(to model: inout DataModel, at point: CGPoint? = nil) {
        let middle = point ?? canvasPoint(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        var position = CGPoint(x: (middle.x - Metrics.tableWidth / 2).rounded(), y: (middle.y - (point == nil ? 80 : 12)).rounded())
        while model.tables.contains(where: { $0.position.distance(to: position) < 8 }) { position += CGPoint(x: 24, y: 24) }
        let id = model.addTable(at: position)
        selection = [.table(id)]
        edit(.name(of: id))
    }

    func edit(_ cell: Cell) {
        editRequest = cell
    }

    /// Where `move` takes the cursor from `cell` in `table`, or nil past the last row (for Tab or Return, a new one).
    /// The header has only its name; rows have key, name and type. Tab goes across a row, then to the next row's name.
    static func cell(after cell: Cell, _ move: CellMove, in table: Table) -> Cell? {
        let rows: [Cell.Row] = [.header] + table.columns.map { .column($0.id) }
        guard let row = rows.firstIndex(of: cell.row) else { return nil }
        let parts: [Metrics.GridColumn] = [.key, .name, .type]
        let part = parts.firstIndex(of: cell.part) ?? 1
        func at(_ row: Int, _ part: Metrics.GridColumn) -> Cell {
            Cell(table: table.id, row: rows[row], part: row == 0 ? .name : part)
        }
        // Into the rows from the header, the name; back up to it, the header.
        let downPart = row == 0 ? Metrics.GridColumn.name : cell.part
        switch move {
        case .up: return at(max(row - 1, 0), cell.part)
        case .down: return at(min(row + 1, rows.count - 1), downPart)
        case .downOrNew: return row + 1 < rows.count ? at(row + 1, downPart) : nil
        case .left, .right:
            guard row > 0 else { return cell }
            return at(row, parts[min(max(part + (move == .left ? -1 : 1), 0), parts.count - 1)])
        case .next:
            if row > 0, part < parts.count - 1 { return at(row, parts[part + 1]) }
            return row + 1 < rows.count ? at(row + 1, .name) : nil
        case .previous:
            if row > 0, part > 0 { return at(row, parts[part - 1]) }
            return row > 1 ? at(row - 1, .type) : at(0, .name)
        }
    }

    func deleteSelection(in model: inout DataModel) {
        for item in selection {
            switch item {
            case .table(let id): model.removeTable(id)
            case .relationship(let id): model.removeRelationships { $0.id == id }
            case .zipTie(let id): model.removeZipTie(id)
            }
        }
        selection = []
    }
}

extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    /// The canvas view's own space, which gestures report in so dragged views don't move under their own drag.
    static var canvas: Self { .named("canvas") }
}

extension FocusedValues {
    @Entry var canvasController: CanvasController?
    @Entry var model: Binding<DataModel>?
}
