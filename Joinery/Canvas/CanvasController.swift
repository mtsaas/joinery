import SwiftUI

/// One window's view of its model: where it's looking, what's selected, and gestures in progress. None of this is
/// saved; gestures write to the document only when they end, so each is a single undo step.
@MainActor @Observable
final class CanvasController {
    /// The pasteboard's name for a copied part of a data model: a `DataModel` as JSON.
    static let clipType = NSPasteboard.PasteboardType("com.mtsaas.joinery.clip")

    enum Item: Hashable {
        case table(Table.ID)
        case relationship(Relationship.ID)
        case zipTie(ZipTie.ID)
        /// Selected along with its tables, which moving it moves.
        case group(TableGroup.ID)
    }

    /// The group whose name is being edited.
    var renamingGroup: TableGroup.ID?

    var selectedGroups: Set<TableGroup.ID> { Set(selection.compactMap { if case .group(let id) = $0 { id } else { nil } }) }

    /// Puts the selected tables in a new group, selects it, and starts naming it.
    func groupSelection(in model: inout DataModel) {
        let tables = selectedTables
        guard !tables.isEmpty else { return }
        let id = model.group(tables)
        selectGroup(id, in: model, extending: false)
        renamingGroup = id
    }

    /// Takes away the selected groups, leaving their tables selected where they are.
    func ungroupSelection(in model: inout DataModel) {
        for id in selectedGroups {
            model.ungroup(id)
            selection.remove(.group(id))
        }
    }

    /// Takes the selected tables out of their groups.
    func removeSelectionFromGroups(in model: inout DataModel) {
        model.removeFromGroups(selectedTables)
        selection = selection.filter { if case .group(let id) = $0 { model.groups.contains { $0.id == id } } else { true } }
    }

    // MARK: Copy and paste

    /// Puts the selected tables (and selected groups' tables) on the pasteboard, with their foreign keys, ties and groups;
    /// then, if they're joined to others, offers to copy some of those too.
    /// - Returns: Whether there was anything to copy.
    @discardableResult
    func copySelection(from model: DataModel, offeringMore: Bool = true) -> Bool {
        let ids = model.clip(tables: selectedTables, groups: selectedGroups).tables.map(\.id)
        guard copy(Set(ids), from: model) else { return false }
        if offeringMore, !model.joinedTables(to: Set(ids)).isEmpty { copiedTables = Set(ids) }
        return true
    }

    /// Puts `ids` on the pasteboard, with their foreign keys, ties and groups (holding only them).
    @discardableResult
    func copy(_ ids: Set<Table.ID>, from model: DataModel) -> Bool {
        let clip = model.clip(tables: ids)
        guard !clip.tables.isEmpty, let data = try? JSONEncoder().encode(clip) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: Self.clipType)
        pastes = 0
        return true
    }

    /// The selected tables (and selected groups' tables), or every table with none selected, as Markdown for an AI
    /// assistant: their columns, the SQL to make them, and their notes.
    func copyMarkdown(from model: DataModel, title: String) {
        let ids = model.clip(tables: selectedTables, groups: selectedGroups).tables.map(\.id)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.markdown(of: ids.isEmpty ? nil : Set(ids), title: title), forType: .string)
    }

    /// Tables just copied that are joined to others: offered more of those to copy with them, until dismissed.
    var copiedTables: Set<Table.ID>?

    func cutSelection(from model: inout DataModel) {
        if copySelection(from: model, offeringMore: false) { deleteSelection(in: &model) }
    }

    /// Adds what was copied, here or from another data model, and selects it. Over the original, if it's in view, it
    /// lands a little down and to the right, further each time; otherwise in the middle of the view.
    func paste(into model: inout DataModel) {
        guard let data = NSPasteboard.general.data(forType: Self.clipType),
              let clip = try? JSONDecoder().decode(DataModel.self, from: data), let bounds = clip.bounds else { return }
        let visible = CGRect(origin: CGPoint(x: -offset.x / zoom, y: -offset.y / zoom), size: viewSize * (1 / zoom))
        let columns = Set(model.tables.flatMap(\.columns).map(\.id))
        let isOverOriginal = visible.intersects(bounds) && clip.tables.contains { $0.columns.contains { columns.contains($0.id) } }
        pastes += 1
        let step = CGPoint(x: 32, y: 32) * CGFloat(isOverOriginal ? pastes : pastes - 1)
        let shift = isOverOriginal ? step : CGPoint(x: visible.midX - bounds.midX, y: visible.midY - bounds.midY) + step
        let pasted = model.paste(clip, offset: shift)
        selection = Set(pasted.tables.map { .table($0) } + pasted.ties.map { .zipTie($0) })
    }

    func selectAll(in model: DataModel) {
        selection = Set(model.tables.map { .table($0.id) } + model.zipTies.map { .zipTie($0.id) })
    }

    /// Selects a group with its tables and the ties inside it, so moving it moves them all; or with Shift adds them to
    /// the selection.
    func selectGroup(_ id: TableGroup.ID, in model: DataModel, extending: Bool) {
        let items = Set([Item.group(id)] + model.members(of: id).map { Item.table($0.id) } + model.ties(in: id).map(Item.zipTie))
        selection = extending ? selection.union(items) : items
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
        /// The column it's drawn for: the one dragged from, or the one a port's inside stands for; nil from a port's
        /// outside, to be plugged into whatever it's dropped on.
        var from: Column.ID?
        /// The port socket it's drawn from, if it is.
        var port: (id: GroupPort.ID, isOutside: Bool)?
        var start: CGPoint
        var end: CGPoint
        var target: DataModel.DropTarget?
    }

    /// A cable being pulled about by the pointer: where it was grabbed and is now, which stretch of it (between which
    /// of its ties) that is, the ties it's been tugged out of, and the tie it's over, to go into.
    struct CableDrag {
        var cable: UUID
        var start: CGPoint
        var point: CGPoint
        /// The way the cable ran where it was grabbed.
        var direction: CGPoint
        /// Between its `segment - 1`th tie (or its start) and its `segment`th (or its end), not counting those popped.
        var segment: Int
        /// The ties it's been tugged out of, in order, and whether each was before the grab along it or after.
        var popped: [(id: ZipTie.ID, isBefore: Bool)] = []
        var target: (id: ZipTie.ID, direction: CGPoint)?
    }
    var cableDrag: CableDrag?
    /// A zip tie or bend point dragged alone over another zip tie, and that tie and the way it runs: the two are shown
    /// combined, and are when let go.
    var tieMerge: (tie: ZipTie.ID, target: ZipTie.ID, direction: CGPoint)?

    /// A column being dragged to another place in its table, and where it'd go: before the column at `insertion`, or
    /// last if that's past them all.
    var columnDrag: (table: Table.ID, column: Column.ID, insertion: Int)?
    /// The table open in the table designer, beside the canvas.
    var designing: Table.ID?
    /// A shortcut for the table designer, caught before the field being typed in there could take it.
    enum DesignerCommand: Equatable { case primaryKey, required, unique, insert, delete, next, previous }
    var designerCommand: DesignerCommand?
    /// Whether the designer's focus is in one of its grids, where Tab goes cell to cell, row after row.
    var isDesignerInGrid = false
    /// Where the designer is, in the window (top-left origin), while it's open: scrolling over it scrolls it, not the canvas.
    var designerFrame: CGRect?
    /// The table whose header the pointer's over, where it's grabbed to move it.
    var hoveredHeader: Table.ID?

    /// A port just added from the +, and when: it grows out of the + into place.
    var appearingPort: (id: GroupPort.ID, start: TimeInterval)?

    /// Where a port would be added, while the pointer's near a group's edge: shown as a + there.
    var portHint: (group: TableGroup.ID, spot: (side: Side4, along: CGFloat), point: CGPoint)?

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
    /// Showing something that can't be changed, such as a comparison: dragging pans, and nothing is picked or edited.
    var isReadOnly = false {
        didSet {
            guard isReadOnly else { return }
            selection = []
            cell = nil
            isEditingCell = false
            designing = nil
            wheel = nil
            isTying = false
            showsPalette = false
            focus = nil
        }
    }
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
        enum Target {
            case canvas, table(Table.ID), column(Column.ID, in: Table.ID), tie(ZipTie.ID), wire(WireSimulation.Hit), group(TableGroup.ID), port(GroupPort.ID)
        }
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
    /// What a wire dropped on a table's header makes there, the same while it's previewed and when it's made; fresh after.
    var newColumnIDs = (column: Column.ID(), relationship: Relationship.ID())
    /// A group's port being dragged along its edge, and where it's got to; saved when let go.
    var portDrag: (port: GroupPort.ID, side: Side4, along: CGFloat)?
    var stroke: Stroke?
    /// The zip-tie tool: while it's on, every drag on the canvas draws a line that ties the wires it crosses.
    var isTying = false
    /// Focus mode's tables, nil while it's off: everything but them and what they're joined to fades. Chosen from the
    /// selection when it's turned on (or the first thing selected after, if nothing was), and kept however the selection
    /// changes after, so a part of the model can be worked on in focus; tables made meanwhile join it.
    var focus: Set<Table.ID>?

    var isFocusing: Bool { focus != nil }

    /// The selected tables, a selected group's included.
    func selectedTablesAndMembers(in model: DataModel) -> Set<Table.ID> {
        selectedTables.union(selectedGroups.flatMap { model.members(of: $0).map(\.id) })
    }

    func toggleFocus(in model: DataModel) {
        focus = focus == nil ? selectedTablesAndMembers(in: model) : nil
    }

    /// Focus on what's selected instead, turning focus on if it's off.
    func focusOnSelection(in model: DataModel) {
        focus = selectedTablesAndMembers(in: model)
    }

    func addSelectionToFocus(in model: DataModel) {
        focus = (focus ?? []).union(selectedTablesAndMembers(in: model))
    }
    /// How many times what was last copied has been pasted, to set each paste a little further along.
    var pastes = 0
    /// Set when the right-drag drawing `stroke` ends, for the view to tie the wires it crossed.
    var isStrokeFinished = false
    /// The selection rectangle being dragged out, in canvas points.
    var marquee: CGRect?
    /// Where the pointer is while a button's down, in canvas points: hovering isn't heard then.
    var dragPointer: CGPoint?
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
    /// While untangling, where the moving tables have got to: shown, wires and all, but not saved till it's done.
    var previewOffsets: [Table.ID: CGPoint] = [:]
    /// An untangling in progress: the crossings it started with, the fewest it's found, and how far along it is.
    var untangling: (from: Int, best: Int, progress: Double)?
    @ObservationIgnored private var untangleTask: Task<Void, Never>?

    /// Zip ties an untangling will delete, hidden while it runs.
    private(set) var untanglingTies: Set<ZipTie.ID> = []

    /// `model` as the canvas shows it: without the zip ties an untangling in progress will delete.
    func shown(_ model: DataModel) -> DataModel {
        guard !untanglingTies.isEmpty else { return model }
        var shown = model
        for tie in untanglingTies { shown.removeZipTie(tie) }
        return shown
    }

    /// Moves the selected tables (and selected groups'), step by step, toward where fewer wires cross, showing it as it
    /// goes; then saves where it got to as one change, deleting the zip ties in the selection and on the moved tables'
    /// wires, which the move leaves in the wrong places (hidden from the start). One undo puts it all back. Stopped,
    /// nothing changes.
    func untangleSelection(of model: Binding<DataModel>) {
        let start = model.wrappedValue
        let moving = selectedTablesAndMembers(in: start)
        guard !moving.isEmpty, untangleTask == nil else { return }
        let columns = Set(start.tables.filter { moving.contains($0.id) }.flatMap(\.columns).map(\.id))
        let wires = Set(start.relationships.filter { columns.contains($0.from) || columns.contains($0.to) }.map(\.id))
        let selectedTies = selectedTies
        untanglingTies = Set(start.zipTies.filter { selectedTies.contains($0.id) || $0.relationships.contains(where: wires.contains) }.map(\.id))
        let ties = untanglingTies
        untangleTask = Task {
            var untangler = Untangler(model: start, moving: moving)
            untangling = (untangler.startingCrossings, untangler.startingCrossings, 0)
            while !untangler.isDone && !Task.isCancelled {
                // As many steps as fit in a frame, then show them.
                let began = ProcessInfo.processInfo.systemUptime
                repeat { untangler.step() } while !untangler.isDone && ProcessInfo.processInfo.systemUptime - began < 0.008
                previewOffsets = untangler.offsets
                untangling = (untangler.startingCrossings, untangler.best.crossings, untangler.progress)
                try? await Task.sleep(for: .milliseconds(4))
            }
            let isFinished = !Task.isCancelled
            previewOffsets = [:]
            untangling = nil
            untangleTask = nil
            untanglingTies = []
            guard isFinished else { return }
            var untangled = model.wrappedValue
            // The tables moved only if that crosses fewer wires; the ties go either way.
            if untangler.best.crossings < untangler.startingCrossings {
                let offsets = untangler.bestOffsets
                for index in untangled.tables.indices {
                    if let offset = offsets[untangled.tables[index].id] { untangled.tables[index].position += offset }
                }
            }
            for tie in ties { untangled.removeZipTie(tie) }
            selection.subtract(ties.map { .zipTie($0) })
            model.wrappedValue = untangled
        }
    }

    /// Stops untangling, leaving everything as it was.
    func stopUntangling() {
        untangleTask?.cancel()
    }

    var isUntangling: Bool { untangleTask != nil }

    var tableOffsets: [Table.ID: CGPoint] {
        // Others' drags, under any here.
        let others = endedDrags.merging(othersDrags) { _, now in now }
        guard let dragOffset else { return others.merging(previewOffsets) { _, here in here } }
        return others.merging(selectedTables.map { ($0, dragOffset) }) { _, here in here }
    }

    /// Others' drags in a session, by table: shown moving, as a drag here is, before letting go makes them a change.
    private(set) var othersDrags: [Table.ID: CGPoint] = [:]
    /// Drags just let go of, still shown until their change lands, so the tables don't jump back meanwhile.
    private var endedDrags: [Table.ID: CGPoint] = [:]
    private var endedDragsTimeout: Task<Void, Never>?

    /// Shows what `peers` are dragging.
    func showDrags(of peers: some Sequence<Peer>) {
        var drags: [Table.ID: CGPoint] = [:]
        for peer in peers {
            guard let drag = peer.drag, drag.count == 2 else { continue }
            for id in (peer.selection ?? []).compactMap(UUID.init(uuidString:)) { drags[id] = CGPoint(x: drag[0], y: drag[1]) }
        }
        let ended = othersDrags.filter { drags[$0.key] == nil }
        if !ended.isEmpty {
            endedDrags.merge(ended) { _, new in new }
            // Let go of without a change (dropped where it began, or turned down): not shown for long.
            endedDragsTimeout?.cancel()
            endedDragsTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { self?.endedDrags = [:] }
            }
        }
        if drags != othersDrags { othersDrags = drags }
    }

    /// A change from someone else has landed: drags it ends are now in the model.
    func dragsLanded() {
        guard !endedDrags.isEmpty else { return }
        endedDrags = [:]
        endedDragsTimeout?.cancel()
    }
    var tieOffsets: [ZipTie.ID: CGPoint] { dragOffset.map { offset in Dictionary(uniqueKeysWithValues: selectedTies.map { ($0, offset) }) } ?? [:] }

    /// What a selection rectangle selects, given everything it touches. With tables, everything; without, ties take
    /// precedence over the wires through them (which are easy to catch by accident); with neither, the wires.
    static func boxSelection(tables: [Table.ID], ties: [ZipTie.ID], wires: [Relationship.ID], groups: [TableGroup.ID] = []) -> Set<Item> {
        let tables = tables.map(Item.table), ties = ties.map(Item.zipTie), wires = wires.map(Item.relationship)
        if !tables.isEmpty { return Set(tables + ties + wires + groups.map(Item.group)) }
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
            case .relationship(let id):
                // A port's bus is the port.
                if model.isBus(id) { model.removePort(id) } else { model.removeRelationships { $0.id == id } }
            case .zipTie(let id): model.removeZipTie(id)
            // Its tables go with it, being selected too; this is for one somehow left without.
            case .group(let id): model.ungroup(id)
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
