import SwiftUI

/// The infinite canvas: tables, the springy wires between their columns, and the zip ties that bundle them.
///
/// Pointer: drag empty canvas to select a group, Shift-click to add to it, and drag any selected item to move them all.
/// Scroll or hold Space and drag to pan; pinch or ⌘-scroll to zoom. Click a wire to select it; double-click to add a
/// bend point it runs through. Drag from a socket onto another column to add a foreign key, or onto a table to give it
/// a column for one. Right-drag (or Option-drag) across wires to zip-tie them. Double-click a cell to edit it.
///
/// Keyboard: T adds a table, Return edits the selected one, arrows nudge, Delete removes, ⌘A selects everything. While
/// editing, Tab and Shift-Tab step through cells, Return adds a column, Escape finishes.
struct CanvasView: View {
    @Binding var schema: Schema
    @Bindable var canvas: CanvasController

    @State private var simulation = WireSimulation()
    @State private var isAnimating = false
    /// The last click, to tell a double-click from two clicks.
    @State private var lastClick: (item: CanvasController.Item, time: TimeInterval)?
    @FocusState private var isCanvasFocused: Bool
    @FocusState private var field: CanvasController.Field?
    @AppStorage("wiresAvoidTables") private var wiresAvoidTables = false

    var body: some View {
        let routing = Routing(schema: schema, tableOffsets: canvas.tableOffsets, tieOffsets: canvas.tieOffsets,
                              avoidingTables: wiresAvoidTables)
        let colors = wireColors
        let foreignKeys = Dictionary(schema.relationships.compactMap { r in colors[r.id].map { (r.from, $0) } },
                                     uniquingKeysWith: { first, _ in first })
        let socketColors = socketColors(routing, colors: colors)
        ZStack(alignment: .topLeading) {
            GridLayer(zoom: canvas.zoom, offset: canvas.offset)
            wireLayer(routing, colors: colors)
            ForEach(schema.tables) { table in
                tableView(table, socketColors: socketColors, foreignKeys: foreignKeys)
            }
            ForEach(schema.zipTies) { tie in
                if let frame = routing.ties[tie.id] { tieHandle(tie, frame) }
            }
            gestureOverlay
            if canvas.isSpaceHeld { panSurface }
        }
        .coordinateSpace(.canvas)
        .clipped()
        .background { CanvasEventMonitor(canvas: canvas) }
        .onGeometryChange(for: CGSize.self, of: \.size) { canvas.resize(to: $0, fitting: schema.bounds) }
        .overlay {
            if schema.tables.isEmpty {
                ContentUnavailableView {
                    Label("No Tables", systemImage: "tablecells")
                } description: {
                    Text("Press T to add a table, then drag between column sockets to draw foreign keys.")
                } actions: {
                    Button("Add Table") { canvas.addTable(to: &schema) }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if canvas.editingTable != nil {
                EditingHints(togglePrimaryKey: togglePrimaryKey, deleteColumn: deleteFocusedColumn)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if canvas.showsPalette {
                // Clicking anywhere else closes it.
                Color.black.opacity(0.001)
                    .onTapGesture { canvas.showsPalette = false }
                    .overlay(alignment: .top) {
                        CommandPalette(commands: paletteCommands, highlight: $canvas.paletteHighlight) {
                            canvas.showsPalette = false
                        }
                        .padding(.top, 96)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.smooth(duration: 0.2), value: canvas.editingTable != nil)
        .animation(.smooth(duration: 0.15), value: canvas.showsPalette)
        .onChange(of: canvas.showsPalette) { if !canvas.showsPalette { isCanvasFocused = true } }
        .focusable()
        .focused($isCanvasFocused)
        .focusEffectDisabled()
        // Key presses reach these even while a cell has focus, so each checks that none does. (`isCanvasFocused` won't
        // do: it's true while anything inside the canvas has focus, cells included.)
        .onKeyPress("t") {
            guard isCanvasKeyTarget else { return .ignored }
            canvas.addTable(to: &schema)
            return .handled
        }
        .onKeyPress(.return) {
            guard isCanvasKeyTarget, canvas.selection.count == 1, case .table(let id)? = canvas.selection.first else { return .ignored }
            canvas.edit(.tableName(id))
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            guard isCanvasKeyTarget else { return .ignored }
            nudge(press)
            return .handled
        }
        .onCommand(#selector(NSText.selectAll(_:))) {
            canvas.selection = Set(schema.tables.map { .table($0.id) } + schema.zipTies.map { .zipTie($0.id) })
        }
        .onDeleteCommand { if isCanvasKeyTarget { canvas.deleteSelection(in: &schema) } }
        .onExitCommand { canvas.selection = [] }
        .onChange(of: canvas.requestedFocus) { _, requested in
            guard let requested else { return }
            canvas.editingTable = owner(of: requested)
            // The fields exist only once the table has redrawn as being edited.
            DispatchQueue.main.async {
                field = requested
                canvas.requestedFocus = nil
            }
        }
        .onChange(of: field) { old, new in
            if let new {
                canvas.editingTable = owner(of: new)
            } else if old != nil, canvas.requestedFocus == nil {
                finishEditing()
            }
        }
        .onChange(of: canvas.fieldKey) { _, key in
            guard let key else { return }
            canvas.fieldKey = nil
            step(key)
        }
        .onChange(of: canvas.isSpaceHeld) { if !canvas.isSpaceHeld { canvas.panOrigin = nil } }
        .onChange(of: canvas.isStrokeFinished) {
            guard canvas.isStrokeFinished else { return }
            canvas.isStrokeFinished = false
            finishStroke()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .click)) { note in
            if note.object as AnyObject? === canvas, let point = note.userInfo?["point"] as? CGPoint { click(at: point) }
        }
        #endif
    }

    // MARK: Command palette

    /// New Table first, then what applies to the selection, tools and view, then every table to jump to.
    private var paletteCommands: [PaletteCommand] {
        var commands = [PaletteCommand(id: "new-table", title: "New Table", symbol: "plus.rectangle", shortcut: "T") {
            canvas.addTable(to: &schema)
        }]
        if canvas.selection.count == 1, case .table(let id)? = canvas.selection.first, let table = schema.table(id) {
            commands += [
                PaletteCommand(id: "add-column", title: "Add Column", subtitle: table.name, symbol: "plus") {
                    addColumn(to: id, after: table.columns.last?.id)
                },
                PaletteCommand(id: "rename", title: "Rename Table", subtitle: table.name, symbol: "pencil", shortcut: "⏎") {
                    canvas.edit(.tableName(id))
                },
            ]
        }
        let tables = canvas.selectedTables
        if tables.count >= 2 {
            let count = "\(tables.count) tables"
            let alignments: [(String, String, Schema.Alignment)] = [
                ("Align Left Edges", "align.horizontal.left", .left), ("Align Centers", "align.horizontal.center", .center),
                ("Align Right Edges", "align.horizontal.right", .right), ("Align Top Edges", "align.vertical.top", .top),
                ("Align Middles", "align.vertical.center", .middle), ("Align Bottom Edges", "align.vertical.bottom", .bottom),
            ]
            commands += alignments.map { title, symbol, alignment in
                PaletteCommand(id: title, title: title, subtitle: count, symbol: symbol) { schema.align(tables, alignment) }
            }
        }
        if tables.count >= 3 {
            let count = "\(tables.count) tables"
            commands += [
                PaletteCommand(id: "distribute-h", title: "Distribute Horizontally", subtitle: count,
                               symbol: "distribute.horizontal.center") { schema.distribute(tables, horizontally: true) },
                PaletteCommand(id: "distribute-v", title: "Distribute Vertically", subtitle: count,
                               symbol: "distribute.vertical.center") { schema.distribute(tables, horizontally: false) },
            ]
        }
        if !canvas.selection.isEmpty {
            commands.append(PaletteCommand(id: "delete", title: "Delete Selection", symbol: "trash", shortcut: "⌫") {
                canvas.deleteSelection(in: &schema)
            })
        }
        commands += [
            PaletteCommand(id: "avoid", title: "Wires Avoid Tables", subtitle: wiresAvoidTables ? "On" : "Off",
                           symbol: "point.topleft.down.to.point.bottomright.curvepath") { wiresAvoidTables.toggle() },
            PaletteCommand(id: "select-all", title: "Select All", symbol: "checkmark.rectangle.stack", shortcut: "⌘A") {
                canvas.selection = Set(schema.tables.map { .table($0.id) } + schema.zipTies.map { .zipTie($0.id) })
            },
            PaletteCommand(id: "fit", title: "Zoom to Fit", symbol: "arrow.up.left.and.arrow.down.right", shortcut: "⌘1") {
                canvas.zoomToFit(schema.bounds)
            },
            PaletteCommand(id: "zoom-in", title: "Zoom In", symbol: "plus.magnifyingglass", shortcut: "⌘+") { canvas.zoom(by: 1.25) },
            PaletteCommand(id: "zoom-out", title: "Zoom Out", symbol: "minus.magnifyingglass", shortcut: "⌘−") { canvas.zoom(by: 0.8) },
            PaletteCommand(id: "actual-size", title: "Actual Size", symbol: "1.magnifyingglass", shortcut: "⌘0") {
                canvas.zoom(by: 1 / canvas.zoom)
            },
        ]
        commands += schema.tables.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { table in
            PaletteCommand(id: "table-\(table.id)", title: table.name, subtitle: "\(table.columns.count) columns", symbol: "tablecells") {
                canvas.selection = [.table(table.id)]
                canvas.center(on: Metrics.frame(of: table))
            }
        }
        return commands
    }

    /// Whether keys are for the canvas itself rather than a cell being edited.
    private var isCanvasKeyTarget: Bool { isCanvasFocused && field == nil }

    // MARK: Wires

    private func wireLayer(_ routing: Routing, colors: [Relationship.ID: Color]) -> some View {
        // Read here, not in the renderer, so changes redraw the canvas.
        let zoom = canvas.zoom, offset = canvas.offset, highlighted = highlightedRelationships
        let tieCrossings = canvas.stroke.map { Set(simulation.crossings(from: $0.start, to: $0.end).map(\.relationship)) } ?? []
        let selectedTies = canvas.selectedTies, hoveredTie = canvas.hoveredTie
        let selectedWires = Set(canvas.selection.compactMap { if case .relationship(let id) = $0 { id } else { nil } })
        let relationships = schema.relationships

        return TimelineView(.animation(paused: !isAnimating)) { timeline in
            Canvas { context, _ in
                let isMoving = simulation.advance(toward: routing.routes, to: timeline.date.timeIntervalSinceReferenceDate)
                if isMoving != isAnimating { Task { isAnimating = isMoving } }

                context.translateBy(x: offset.x, y: offset.y)
                context.scaleBy(x: zoom, y: zoom)
                // Highlighted wires last, so they're on top.
                let ordered = relationships.sorted { !(highlighted?.contains($0.id) ?? false) && (highlighted?.contains($1.id) ?? false) }
                for relationship in ordered {
                    guard let wire = simulation.wires[relationship.id] else { continue }
                    let path = Path(smoothing: wire.points)
                    let isDimmed = highlighted.map { !$0.contains(relationship.id) } ?? false
                    let color = tieCrossings.contains(relationship.id) ? Color.primary : colors[relationship.id] ?? .gray
                    context.stroke(path, with: .color(Theme.canvas), style: StrokeStyle(lineWidth: Metrics.tieSpacing, lineCap: .round))
                    if selectedWires.contains(relationship.id) {
                        context.stroke(path, with: .color(color.mix(with: .black, by: Theme.selectedWireDarkening)),
                                       style: StrokeStyle(lineWidth: Metrics.selectedWireWidth, lineCap: .round))
                    }
                    context.stroke(path, with: .color(color.opacity(isDimmed ? 0.28 : 1)),
                                   style: StrokeStyle(lineWidth: Metrics.wireWidth, lineCap: .round))
                }
                for (id, tie) in routing.ties {
                    drawTie(tie, id: id, isSelected: selectedTies.contains(id), isHovered: id == hoveredTie,
                            color: tie.relationships.first.flatMap { colors[$0] } ?? .gray,
                            relationships: relationships, in: context)
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture(coordinateSpace: .canvas) { location in click(at: canvas.canvasPoint(location)) }
        .gesture(backgroundDrag)
    }

    /// Drawn where its wires actually are, so it rides along as they spring into place. A bend point is a dot.
    private func drawTie(_ tie: Routing.Tie, id: ZipTie.ID, isSelected: Bool, isHovered: Bool, color: Color,
                         relationships: [Relationship], in context: GraphicsContext) {
        let slots = tie.relationships.compactMap { wireID -> CGPoint? in
            guard let wire = simulation.wires[wireID],
                  let index = relationships.first(where: { $0.id == wireID })?.zipTies.firstIndex(of: id) else { return nil }
            let sample = (index + 1) * Routing.samplesPerSegment
            return wire.points.indices.contains(sample) ? wire.points[sample] : nil
        }
        guard !slots.isEmpty else { return }
        var context = context
        let center = slots.reduce(.zero, +) / CGFloat(slots.count)
        context.translateBy(x: center.x, y: center.y)
        if tie.relationships.count == 1 {
            let radius = Metrics.bendPointDiameter / 2
            let dot = Path(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(isSelected ? Color.accentColor : Theme.card))
            context.stroke(dot, with: .color(isSelected ? Color.accentColor : color), lineWidth: isHovered ? 2.25 : 1.5)
            return
        }
        context.rotate(by: .radians(atan2(tie.direction.y, tie.direction.x)))
        let halfLength = Metrics.tieHalfLength(holding: tie.relationships.count)
        let band = CGRect(x: -Metrics.tieThickness / 2, y: -halfLength, width: Metrics.tieThickness, height: halfLength * 2)
        let shape = Path(roundedRect: band, cornerRadius: Metrics.tieThickness / 2)
        context.fill(shape, with: .color(isSelected ? Color.accentColor : isHovered ? Theme.tieHovered : Theme.tie))
        context.stroke(shape, with: .color(.black.opacity(0.18)), lineWidth: 0.5)
    }

    /// A wire takes the color of the table it references.
    private var wireColors: [Relationship.ID: Color] {
        let locations = schema.columnLocations
        return Dictionary(schema.relationships.compactMap { r in locations[r.to].map { (r.id, $0.table.color.color) } },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Sockets with wires take their wires' color; the rest have none.
    private func socketColors(_ routing: Routing, colors: [Relationship.ID: Color]) -> [Routing.Socket: Color] {
        var sockets: [Routing.Socket: Color] = [:]
        for (id, ends) in routing.sockets {
            sockets[ends.from] = sockets[ends.from] ?? colors[id]
            sockets[ends.to] = colors[id]
        }
        return sockets
    }

    /// The wires to show over the rest, which fade: those of whatever's selected. Nil highlights none.
    private var highlightedRelationships: Set<Relationship.ID>? {
        guard !canvas.selection.isEmpty else { return nil }
        let tables = canvas.selectedTables
        let columns = Set(schema.tables.filter { tables.contains($0.id) }.flatMap(\.columns).map(\.id))
        var wires = Set(schema.relationships.filter { columns.contains($0.from) || columns.contains($0.to) }.map(\.id))
        for item in canvas.selection {
            switch item {
            case .relationship(let id): wires.insert(id)
            case .zipTie(let id): wires.formUnion(schema.zipTies.first { $0.id == id }?.relationships ?? [])
            case .table: break
            }
        }
        return wires
    }

    // MARK: Tables

    private func tableView(_ table: Table, socketColors: [Routing.Socket: Color], foreignKeys: [Column.ID: Color]) -> some View {
        let offset = canvas.tableOffsets[table.id] ?? .zero
        let frame = Metrics.frame(of: table).offsetBy(dx: offset.x, dy: offset.y)
        let origin = canvas.viewPoint(frame.origin)
        let isEditing = canvas.editingTable == table.id
        return ZStack(alignment: .topLeading) {
            TableCard(table: binding(for: table.id), zoom: canvas.zoom,
                      isSelected: canvas.selection.contains(.table(table.id)) || canvas.connection?.target == .table(table.id),
                      isEditing: isEditing, targetColumn: targetColumn, foreignKeys: foreignKeys,
                      focus: $field, submit: submit)
                .position(x: origin.x + frame.width * canvas.zoom / 2, y: origin.y + frame.height * canvas.zoom / 2)
                // While editing, clicks belong to the cells.
                .gesture(itemGesture(.table(table.id)) { beginEditing(table, at: $0) }, including: isEditing ? .subviews : .all)
                .contextMenu { tableMenu(table) }
            ForEach(Array(table.columns.enumerated()), id: \.element.id) { row, column in
                ForEach(Side.allCases, id: \.self) { side in
                    let socket = Metrics.socket(row: row, side: side, in: frame)
                    Socket(color: socketColors[Routing.Socket(column: column.id, side: side)], zoom: canvas.zoom)
                        .position(canvas.viewPoint(socket))
                        .gesture(connectGesture(from: column, at: socket))
                        .help("Drag to another column to add a foreign key")
                }
            }
        }
    }

    /// The row a wire being dragged would connect to.
    private var targetColumn: Column.ID? {
        if case .column(let id)? = canvas.connection?.target { id } else { nil }
    }

    @ViewBuilder
    private func tableMenu(_ table: Table) -> some View {
        Button("Rename", systemImage: "pencil") { canvas.edit(.tableName(table.id)) }
        Button("Add Column", systemImage: "plus") { addColumn(to: table.id, after: table.columns.last?.id) }
        Picker("Color", selection: binding(for: table.id).color) {
            ForEach(TableColor.allCases) { color in
                Label(color.rawValue.capitalized, systemImage: "circle.fill")
                    .tint(color.color)
                    .tag(color)
            }
        }
        Divider()
        Button("Delete Table", systemImage: "trash", role: .destructive) { schema.removeTable(table.id) }
    }

    /// Looks the table up on every access, so a binding a text field holds after its table is deleted can't index past
    /// the end.
    private func binding(for id: Table.ID) -> Binding<Table> {
        Binding {
            schema.table(id) ?? Table(name: "", position: .zero, color: .blue)
        } set: { table in
            if let index = schema.tables.firstIndex(where: { $0.id == id }) { schema.tables[index] = table }
        }
    }

    /// Clicking selects, Shift-clicking adds; dragging moves everything selected; double-clicking calls `doubleClick`
    /// with where, in canvas points.
    private func itemGesture(_ item: CanvasController.Item, doubleClick: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .canvas)
            .onChanged { value in
                if canvas.dragOffset == nil {
                    isCanvasFocused = true
                    canvas.click(item, extending: NSEvent.modifierFlags.contains(.shift))
                }
                canvas.dragOffset = CGPoint(value.translation) / canvas.zoom
            }
            .onEnded { value in
                canvas.dragOffset = nil
                let delta = CGPoint(value.translation) / canvas.zoom
                if delta.length * canvas.zoom > 2 {
                    schema.move(tables: canvas.selectedTables, ties: canvas.selectedTies, by: delta)
                    lastClick = nil
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                if let last = lastClick, last.item == item, now - last.time < NSEvent.doubleClickInterval {
                    lastClick = nil
                    doubleClick(canvas.canvasPoint(value.location))
                } else {
                    lastClick = (item, now)
                }
            }
    }

    private func connectGesture(from column: Column, at socket: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .canvas)
            .onChanged { value in
                let end = canvas.canvasPoint(value.location)
                let target = schema.dropTarget(at: end).flatMap { $0 == .column(column.id) ? nil : $0 }
                canvas.connection = .init(from: column.id, start: socket, end: end, target: target)
            }
            .onEnded { _ in
                if let connection = canvas.connection, let target = connection.target,
                   let id = schema.connect(dragging: connection.from, onto: target) {
                    canvas.selection = [.relationship(id)]
                }
                canvas.connection = nil
            }
    }

    // MARK: Editing

    /// Edits the cell double-clicked; the key cell toggles the primary key instead.
    private func beginEditing(_ table: Table, at point: CGPoint) {
        let local = point - table.position
        let row = Int(((local.y - Metrics.headerHeight) / Metrics.rowHeight).rounded(.down))
        guard local.y >= Metrics.headerHeight, table.columns.indices.contains(row) else {
            return canvas.edit(.tableName(table.id))
        }
        let column = table.columns[row].id
        switch Metrics.gridColumn(atX: local.x) {
        case .key: togglePrimaryKey(column)
        case .name: canvas.edit(.columnName(column))
        case .type: canvas.edit(.columnType(column))
        }
    }

    /// Return: from the table's name to its first column, from a name to its type, from a type to a new column.
    private func submit(_ submitted: CanvasController.Field) {
        guard let tableID = owner(of: submitted), let table = schema.table(tableID) else { return }
        switch submitted {
        case .tableName:
            if let first = table.columns.first { field = .columnName(first.id) } else { addColumn(to: tableID, after: nil) }
        case .columnName(let id):
            field = .columnType(id)
        case .columnType(let id):
            addColumn(to: tableID, after: id)
        }
    }

    /// Tab and Shift-Tab through the table's cells in reading order; Tab past the last adds a column.
    private func step(_ key: CanvasController.FieldKey) {
        guard let current = field, let id = canvas.editingTable, let table = schema.table(id) else { return }
        let order = [CanvasController.Field.tableName(id)] + table.columns.flatMap { [.columnName($0.id), .columnType($0.id)] }
        let index = order.firstIndex(of: current) ?? 0
        switch key {
        case .next where index == order.count - 1: addColumn(to: id, after: table.columns.last?.id)
        case .next: field = order[index + 1]
        case .previous: field = order[max(index - 1, 0)]
        case .done: isCanvasFocused = true
        case .deleteColumn: deleteFocusedColumn()
        case .togglePrimaryKey: togglePrimaryKey()
        }
    }

    private func addColumn(to table: Table.ID, after column: Column.ID?) {
        if let id = schema.addColumn(to: table, after: column) { canvas.edit(.columnName(id)) }
    }

    /// The column whose cell has focus.
    private var focusedColumn: Column.ID? {
        switch field {
        case .columnName(let id), .columnType(let id): id
        default: nil
        }
    }

    private func togglePrimaryKey() {
        if let column = focusedColumn { togglePrimaryKey(column) }
    }

    private func togglePrimaryKey(_ column: Column.ID) {
        guard let (table, row) = schema.columnLocations[column],
              let index = schema.tables.firstIndex(where: { $0.id == table.id }) else { return }
        schema.tables[index].columns[row].isPrimaryKey.toggle()
    }

    /// Deletes the focused column and moves up to the cell above.
    private func deleteFocusedColumn() {
        guard let column = focusedColumn, let (table, row) = schema.columnLocations[column] else { return }
        field = row > 0 ? .columnName(table.columns[row - 1].id) : .tableName(table.id)
        schema.removeColumn(column)
    }

    /// Ends editing: columns left without a name are dropped.
    private func finishEditing() {
        guard let id = canvas.editingTable else { return }
        canvas.editingTable = nil
        for column in schema.table(id)?.columns ?? [] where column.name.trimmingCharacters(in: .whitespaces).isEmpty {
            schema.removeColumn(column.id)
        }
    }

    private func owner(of field: CanvasController.Field) -> Table.ID? {
        switch field {
        case .tableName(let id): id
        case .columnName(let id), .columnType(let id): schema.columnLocations[id]?.table.id
        }
    }

    // MARK: Zip ties and bend points

    private func tieHandle(_ tie: ZipTie, _ frame: Routing.Tie) -> some View {
        let isBendPoint = tie.relationships.count == 1
        let length = Metrics.tieHalfLength(holding: tie.relationships.count) * 2 + Metrics.socketHitRadius
        // Never smaller than a comfortable target on screen, however far out you've zoomed.
        return Color.clear
            .frame(width: max(Metrics.socketHitRadius * 2 * canvas.zoom, Metrics.minimumTarget),
                   height: max(length * canvas.zoom, Metrics.minimumTarget))
            .contentShape(.rect)
            .rotationEffect(.radians(atan2(frame.direction.y, frame.direction.x)))
            .position(canvas.viewPoint(frame.center))
            // Double-clicking a bend point straightens the wire again.
            .gesture(itemGesture(.zipTie(tie.id)) { _ in if isBendPoint { schema.removeZipTie(tie.id) } })
            .contextMenu {
                if isBendPoint {
                    Button("Remove Bend Point", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        schema.removeZipTie(tie.id)
                    }
                    Button("Delete Foreign Key", systemImage: "trash", role: .destructive) {
                        schema.removeRelationships { $0.id == tie.relationships[0] }
                    }
                } else {
                    Button("Cut Zip Tie", systemImage: "scissors", role: .destructive) { schema.removeZipTie(tie.id) }
                }
            }
            .onHover { isHovered in
                if isHovered { canvas.hoveredTie = tie.id } else if canvas.hoveredTie == tie.id { canvas.hoveredTie = nil }
            }
            .pointerStyle(canvas.dragOffset != nil && canvas.selection.contains(.zipTie(tie.id)) ? .grabActive : .grabIdle)
            .help(isBendPoint ? "Bend point: drag to reroute, double-click to remove" : "Zip tie: drag to move, Delete to cut")
    }

    // MARK: Empty canvas

    /// A click on empty canvas clears the selection. On a wire, selects it (Shift adds it), and a double-click adds a
    /// bend point there.
    private func click(at point: CGPoint) {
        isCanvasFocused = true
        let isExtending = NSEvent.modifierFlags.contains(.shift)
        guard let hit = simulation.hit(near: point, within: Metrics.wireHitRadius / canvas.zoom) else {
            if !isExtending { canvas.selection = [] }
            lastClick = nil
            return
        }
        let item = CanvasController.Item.relationship(hit.relationship)
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClick, last.item == item, now - last.time < NSEvent.doubleClickInterval,
           let bend = schema.addBendPoint(on: hit.relationship, at: hit.point, direction: hit.tangent, segment: hit.segment) {
            canvas.selection = [.zipTie(bend)]
            lastClick = nil
        } else {
            canvas.click(item, extending: isExtending)
            lastClick = (item, now)
        }
    }

    /// With Option, draws a line to tie wires (as a right-drag does, through the event monitor); otherwise drags out a
    /// selection rectangle.
    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .canvas)
            .onChanged { value in
                let start = canvas.canvasPoint(value.startLocation), now = canvas.canvasPoint(value.location)
                if canvas.backgroundDrag == nil {
                    isCanvasFocused = true
                    let flags = NSEvent.modifierFlags
                    if flags.contains(.option) {
                        canvas.backgroundDrag = .stroke
                    } else {
                        canvas.backgroundDrag = .marquee(base: flags.contains(.shift) ? canvas.selection : [])
                    }
                }
                switch canvas.backgroundDrag {
                case .stroke:
                    canvas.stroke = .init(start: start, end: now)
                case .marquee(let base):
                    let rect = CGRect(x: min(start.x, now.x), y: min(start.y, now.y), width: abs(now.x - start.x), height: abs(now.y - start.y))
                    canvas.marquee = rect
                    canvas.selection = base.union(items(in: rect))
                case nil:
                    break
                }
            }
            .onEnded { _ in
                switch canvas.backgroundDrag {
                case .stroke:
                    finishStroke()
                case .marquee, nil:
                    canvas.marquee = nil
                }
                canvas.backgroundDrag = nil
            }
    }

    /// What a selection rectangle picks up, of the tables and wires it touches and the ties inside it.
    private func items(in rect: CGRect) -> Set<CanvasController.Item> {
        CanvasController.boxSelection(
            tables: schema.tables.filter { Metrics.frame(of: $0).intersects(rect) }.map(\.id),
            ties: schema.zipTies.filter { rect.contains($0.position) }.map(\.id),
            wires: simulation.wires.filter { $0.value.points.contains(where: rect.contains) }.map(\.key))
    }

    private func finishStroke() {
        if let stroke = canvas.stroke, let tie = schema.zipTie(simulation, from: stroke.start, to: stroke.end) {
            canvas.selection = [.zipTie(tie)]
        }
        canvas.stroke = nil
    }

    /// While Space is held, covers everything so any drag pans.
    private var panSurface: some View {
        Color.clear
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .canvas)
                .onChanged { value in
                    let origin = canvas.panOrigin ?? canvas.offset
                    canvas.panOrigin = origin
                    canvas.pan(by: origin + CGPoint(value.translation) - canvas.offset)
                }
                .onEnded { _ in canvas.panOrigin = nil })
            .pointerStyle(canvas.panOrigin == nil ? .grabIdle : .grabActive)
    }

    /// Arrow keys move the selection a point, or ten with Shift.
    private func nudge(_ press: KeyPress) {
        let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
        let delta = switch press.key {
        case .upArrow: CGPoint(x: 0, y: -step)
        case .downArrow: CGPoint(x: 0, y: step)
        case .leftArrow: CGPoint(x: -step, y: 0)
        default: CGPoint(x: step, y: 0)
        }
        schema.move(tables: canvas.selectedTables, ties: canvas.selectedTies, by: delta)
    }

    // MARK: Overlay

    /// The wire being dragged out, the tie line and the selection rectangle, above the tables.
    private var gestureOverlay: some View {
        let zoom = canvas.zoom, offset = canvas.offset, connection = canvas.connection, stroke = canvas.stroke
        let marquee = canvas.marquee
        // Previews the color it'll take once dropped, and on a table, the column it'll add.
        let color = connection.map { connection in
            switch connection.target {
            case .column(let id)?: schema.columnLocations[id]?.table.color.color ?? Theme.socket
            case .table?: schema.columnLocations[connection.from]?.table.color.color ?? Theme.socket
            case nil: Theme.socket
            }
        }
        let newColumn: String? = if let connection, case .table(let id)? = connection.target {
            schema.newColumnName(referencing: connection.from, in: id)
        } else { nil }
        return Canvas { screen, _ in
            var context = screen
            context.translateBy(x: offset.x, y: offset.y)
            context.scaleBy(x: zoom, y: zoom)
            if let connection, let newColumn {
                // A tag by the pointer, at screen size whatever the zoom.
                let label = screen.resolve(Text("+ \(newColumn)").font(.callout.weight(.medium)).foregroundStyle(.white))
                let size = label.measure(in: CGSize(width: 400, height: 40))
                let origin = connection.end * zoom + offset + CGPoint(x: 14, y: -size.height - 14)
                let tag = CGRect(origin: origin, size: size).insetBy(dx: -8, dy: -4)
                screen.fill(Path(roundedRect: tag, cornerRadius: tag.height / 2), with: .color(.accentColor))
                screen.draw(label, in: CGRect(origin: origin, size: size))
            }
            if let connection, let color {
                let way = connection.end.x >= connection.start.x ? CGPoint(x: 1, y: 0) : CGPoint(x: -1, y: 0)
                let reach = max(abs(connection.end.x - connection.start.x) * 0.45, 36)
                var path = Path()
                path.move(to: connection.start)
                path.addCurve(to: connection.end, control1: connection.start + way * reach, control2: connection.end - way * reach)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: Metrics.wireWidth, lineCap: .round))
                let dot = Metrics.socketDiameter
                context.fill(Path(ellipseIn: CGRect(x: connection.end.x - dot / 2, y: connection.end.y - dot / 2, width: dot, height: dot)),
                             with: .color(color))
            }
            if let stroke {
                var path = Path()
                path.move(to: stroke.start)
                path.addLine(to: stroke.end)
                context.stroke(path, with: .color(Theme.stroke), style: StrokeStyle(lineWidth: 1.5 / zoom, lineCap: .round))
            }
            if let marquee {
                let shape = Path(marquee)
                context.fill(shape, with: .color(Color.accentColor.opacity(0.08)))
                context.stroke(shape, with: .color(Color.accentColor.opacity(0.7)), lineWidth: 1 / zoom)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Shortcuts while editing a table, in a capsule at the bottom of the canvas. The keys themselves are caught by the
/// event monitor; the ⌘ ones here are also buttons, for the mouse.
private struct EditingHints: View {
    let togglePrimaryKey: () -> Void
    let deleteColumn: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            hint("⇥", "Next")
            hint("⏎", "New column")
            Button(action: togglePrimaryKey) { hint("⇧⌘K", "Primary key") }
            Button(action: deleteColumn) { hint("⌘⌫", "Delete column") }
            hint("?", "Nullable")
            hint("⎋", "Done")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect()
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys).fontWeight(.semibold)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

/// Dots every 24 points, thinned out as you zoom out so they never crowd.
private struct GridLayer: View {
    let zoom: CGFloat
    let offset: CGPoint

    var body: some View {
        Canvas { context, size in
            var spacing = 24 * zoom
            while spacing < 12 { spacing *= 4 }
            let dot: CGFloat = 1.6
            var dots = Path()
            var x = offset.x.truncatingRemainder(dividingBy: spacing) - spacing
            while x < size.width + spacing {
                var y = offset.y.truncatingRemainder(dividingBy: spacing) - spacing
                while y < size.height + spacing {
                    dots.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    y += spacing
                }
                x += spacing
            }
            context.fill(dots, with: .color(Theme.gridDot))
        }
        .background(Theme.canvas)
        .allowsHitTesting(false)
    }
}

private extension Path {
    /// A smooth curve through the middle of each pair of points, bending at the points themselves.
    init(smoothing points: [CGPoint]) {
        self.init()
        guard let first = points.first, let last = points.last else { return }
        move(to: first)
        for (point, next) in zip(points.dropFirst(), points.dropFirst(2)) {
            addQuadCurve(to: (point + next) / 2, control: point)
        }
        addLine(to: last)
    }
}
