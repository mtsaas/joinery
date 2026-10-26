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

    /// A text field on a table card being edited.
    enum Field: Hashable {
        case tableName(Table.ID)
        case columnName(Column.ID)
        case columnType(Column.ID)
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
    /// The table whose cells are text fields. Only one at a time.
    var editingTable: Table.ID?
    /// A field to focus as soon as the view can, set by things outside the view such as menu commands.
    var requestedFocus: Field?
    var isSpaceHeld = false
    #if DEBUG
    /// Clicking a wire starts a correction to it instead of selecting it.
    var isFeedbackMode = false
    var feedback: FeedbackEdit?
    #endif
    var showsPalette = false
    /// Which of the palette's matches is highlighted.
    var paletteHighlight = 0
    /// A key pressed in a cell that the table handles, for the view to act on.
    var fieldKey: FieldKey?

    enum FieldKey { case next, previous, done, deleteColumn, togglePrimaryKey }

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
        edit(.tableName(id))
    }

    func edit(_ field: Field) {
        requestedFocus = field
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
