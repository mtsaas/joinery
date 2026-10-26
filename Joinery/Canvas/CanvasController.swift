import SwiftUI

/// One window's view of its schema: where it's looking, what's selected, and gestures in progress. None of this is
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

    /// What a key pressed on the grid asks for; the view carries it out against the schema.
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
        case insertColumn, deleteColumn, toggleKey
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
        var target: Schema.DropTarget?
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
    /// Until the person pans or zooms, the view keeps the whole schema fitted as the window resizes.
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
    /// Which of the palette's matches is highlighted.
    var paletteHighlight = 0

    /// How far the selected tables and ties have been dragged, not yet saved to the document.
    var dragOffset: CGPoint?
    var hoveredTie: ZipTie.ID?
    var connection: Connection?
    var stroke: Stroke?
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
    func addTable(to schema: inout Schema) {
        let middle = canvasPoint(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        var position = CGPoint(x: (middle.x - Metrics.tableWidth / 2).rounded(), y: (middle.y - 80).rounded())
        while schema.tables.contains(where: { $0.position.distance(to: position) < 8 }) { position += CGPoint(x: 24, y: 24) }
        let id = schema.addTable(at: position)
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

    func deleteSelection(in schema: inout Schema) {
        for item in selection {
            switch item {
            case .table(let id): schema.removeTable(id)
            case .relationship(let id): schema.removeRelationships { $0.id == id }
            case .zipTie(let id): schema.removeZipTie(id)
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
    @Entry var schema: Binding<Schema>?
}
