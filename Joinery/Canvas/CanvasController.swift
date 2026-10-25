import SwiftUI

/// One window's view of its schema: where it's looking, what's selected, and gestures in progress. None of this is
/// saved; gestures write to the document only when they end, so each is a single undo step.
@MainActor @Observable
final class CanvasController {
    enum Tool { case select, zipTie }

    enum Selection: Hashable {
        case table(Table.ID)
        case relationship(Relationship.ID)
        case zipTie(ZipTie.ID)
    }

    /// A wire being dragged out of a socket, in canvas points.
    struct Connection {
        var from: Column.ID
        var start: CGPoint
        var end: CGPoint
        var target: Column.ID?
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
    var tool = Tool.select
    var selection: Selection?
    var showsInspector = false

    var tableDrag: [Table.ID: CGPoint] = [:]
    var tieDrag: [ZipTie.ID: CGPoint] = [:]
    var hoveredTie: ZipTie.ID?
    var connection: Connection?
    var stroke: Stroke?
    var panOrigin: CGPoint?

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

    /// Adds a table in the middle of the view, stepped down and right from any already there.
    func addTable(to schema: inout Schema) {
        let middle = canvasPoint(CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
        var position = CGPoint(x: (middle.x - Metrics.tableWidth / 2).rounded(), y: (middle.y - 80).rounded())
        while schema.tables.contains(where: { $0.position.distance(to: position) < 8 }) { position += CGPoint(x: 24, y: 24) }
        selection = .table(schema.addTable(at: position))
        showsInspector = true
    }

    func deleteSelection(in schema: inout Schema) {
        switch selection {
        case .table(let id): schema.removeTable(id)
        case .relationship(let id): schema.removeRelationships { $0.id == id }
        case .zipTie(let id): schema.removeZipTie(id)
        case nil: return
        }
        selection = nil
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
