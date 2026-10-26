import SwiftUI

/// The infinite canvas: tables, the springy wires between their columns, and the zip ties that bundle them.
///
/// Pointer: drag empty canvas to select a group, Shift-click to add to it, and drag any selected item to move them all.
/// Scroll or hold Space and drag to pan; pinch or ⌘-scroll to zoom. Click a wire to select it; double-click to add a
/// bend point it runs through. Drag from a socket onto another column to add a foreign key, or onto a table to give it
/// a column for one. With the zip-tie tool (Z) or Option, drag across wires to zip-tie them. Right-drag pans; a
/// right-click opens the command wheel. Double-click a cell to edit it.
///
/// Keyboard: T adds a table, Return edits the selected one, arrows nudge, Delete removes, ⌘A selects everything. While
/// editing, Tab and Shift-Tab step through cells, Return adds a column, Escape finishes.
struct CanvasView: View {
    @Binding var model: DataModel
    @Bindable var canvas: CanvasController

    @State private var simulation = WireSimulation()
    @State private var isAnimating = false
    /// The last click, to tell a double-click from two clicks.
    @State private var lastClick: (item: CanvasController.Item, time: TimeInterval)?
    /// A selected item Shift-pressed: taken out of the selection if the press turns out to be a click, not a drag.
    @State private var deselectOnClick: CanvasController.Item?
    @FocusState private var isCanvasFocused: Bool
    @State private var routingCache = RoutingCache()
    @State private var textLayouts = TextLayouts()
    @State private var wirePaths = WirePaths()
    /// What the press on the canvas in progress landed on.
    @State private var press: Press?
    @State private var hoveredSocket: Routing.Socket?
    @AppStorage("wiresAvoidTables") private var wiresAvoidTables = false
    @AppStorage("showsMinimap") private var showsMinimap = true
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let routing = routingCache.routing(for: model, tableOffsets: canvas.tableOffsets, tieOffsets: canvas.tieOffsets,
                                           avoidingTables: wiresAvoidTables)
        let colors = routingCache.wireColors(for: model)
        let foreignKeys = Dictionary(model.relationships.compactMap { r in colors[r.id].map { (r.from, $0) } },
                                     uniquingKeysWith: { first, _ in first })
        let socketColors = socketColors(routing, colors: colors)
        let groupFrames = model.groups.compactMap { group in model.frame(of: group.id, offsets: canvas.tableOffsets).map { (group, $0) } }
        ZStack(alignment: .topLeading) {
            GridLayer(zoom: canvas.zoom, offset: canvas.offset)
            GroupLayer(groups: groupFrames, zoom: canvas.zoom, viewOffset: canvas.offset, selected: canvas.selectedGroups,
                       renaming: canvas.renamingGroup, focused: focusedTables.map { focused in
                           Set(model.tables.filter { focused.contains($0.id) }.compactMap(\.group))
                       })
            wireLayer(routing, colors: colors)
            tableLayer(socketColors: socketColors, foreignKeys: foreignKeys)
            ForEach(model.zipTies) { tie in
                if let frame = routing.ties[tie.id] { tieHandle(tie, frame) }
            }
            cellEditor
            groupNameEditor(groupFrames)
            gestureOverlay(routing)
            #if DEBUG
            if let edit = canvas.feedback { feedbackHandles(edit) }
            #endif
            if canvas.isSpaceHeld { panSurface }
        }
        .coordinateSpace(.canvas)
        .clipped()
        .background { CanvasEventMonitor(canvas: canvas) }
        .onGeometryChange(for: CGSize.self, of: \.size) { canvas.resize(to: $0, fitting: model.bounds) }
        .overlay {
            if model.tables.isEmpty {
                ContentUnavailableView {
                    Label("No Tables", systemImage: "tablecells")
                } description: {
                    Text("Press T to add a table, then drag between column sockets to draw foreign keys.")
                } actions: {
                    Button("Add Table") { canvas.addTable(to: &model) }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsMinimap, !model.tables.isEmpty, canvas.viewSize.width > 0 {
                let zoom = canvas.zoom
                Minimap(tables: model.tables,
                        groups: model.groups.compactMap { group in model.frame(of: group.id).map { (group, $0) } },
                        visible: CGRect(origin: CGPoint(x: -canvas.offset.x / zoom, y: -canvas.offset.y / zoom), size: canvas.viewSize * (1 / zoom))) {
                    canvas.center(on: CGRect(origin: $0, size: .zero))
                }
                .padding(16)
            }
        }
        .overlay(alignment: .bottom) {
            if canvas.cell != nil {
                GridHints { canvas.cellCommand = $0 }
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if let wheel = canvas.wheel {
                let contents = wheelContents(wheel)
                CommandWheel(center: wheel.center, slots: contents.slots, extras: contents.extras, color: contents.color) {
                    canvas.wheel = nil
                }
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
        #if DEBUG
        .overlay(alignment: .bottomLeading) { FrameReadout().padding(12) }
        .overlay(alignment: .bottom) {
            if canvas.isFeedbackMode {
                FeedbackBar(canvas: canvas, save: saveFeedback).padding(.bottom, 20)
            }
        }
        #endif
        .animation(.smooth(duration: 0.2), value: canvas.cell != nil)
        .animation(.smooth(duration: 0.15), value: canvas.showsPalette)
        .onChange(of: canvas.showsPalette) { if !canvas.showsPalette { isCanvasFocused = true } }
        // Opening a model puts the keys straight to work on it: T, Z and the rest, without a click first.
        .onAppear { isCanvasFocused = true }
        .focusable()
        .focused($isCanvasFocused)
        .focusEffectDisabled()
        // Key presses reach these even while a cell has focus, so each checks that none does. (`isCanvasFocused` won't
        // do: it's true while anything inside the canvas has focus, cells included.)
        // F turns focus mode on and off; ⇧F focuses on the selection instead.
        .onKeyPress(characters: CharacterSet(charactersIn: "fF")) { press in
            guard isCanvasKeyTarget, press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            if press.modifiers.contains(.shift) { canvas.focusOnSelection(in: model) } else { canvas.toggleFocus(in: model) }
            return .handled
        }
        .onKeyPress("z") {
            guard isCanvasKeyTarget else { return .ignored }
            canvas.isTying.toggle()
            return .handled
        }
        .onKeyPress("t") {
            guard isCanvasKeyTarget else { return .ignored }
            canvas.addTable(to: &model)
            return .handled
        }
        .onKeyPress(.return) {
            guard isCanvasKeyTarget, canvas.selection.count == 1, case .table(let id)? = canvas.selection.first else { return .ignored }
            canvas.edit(.name(of: id))
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            guard isCanvasKeyTarget else { return .ignored }
            nudge(press)
            return .handled
        }
        .onDeleteCommand { if isCanvasKeyTarget { canvas.deleteSelection(in: &model) } }

        .onExitCommand {
            #if DEBUG
            if canvas.feedback != nil { return canvas.feedback = nil }
            #endif
            if canvas.isTying { return canvas.isTying = false }
            canvas.selection = []
        }
        .onChange(of: canvas.cellCommand) { _, command in
            guard let command else { return }
            canvas.cellCommand = nil
            perform(command)
        }
        .onChange(of: canvas.editRequest) { _, request in
            guard let request else { return }
            canvas.editRequest = nil
            begin(request, replacingWith: nil, selectingAll: true)
        }
        // Focus on with nothing in it yet takes the first tables selected.
        .onChange(of: canvas.selection) {
            if canvas.focus?.isEmpty == true { canvas.focus = canvas.selectedTablesAndMembers(in: model) }
        }
        // Tables made in focus mode are in focus.
        .onChange(of: model.tables.map(\.id)) { old, new in
            guard canvas.focus != nil else { return }
            canvas.focus?.formUnion(Set(new).subtracting(old))
        }
        // Selecting something else takes the cursor off the table.
        .onChange(of: canvas.selection) {
            if let cell = canvas.cell, !canvas.selection.contains(.table(cell.table)) { leaveGrid() }
        }
        .onChange(of: canvas.wheelRequest) { _, request in
            guard let request else { return }
            canvas.wheelRequest = nil
            openWheel(at: request)
        }
        .onChange(of: canvas.isSpaceHeld) { if !canvas.isSpaceHeld { canvas.panOrigin = nil } }
        .onChange(of: canvas.isStrokeFinished) {
            guard canvas.isStrokeFinished else { return }
            canvas.isStrokeFinished = false
            finishStroke()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .saveFeedback)) { note in
            if note.object as AnyObject? === canvas { saveFeedback() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .holdDrag)) { note in
            guard note.object as AnyObject? === canvas, let id = note.userInfo?["table"] as? Table.ID,
                  let translation = note.userInfo?["translation"] as? CGSize else { return }
            dragItem(.table(id), by: translation)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { note in
            if note.object as AnyObject? === canvas { openSettings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pickFromWheel)) { note in
            guard note.object as AnyObject? === canvas, let wheel = canvas.wheel,
                  let direction = note.userInfo?["direction"] as? CommandWheel.Direction else { return }
            canvas.wheel = nil
            wheelContents(wheel).slots[direction]?.action()
        }
        .onReceive(NotificationCenter.default.publisher(for: .click)) { note in
            if note.object as AnyObject? === canvas, let point = note.userInfo?["point"] as? CGPoint { click(at: point) }
        }
        #endif
    }

    // MARK: Command palette

    /// New Table first, then what applies to the selection, tools and view, then every table to jump to.
    private var paletteCommands: [PaletteCommand] {
        var commands = [PaletteCommand(id: "new-table", title: "New Table", symbol: "plus.rectangle", shortcut: "T") {
            canvas.addTable(to: &model)
        }]
        if canvas.selection.count == 1, case .table(let id)? = canvas.selection.first, let table = model.table(id) {
            commands += [
                PaletteCommand(id: "add-column", title: "Add Column", subtitle: table.name, symbol: "plus") {
                    addColumn(to: id, after: table.columns.last?.id)
                },
                PaletteCommand(id: "rename", title: "Rename Table", subtitle: table.name, symbol: "pencil", shortcut: "⏎") {
                    canvas.edit(.name(of: id))
                },
            ]
        }
        let tables = canvas.selectedTables
        if let (aligned, ties) = canvas.alignable {
            let count = [(aligned.count, "table"), (ties.count, "tie")].filter { $0.0 > 0 }
                .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }.formatted()
            commands += DataModel.Alignment.allCases.map { alignment in
                PaletteCommand(id: alignment.title, title: alignment.title, subtitle: count, symbol: alignment.symbol) {
                    model.align(aligned, ties: ties, alignment)
                }
            }
        }
        if !tables.isEmpty {
            commands.append(PaletteCommand(id: "group", title: "Group Tables", subtitle: tables.count == 1 ? "1 table" : "\(tables.count) tables",
                                           symbol: "rectangle.dashed", shortcut: "⌘G") { canvas.groupSelection(in: &model) })
        }
        if !tables.isEmpty || !canvas.selectedGroups.isEmpty {
            commands.append(PaletteCommand(id: "focus-selection", title: "Focus on Selection", symbol: "scope", shortcut: "⇧F") {
                canvas.focusOnSelection(in: model)
            })
            if canvas.isFocusing {
                commands.append(PaletteCommand(id: "focus-add", title: "Add Selection to Focus", symbol: "plus.viewfinder") {
                    canvas.addSelectionToFocus(in: model)
                })
            }
        }
        if !canvas.selectedGroups.isEmpty {
            commands.append(PaletteCommand(id: "ungroup", title: "Ungroup", symbol: "rectangle.dashed", shortcut: "⇧⌘G") {
                canvas.ungroupSelection(in: &model)
            })
        }
        if model.tables.contains(where: { tables.contains($0.id) && $0.group != nil }) {
            commands.append(PaletteCommand(id: "ungroup-tables", title: "Remove from Group", symbol: "rectangle.dashed.badge.record") {
                canvas.removeSelectionFromGroups(in: &model)
            })
        }
        if tables.count >= 3 {
            let count = "\(tables.count) tables"
            commands += [
                PaletteCommand(id: "distribute-h", title: "Distribute Horizontally", subtitle: count,
                               symbol: "distribute.horizontal.center") { model.distribute(tables, horizontally: true) },
                PaletteCommand(id: "distribute-v", title: "Distribute Vertically", subtitle: count,
                               symbol: "distribute.vertical.center") { model.distribute(tables, horizontally: false) },
            ]
        }
        if !canvas.selection.isEmpty {
            commands.append(PaletteCommand(id: "delete", title: "Delete Selection", symbol: "trash", shortcut: "⌫") {
                canvas.deleteSelection(in: &model)
            })
        }
        commands += [
            PaletteCommand(id: "focus", title: "Focus Mode", subtitle: canvas.isFocusing ? "On" : "Off", symbol: "scope",
                           shortcut: "F") { canvas.toggleFocus(in: model) },
            PaletteCommand(id: "tie", title: "Zip Tie Tool", subtitle: canvas.isTying ? "On" : "Off",
                           symbol: "arrow.triangle.merge", shortcut: "Z") { canvas.isTying.toggle() },
            PaletteCommand(id: "avoid", title: "Wires Avoid Tables", subtitle: wiresAvoidTables ? "On" : "Off",
                           symbol: "point.topleft.down.to.point.bottomright.curvepath") { wiresAvoidTables.toggle() },
            PaletteCommand(id: "mcp", title: "Connect an AI Assistant", subtitle: "Settings", symbol: "sparkles") {
                openSettings()
            },
            PaletteCommand(id: "select-all", title: "Select All", symbol: "checkmark.rectangle.stack", shortcut: "⌘A") {
                canvas.selection = Set(model.tables.map { .table($0.id) } + model.zipTies.map { .zipTie($0.id) })
            },
            PaletteCommand(id: "fit", title: "Zoom to Fit", symbol: "arrow.up.left.and.arrow.down.right", shortcut: "⌘1") {
                canvas.zoomToFit(model.bounds)
            },
            PaletteCommand(id: "zoom-in", title: "Zoom In", symbol: "plus.magnifyingglass", shortcut: "⌘+") { canvas.zoom(by: 1.25) },
            PaletteCommand(id: "zoom-out", title: "Zoom Out", symbol: "minus.magnifyingglass", shortcut: "⌘−") { canvas.zoom(by: 0.8) },
            PaletteCommand(id: "actual-size", title: "Actual Size", symbol: "1.magnifyingglass", shortcut: "⌘0") {
                canvas.zoom(by: 1 / canvas.zoom)
            },
        ]
        #if DEBUG
        commands.append(PaletteCommand(id: "feedback", title: "Routing Feedback Mode", subtitle: canvas.isFeedbackMode ? "On" : "Off",
                                       symbol: "point.topleft.down.to.point.bottomright.curvepath", shortcut: "⌥⌘R") {
            canvas.isFeedbackMode.toggle()
            if !canvas.isFeedbackMode { canvas.feedback = nil }
        })
        #endif
        commands += model.tables.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { table in
            PaletteCommand(id: "table-\(table.id)", title: table.name, subtitle: "\(table.columns.count) columns", symbol: "tablecells") {
                canvas.selection = [.table(table.id)]
                canvas.center(on: Metrics.frame(of: table))
            }
        }
        return commands
    }

    // MARK: Command wheel

    /// Opens the wheel for whatever's under `viewPoint`. Right-clicking something not selected selects it alone, as in
    /// Finder; right-clicking empty canvas keeps the selection, so it can be aligned from anywhere.
    private func openWheel(at viewPoint: CGPoint) {
        isCanvasFocused = true
        let point = canvas.canvasPoint(viewPoint)
        let routing = routingCache.routing(for: model, tableOffsets: canvas.tableOffsets, tieOffsets: canvas.tieOffsets,
                                           avoidingTables: wiresAvoidTables)
        let reach = Metrics.wireHitRadius / canvas.zoom
        let target: CanvasController.Wheel.Target
        if let (id, _) = routing.ties.first(where: { _, tie in
            tie.center.distance(to: point) <= Metrics.tieHalfLength(holding: tie.relationships.count) + reach
        }) {
            target = .tie(id)
            if !canvas.selection.contains(.zipTie(id)) { canvas.selection = [.zipTie(id)] }
        } else if let table = model.tables.last(where: { Metrics.frame(of: $0).contains(point) }) {
            // Its header is the table; a row, that column.
            if case .column(let id) = cell(at: point, in: table).row { target = .column(id, in: table.id) } else { target = .table(table.id) }
            if !canvas.selection.contains(.table(table.id)) { canvas.selection = [.table(table.id)] }
        } else if let group = group(at: point) {
            target = .group(group)
            if !canvas.selection.contains(.group(group)) {
                canvas.selectGroup(group, in: model, extending: false)
            }
        } else if let hit = simulation.hit(near: point, within: reach) {
            target = .wire(hit)
            if !canvas.selection.contains(.relationship(hit.relationship)) { canvas.selection = [.relationship(hit.relationship)] }
        } else {
            target = .canvas
        }
        // Kept clear of the edges, so every label shows.
        let size = canvas.viewSize
        let center = CGPoint(x: min(max(viewPoint.x, 190), max(size.width - 190, 190)),
                             y: min(max(viewPoint.y, 110), max(size.height - 150, 110)))
        canvas.wheel = .init(center: center, point: point, target: target)
    }

    /// What the wheel offers. With two or more tables or ties selected, aligning, each way pointing where things go:
    /// left edges to the west, top edges to the north. Otherwise, what suits what was right-clicked.
    private func wheelContents(_ wheel: CanvasController.Wheel) -> (slots: [CommandWheel.Direction: PaletteCommand],
                                                                   extras: [PaletteCommand],
                                                                   color: (current: TableColor, set: (TableColor) -> Void)?) {
        let tables = canvas.selectedTables
        var slots: [CommandWheel.Direction: PaletteCommand] = [:], extras: [PaletteCommand] = []
        var color: (current: TableColor, set: (TableColor) -> Void)?
        let deleteSelection = PaletteCommand(id: "delete", title: "Delete", symbol: "trash", shortcut: "⌫", isDestructive: true) {
            canvas.deleteSelection(in: &model)
        }
        let groupSelection = PaletteCommand(id: "group", title: "Group", symbol: "rectangle.dashed", shortcut: "⌘G") {
            canvas.groupSelection(in: &model)
        }
        if let (aligned, ties) = canvas.alignable {
            let directions: [DataModel.Alignment: CommandWheel.Direction] = [.left: .west, .right: .east, .top: .north,
                                                                           .bottom: .south, .center: .northWest, .middle: .southWest]
            for (alignment, direction) in directions {
                slots[direction] = PaletteCommand(id: alignment.title, title: alignment.title, symbol: alignment.symbol) {
                    model.align(aligned, ties: ties, alignment)
                }
            }
            if tables.count >= 3 {
                slots[.northEast] = PaletteCommand(id: "distribute-h", title: "Distribute Horizontally",
                                                   symbol: "distribute.horizontal.center") { model.distribute(tables, horizontally: true) }
                slots[.southEast] = PaletteCommand(id: "distribute-v", title: "Distribute Vertically",
                                                   symbol: "distribute.vertical.center") { model.distribute(tables, horizontally: false) }
            }
            extras = [groupSelection, deleteSelection]
            return (slots, extras, nil)
        }
        switch wheel.target {
        case .table(let id):
            guard let table = model.table(id) else { break }
            slots[.north] = PaletteCommand(id: "rename", title: "Rename", symbol: "pencil", shortcut: "⏎") { canvas.edit(.name(of: id)) }
            slots[.east] = PaletteCommand(id: "add-column", title: "Add Column", symbol: "plus") {
                addColumn(to: id, after: table.columns.last?.id)
            }
            slots[.south] = PaletteCommand(id: "delete", title: "Delete Table", symbol: "trash", isDestructive: true) {
                model.removeTable(id)
            }
            color = (table.color, { binding(for: id).wrappedValue.color = $0 })
            if table.group != nil {
                slots[.west] = PaletteCommand(id: "ungroup-table", title: "Remove from Group", symbol: "rectangle.dashed.badge.record") {
                    canvas.removeSelectionFromGroups(in: &model)
                }
            } else {
                slots[.west] = groupSelection
            }
        case .group(let id):
            guard let group = model.groups.first(where: { $0.id == id }) else { break }
            slots[.north] = PaletteCommand(id: "rename-group", title: "Rename", symbol: "pencil") { canvas.renamingGroup = id }
            slots[.south] = PaletteCommand(id: "ungroup", title: "Ungroup", symbol: "rectangle.dashed", shortcut: "⇧⌘G") {
                canvas.ungroupSelection(in: &model)
            }
            extras = [deleteSelection]
            color = (group.color, { color in
                if let index = model.groups.firstIndex(where: { $0.id == id }) { model.groups[index].color = color }
            })
        case .column(let id, let tableID):
            guard let table = model.table(tableID), let column = table.columns.first(where: { $0.id == id }) else { break }
            func toggle(_ title: String, _ symbol: String, _ isOn: Bool, _ change: @escaping (inout Column) -> Void) -> PaletteCommand {
                PaletteCommand(id: title, title: title, subtitle: isOn ? "On" : "Off", symbol: symbol) { updateColumn(id, in: tableID, change) }
            }
            func edit(_ part: Metrics.GridColumn) {
                canvas.cell = CanvasController.Cell(table: tableID, row: .column(id), part: part)
                begin(canvas.cell!, replacingWith: nil, selectingAll: true)
            }
            slots[.west] = toggle("Primary Key", "key", column.isPrimaryKey) { $0.isPrimaryKey.toggle() }
            slots[.north] = toggle("Required", "asterisk", !column.isNullable) { $0.isNullable.toggle() }
            slots[.east] = toggle("Unique", "1.circle", column.isUnique) { $0.isUnique.toggle() }
            slots[.northWest] = PaletteCommand(id: "rename-column", title: "Rename Column", symbol: "pencil") { edit(.name) }
            slots[.northEast] = PaletteCommand(id: "edit-type", title: "Change Type", symbol: "textformat") { edit(.type) }
            slots[.southEast] = PaletteCommand(id: "insert-column", title: "Insert Column Below", symbol: "plus") {
                addColumn(to: tableID, after: id)
            }
            slots[.south] = PaletteCommand(id: "delete-column", title: "Delete Column", symbol: "trash", isDestructive: true) {
                deleteColumn(at: CanvasController.Cell(table: tableID, row: .column(id), part: .name))
            }
            color = (table.color, { binding(for: tableID).wrappedValue.color = $0 })
        case .tie(let id):
            guard let tie = model.zipTies.first(where: { $0.id == id }) else { break }
            if tie.relationships.count == 1 {
                slots[.north] = PaletteCommand(id: "remove-bend", title: "Remove Bend Point",
                                               symbol: "point.topleft.down.to.point.bottomright.curvepath") { model.removeZipTie(id) }
                slots[.south] = PaletteCommand(id: "delete-key", title: "Delete Foreign Key", symbol: "trash", isDestructive: true) {
                    model.removeRelationships { $0.id == tie.relationships[0] }
                }
            } else {
                slots[.south] = PaletteCommand(id: "cut", title: "Cut Zip Tie", symbol: "scissors", isDestructive: true) {
                    model.removeZipTie(id)
                }
                if tie.heldDirection != nil {
                    slots[.north] = PaletteCommand(id: "turn", title: "Turn with Wires", symbol: "arrow.triangle.2.circlepath") { release(id) }
                }
            }
        case .wire(let hit):
            slots[.north] = PaletteCommand(id: "bend", title: "Add Bend Point", symbol: "point.topleft.down.to.point.bottomright.curvepath") {
                if let bend = model.addBendPoint(on: hit.relationship, at: hit.point, direction: hit.tangent, segment: hit.segment) {
                    canvas.selection = [.zipTie(bend)]
                }
            }
            slots[.south] = PaletteCommand(id: "delete-key", title: "Delete Foreign Key", symbol: "trash", isDestructive: true) {
                model.removeRelationships { $0.id == hit.relationship }
            }
        case .canvas:
            slots[.north] = PaletteCommand(id: "new-table", title: "New Table", symbol: "plus.rectangle", shortcut: "T") {
                canvas.addTable(to: &model, at: wheel.point)
            }
            slots[.east] = PaletteCommand(id: "fit", title: "Zoom to Fit", symbol: "arrow.up.left.and.arrow.down.right") {
                canvas.zoomToFit(model.bounds)
            }
            slots[.west] = PaletteCommand(id: "select-all", title: "Select All", symbol: "checkmark.rectangle.stack") {
                canvas.selection = Set(model.tables.map { .table($0.id) } + model.zipTies.map { .zipTie($0.id) })
            }
            slots[.south] = PaletteCommand(id: "palette", title: "All Commands", symbol: "command", shortcut: "⌘K") {
                canvas.togglePalette()
            }
            slots[.northEast] = PaletteCommand(id: "avoid", title: "Wires Avoid Tables", subtitle: wiresAvoidTables ? "On" : "Off",
                                               symbol: "point.topleft.down.to.point.bottomright.curvepath") { wiresAvoidTables.toggle() }
            if !canvas.selection.isEmpty { extras = [deleteSelection] }
        }
        return (slots, extras, color)
    }

    /// Whether keys are for the canvas itself rather than a cell being edited, a group being named or the palette's search.
    private var isCanvasKeyTarget: Bool {
        isCanvasFocused && !canvas.isEditingCell && !canvas.showsPalette && canvas.renamingGroup == nil
    }

    // MARK: Wires

    private func wireLayer(_ routing: Routing, colors: [Relationship.ID: Color]) -> some View {
        // Read here, not in the renderer, so changes redraw the canvas.
        let zoom = canvas.zoom, offset = canvas.offset, highlighted = highlightedRelationships
        // In focus mode, ties none of whose wires are in focus fade with them.
        let isFocused = focusedTables != nil
        let tieCrossings = canvas.stroke.map { Set(simulation.crossings(from: $0.start, to: $0.end).map(\.relationship)) } ?? []
        let selectedTies = canvas.selectedTies, hoveredTie = canvas.hoveredTie
        let selectedWires = Set(canvas.selection.compactMap { if case .relationship(let id) = $0 { id } else { nil } })
        let relationships = model.relationships

        return TimelineView(.animation(paused: !isAnimating)) { timeline in
            Canvas { context, _ in
                #if DEBUG
                let start = ProcessInfo.processInfo.systemUptime
                defer { FrameMeter.shared.drew(in: (ProcessInfo.processInfo.systemUptime - start) * 1000) }
                #endif
                let isMoving = simulation.advance(toward: routing.routes, to: timeline.date.timeIntervalSinceReferenceDate)
                if isMoving != isAnimating { Task { isAnimating = isMoving } }

                context.translateBy(x: offset.x, y: offset.y)
                context.scaleBy(x: zoom, y: zoom)
                // Highlighted wires last, so they're on top.
                let ordered = relationships.sorted { !(highlighted?.contains($0.id) ?? false) && (highlighted?.contains($1.id) ?? false) }
                for relationship in ordered {
                    guard let wire = simulation.wires[relationship.id] else { continue }
                    let path = wirePaths.path(for: relationship.id, through: wire.points)
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
                            isFaded: isFocused && !tie.relationships.contains { highlighted?.contains($0) == true },
                            relationships: relationships, in: context)
                }
            }
        }
        // Presses go to the table layer above, which covers the canvas.
        .allowsHitTesting(false)
    }

    /// Drawn where its wires actually are, so it rides along as they spring into place. A bend point is a dot.
    private func drawTie(_ tie: Routing.Tie, id: ZipTie.ID, isSelected: Bool, isHovered: Bool, color: Color, isFaded: Bool,
                         relationships: [Relationship], in context: GraphicsContext) {
        let slots = tie.relationships.compactMap { wireID -> CGPoint? in
            guard let wire = simulation.wires[wireID],
                  let index = relationships.first(where: { $0.id == wireID })?.zipTies.firstIndex(of: id) else { return nil }
            let sample = (index + 1) * Routing.samplesPerSegment
            return wire.points.indices.contains(sample) ? wire.points[sample] : nil
        }
        guard !slots.isEmpty else { return }
        var context = context
        if isFaded { context.opacity = TableLayer.fadedOpacity }
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
        // In focus mode, the wires among the tables in focus.
        if let focused = focusedTables { return model.relationships(among: focused) }
        guard !canvas.selection.isEmpty else { return nil }
        let tables = canvas.selectedTables
        let columns = Set(model.tables.filter { tables.contains($0.id) }.flatMap(\.columns).map(\.id))
        var wires = Set(model.relationships.filter { columns.contains($0.from) || columns.contains($0.to) }.map(\.id))
        for item in canvas.selection {
            switch item {
            case .relationship(let id): wires.insert(id)
            case .zipTie(let id): wires.formUnion(model.zipTies.first { $0.id == id }?.relationships ?? [])
            case .table, .group: break
            }
        }
        return wires
    }

    // MARK: Tables

    /// In focus mode: the tables in focus and every table a foreign key joins them to; everything else fades. Nil while
    /// focus is off, or on with nothing chosen yet.
    private var focusedTables: Set<Table.ID>? {
        guard let focus = canvas.focus, !focus.isEmpty else { return nil }
        return model.neighborhood(of: focus)
    }

    /// Every table, and the presses on them and on the empty canvas around them.
    private func tableLayer(socketColors: [Routing.Socket: Color], foreignKeys: [Column.ID: Color]) -> some View {
        var selected = canvas.selectedTables
        if case .table(let id)? = canvas.connection?.target { selected.insert(id) }
        return TableLayer(tables: model.tables, offsets: canvas.tableOffsets, zoom: canvas.zoom, viewOffset: canvas.offset,
                          viewSize: canvas.viewSize, selected: selected, cursor: canvas.cell, targetColumn: targetColumn,
                          foreignKeys: foreignKeys, socketColors: socketColors, hoveredSocket: hoveredSocket, layouts: textLayouts,
                          focused: focusedTables)
            .contentShape(.rect)
            .gesture(surfaceGesture)
            .onContinuousHover { phase in
                var socket: Routing.Socket?
                if case .active(let location) = phase { socket = self.socket(at: canvas.canvasPoint(location))?.socket }
                if socket != hoveredSocket { hoveredSocket = socket }
            }
            .pointerStyle(canvas.isTying ? .rectSelection : hoveredSocket == nil ? nil : .link)
            .help(hoveredSocket == nil ? "" : "Drag to another column to add a foreign key")
    }

    /// What a press on the canvas is for, from where it started.
    enum Press {
        /// Drawing a foreign key out of a column's socket.
        case socket(Column, at: CGPoint)
        case table(Table)
        /// On a group's name: selecting and moving the group.
        case group(TableGroup.ID)
        case background
    }

    private func press(at point: CGPoint) -> Press {
        if let (column, socket, _) = socket(at: point) { return .socket(column, at: socket) }
        if let table = model.tables.last(where: { Metrics.frame(of: $0).contains(point) }) { return .table(table) }
        if let group = group(at: point) { return .group(group) }
        return .background
    }

    /// The group whose name band is under `point`, in canvas points; the last drawn, if they overlap.
    private func group(at point: CGPoint) -> TableGroup.ID? {
        model.groups.last { group in model.frame(of: group.id).map { GroupLayer.labelBand(of: $0).contains(point) } == true }?.id
    }

    /// The socket within reach of `point`, in canvas points, with its column and center.
    private func socket(at point: CGPoint) -> (column: Column, center: CGPoint, socket: Routing.Socket)? {
        let reach = Metrics.socketReach(zoom: canvas.zoom)
        for table in model.tables.reversed() {
            let frame = Metrics.frame(of: table)
            guard frame.insetBy(dx: -reach, dy: -reach).contains(point) else { continue }
            let row = Int(((point.y - frame.minY - Metrics.headerHeight) / Metrics.rowHeight).rounded(.down))
            guard table.columns.indices.contains(row) else { continue }
            for side in Side.allCases {
                let center = Metrics.socket(row: row, side: side, in: frame)
                if center.distance(to: point) <= reach {
                    return (table.columns[row], center, Routing.Socket(column: table.columns[row].id, side: side))
                }
            }
        }
        return nil
    }

    /// One gesture for the whole canvas, which does what suits where the press started: from a socket it draws a
    /// foreign key; on a table it selects, moves, or picks a cell; on empty canvas it selects with a rectangle, ties
    /// with Option, or clicks what's there.
    private var surfaceGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .canvas)
            .onChanged { value in
                // With the zip-tie tool, every drag ties, wherever it starts.
                let press = self.press ?? (canvas.isTying ? .background : self.press(at: canvas.canvasPoint(value.startLocation)))
                if self.press == nil { self.press = press }
                switch press {
                case .socket(let column, let socket):
                    // A short way first, so a click on a socket doesn't start a wire.
                    guard canvas.connection != nil || CGPoint(value.translation).length >= 2 else { return }
                    dragConnection(from: column, at: socket, to: canvas.canvasPoint(value.location))
                case .table(let table):
                    dragItem(.table(table.id), by: value.translation)
                case .group(let id):
                    dragItem(.group(id), by: value.translation)
                case .background:
                    dragBackground(from: value.startLocation, to: value.location)
                }
            }
            .onEnded { value in
                let press = self.press ?? .background
                self.press = nil
                switch press {
                case .socket:
                    finishConnection()
                case .table(let table):
                    dropItem(.table(table.id), at: value.location, translation: value.translation,
                             click: { selectCell(at: $0, in: table) }) { doubleClickCell(at: $0, in: table) }
                case .group(let id):
                    // A double-click on its name renames it.
                    dropItem(.group(id), at: value.location, translation: value.translation, click: nil) { _ in canvas.renamingGroup = id }
                case .background:
                    if canvas.backgroundDrag == nil { click(at: canvas.canvasPoint(value.location)) } else { finishBackgroundDrag() }
                }
            }
    }

    /// A group's name being edited, in place of its label: Return or clicking away keeps it, Escape doesn't.
    @ViewBuilder
    private func groupNameEditor(_ frames: [(TableGroup, CGRect)]) -> some View {
        if let id = canvas.renamingGroup, let (group, frame) = frames.first(where: { $0.0.id == id }) {
            let zoom = canvas.zoom
            let origin = GroupLayer.labelOrigin(of: frame) * zoom + canvas.offset
            let width = max(160, (frame.width - Metrics.groupPadding * 2) * zoom)
            RenameField(name: group.name) { name in
                canvas.renamingGroup = nil
                let name = name?.trimmingCharacters(in: .whitespaces) ?? ""
                if !name.isEmpty, let index = model.groups.firstIndex(where: { $0.id == id }) { model.groups[index].name = name }
            }
            .textFieldStyle(.plain)
            .font(GroupLayer.labelFont(zoom: zoom))
            .foregroundStyle(group.color.color)
            .frame(width: width, height: 22 * max(zoom, 0.6))
            .position(x: origin.x + width / 2, y: origin.y)
        }
    }

    private func textStyle(of cell: CanvasController.Cell, row: Int?, in table: Table) -> TableText {
        guard let row else { return .header }
        return cell.part == .type ? .type : table.columns[row].isPrimaryKey ? .keyName : .name
    }

    /// The cell being edited: a text field over its place in the table, in the same type, inside the grid cursor, with
    /// the cell's own background hiding the text it replaces.
    @ViewBuilder
    private var cellEditor: some View {
        if canvas.isEditingCell, let cell = canvas.cell, let table = model.table(cell.table) {
            let offset = canvas.tableOffsets[table.id] ?? .zero
            let row: Int? = if case .column(let id) = cell.row { table.columns.firstIndex { $0.id == id } } else { nil }
            let zoom = canvas.zoom
            // Inside the cursor's border (see `TableLayer`).
            let inset = 1 + max(2 * zoom, 1.5)
            let rect = Metrics.cell(row: row, part: cell.part, in: Metrics.frame(of: table).offsetBy(dx: offset.x, dy: offset.y))
            CellEditor(text: $canvas.draft, selectsAll: canvas.selectsAllDraft, completesTypes: cell.part == .type) {
                canvas.cellCommand = .commit(then: nil)
            }
            .font(textStyle(of: cell, row: row, in: table).swiftUIFont(zoom: zoom))
            .foregroundStyle(cell.part == .type ? .secondary : .primary)
            .lineLimit(1)
            .padding(.horizontal, Metrics.cellInset * zoom - inset)
            .frame(width: rect.width * zoom - inset * 2, height: rect.height * zoom - inset * 2, alignment: .leading)
            .background(row == nil ? table.color.headerFill : Theme.card)
            .position(canvas.viewPoint(CGPoint(x: rect.midX, y: rect.midY)))
        }
    }

    /// Lets a tie lined up with others turn with its wires again.
    private func release(_ tie: ZipTie.ID) {
        if let index = model.zipTies.firstIndex(where: { $0.id == tie }) { model.zipTies[index].heldDirection = nil }
    }

    /// The row a wire being dragged would connect to.
    private var targetColumn: Column.ID? {
        if case .column(let id)? = canvas.connection?.target { id } else { nil }
    }

    /// Looks the table up on every access, so a binding a text field holds after its table is deleted can't index past
    /// the end.
    private func binding(for id: Table.ID) -> Binding<Table> {
        Binding {
            model.table(id) ?? Table(name: "", position: .zero, color: .blue)
        } set: { table in
            if let index = model.tables.firstIndex(where: { $0.id == id }) { model.tables[index] = table }
        }
    }

    /// Clicking selects, Shift-clicking adds; dragging moves everything selected. A click (without a drag) also calls
    /// `click`, and a double-click `doubleClick`, with where, in canvas points.
    private func itemGesture(_ item: CanvasController.Item, doubleClick: @escaping (CGPoint) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .canvas)
            .onChanged { dragItem(item, by: $0.translation) }
            .onEnded { dropItem(item, at: $0.location, translation: $0.translation, click: nil, doubleClick: doubleClick) }
    }

    /// Pressing selects the item; dragging moves the selection, held to one axis while Shift is down. Shift-pressing
    /// adds an item to the selection at once, but takes a selected one out only on a click (see `dropItem`), so a
    /// Shift-drag doesn't drop what it's moving.
    private func dragItem(_ item: CanvasController.Item, by translation: CGSize) {
        let isShifted = NSEvent.modifierFlags.contains(.shift)
        if canvas.dragOffset == nil {
            isCanvasFocused = true
            if case .group(let id) = item, !canvas.selection.contains(item) {
                canvas.selectGroup(id, in: model, extending: isShifted)
            } else if isShifted && canvas.selection.contains(item) {
                deselectOnClick = item
            } else {
                canvas.click(item, extending: isShifted)
            }
        }
        (canvas.dragOffset, canvas.guides) = move(by: translation)
    }

    /// How far a drag of `translation` (view points) moves the selection: held to one axis with Shift, and snapped into
    /// line with other tables unless ⌘ is down; with the guides that show the line-ups.
    private func move(by translation: CGSize) -> (offset: CGPoint, guides: [CanvasController.Guide]) {
        let flags = NSEvent.modifierFlags
        let offset = CanvasController.moveOffset(CGPoint(translation) / canvas.zoom, isAxisLocked: flags.contains(.shift))
        let selected = canvas.selectedTables
        guard !selected.isEmpty, !flags.contains(.command) else { return (offset, []) }
        let moving = model.tables.filter { selected.contains($0.id) }.map(Metrics.frame)
        let others = model.tables.filter { !selected.contains($0.id) }.map(Metrics.frame)
        // With Shift, only along the way it's moving.
        let isLocked = flags.contains(.shift)
        return CanvasController.snap(moving, by: offset, to: others, tolerance: 6 / canvas.zoom,
                                     across: !isLocked || offset.x != 0, down: !isLocked || offset.y != 0)
    }

    /// Ends a move, or if it hardly moved, a click (or double-click) at `location`, in view points.
    private func dropItem(_ item: CanvasController.Item, at location: CGPoint, translation: CGSize,
                          click: ((CGPoint) -> Void)?, doubleClick: (CGPoint) -> Void) {
        canvas.dragOffset = nil
        canvas.guides = []
        defer { deselectOnClick = nil }
        let delta = move(by: translation).offset
        if CGPoint(translation).length > 2 {
            // One change: moved, and into any group dropped in.
            var moved = model
            moved.move(tables: canvas.selectedTables, ties: canvas.selectedTies, by: delta)
            moved.regroup(canvas.selectedTables)
            model = moved
            lastClick = nil
            return
        }
        if deselectOnClick == item {
            canvas.selection.remove(item)
            // A group goes with its tables.
            if case .group(let id) = item {
                canvas.selection.subtract(model.members(of: id).map { .table($0.id) } + model.ties(in: id).map { .zipTie($0) })
            }
            return
        }
        click?(canvas.canvasPoint(location))
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClick, last.item == item, now - last.time < NSEvent.doubleClickInterval {
            lastClick = nil
            doubleClick(canvas.canvasPoint(location))
        } else {
            lastClick = (item, now)
        }
    }

    private func dragConnection(from column: Column, at socket: CGPoint, to end: CGPoint) {
        let target = model.dropTarget(at: end).flatMap { $0 == .column(column.id) ? nil : $0 }
        canvas.connection = .init(from: column.id, start: socket, end: end, target: target)
    }

    private func finishConnection() {
        if let connection = canvas.connection, let target = connection.target,
           let id = model.connect(dragging: connection.from, onto: target) {
            canvas.selection = [.relationship(id)]
        }
        canvas.connection = nil
    }

    // MARK: The grid

    /// Which cell of `table` is under `point`, in canvas points.
    private func cell(at point: CGPoint, in table: Table) -> CanvasController.Cell {
        let local = point - table.position
        let row = Int(((local.y - Metrics.headerHeight) / Metrics.rowHeight).rounded(.down))
        guard local.y >= Metrics.headerHeight, table.columns.indices.contains(row) else { return .name(of: table.id) }
        return CanvasController.Cell(table: table.id, row: .column(table.columns[row].id), part: Metrics.gridColumn(atX: local.x))
    }

    private func selectCell(at point: CGPoint, in table: Table) {
        commitDraft()
        canvas.cell = cell(at: point, in: table)
    }

    /// Double-clicking a cell edits it with its text selected; on a key cell, it toggles the primary key.
    private func doubleClickCell(at point: CGPoint, in table: Table) {
        let target = cell(at: point, in: table)
        guard target.part != .key else { return togglePrimaryKey(target) }
        begin(target, replacingWith: nil, selectingAll: true)
    }

    private func perform(_ command: CanvasController.CellCommand) {
        guard let cell = canvas.cell else { return }
        switch command {
        case .move(let move):
            moveCursor(move)
        case .edit(let replacement):
            if cell.part != .key { begin(cell, replacingWith: replacement) } else if replacement == nil { togglePrimaryKey(cell) }
        case .commit(let move):
            commitDraft()
            if let move { moveCursor(move) }
        case .cancel:
            canvas.isEditingCell = false
            isCanvasFocused = true
        case .clear:
            if cell.part == .key { setPrimaryKey(cell, to: false) } else { begin(cell, replacingWith: "") }
        case .space:
            if cell.part == .key { togglePrimaryKey(cell) } else { begin(cell, replacingWith: " ") }
        case .insertColumn:
            if case .column(let id) = cell.row { addColumn(to: cell.table, after: id) } else { addColumn(to: cell.table, after: nil) }
        case .deleteColumn:
            deleteColumn(at: cell)
        case .toggleKey:
            togglePrimaryKey(cell)
        case .toggleUnique:
            if case .column(let id) = cell.row { updateColumn(id, in: cell.table) { $0.isUnique.toggle() } }
        case .toggleRequired:
            if case .column(let id) = cell.row { updateColumn(id, in: cell.table) { $0.isNullable.toggle() } }
        case .leave:
            leaveGrid()
        }
    }

    /// Moves the cursor; Tab or Return past the last row goes on into a new column.
    private func moveCursor(_ move: CanvasController.CellMove) {
        guard let cell = canvas.cell, let table = model.table(cell.table) else { return }
        isCanvasFocused = true
        if let next = CanvasController.cell(after: cell, move, in: table) {
            canvas.cell = next
        } else if move == .next || move == .downOrNew {
            addColumn(to: table.id, after: table.columns.last?.id)
        }
    }

    /// Starts editing `cell`, its text replaced by `replacement` (typing over it) or kept.
    private func begin(_ cell: CanvasController.Cell, replacingWith replacement: String?, selectingAll: Bool = false) {
        guard cell.part != .key else { return }
        commitDraft()
        canvas.cell = cell
        canvas.draft = replacement ?? text(of: cell)
        canvas.selectsAllDraft = replacement == nil && selectingAll
        canvas.isEditingCell = true
    }

    private func text(of cell: CanvasController.Cell) -> String {
        guard let table = model.table(cell.table) else { return "" }
        guard case .column(let id) = cell.row else { return table.name }
        guard let column = table.columns.first(where: { $0.id == id }) else { return "" }
        return cell.part == .type ? column.typeLabel : column.name
    }

    /// Puts what was typed into the model, as one change (one undo). A type is read as typed ("int?", "ts"), and
    /// left as it was if it reads as nothing; a table keeps its name rather than lose it.
    private func commitDraft() {
        guard canvas.isEditingCell else { return }
        canvas.isEditingCell = false
        isCanvasFocused = true
        guard let cell = canvas.cell, let index = model.tables.firstIndex(where: { $0.id == cell.table }) else { return }
        let text = canvas.draft.trimmingCharacters(in: .whitespaces)
        guard case .column(let id) = cell.row else {
            if !text.isEmpty, text != model.tables[index].name { model.tables[index].name = text }
            return
        }
        guard let row = model.tables[index].columns.firstIndex(where: { $0.id == id }) else { return }
        var column = model.tables[index].columns[row]
        if cell.part == .type {
            guard let parsed = DataType.parse(text) else { return }
            (column.type, column.isNullable) = (parsed.type, parsed.isNullable)
        } else {
            column.name = text
        }
        if column != model.tables[index].columns[row] { model.tables[index].columns[row] = column }
    }

    /// Takes the cursor off the grid. Columns left without a name are dropped.
    private func leaveGrid() {
        commitDraft()
        guard let cell = canvas.cell else { return }
        canvas.cell = nil
        for column in model.table(cell.table)?.columns ?? [] where column.name.trimmingCharacters(in: .whitespaces).isEmpty {
            model.removeColumn(column.id)
        }
    }

    /// Adds a column after `column` (at the top for nil) and starts typing its name.
    private func addColumn(to table: Table.ID, after column: Column.ID?) {
        commitDraft()
        if let id = model.addColumn(to: table, after: column) {
            begin(CanvasController.Cell(table: table, row: .column(id), part: .name), replacingWith: "")
        }
    }

    /// Deletes the cursor's column; the cursor goes to the row above.
    private func deleteColumn(at cell: CanvasController.Cell) {
        guard case .column(let id) = cell.row, let table = model.table(cell.table),
              let row = table.columns.firstIndex(where: { $0.id == id }) else { return }
        canvas.isEditingCell = false
        canvas.cell = row > 0 ? CanvasController.Cell(table: table.id, row: .column(table.columns[row - 1].id), part: cell.part)
            : .name(of: table.id)
        model.removeColumn(id)
    }

    private func updateColumn(_ column: Column.ID, in table: Table.ID, _ change: (inout Column) -> Void) {
        guard let index = model.tables.firstIndex(where: { $0.id == table }),
              let row = model.tables[index].columns.firstIndex(where: { $0.id == column }) else { return }
        change(&model.tables[index].columns[row])
    }

    private func togglePrimaryKey(_ cell: CanvasController.Cell) {
        guard case .column(let id) = cell.row, let column = model.table(cell.table)?.columns.first(where: { $0.id == id }) else { return }
        setPrimaryKey(cell, to: !column.isPrimaryKey)
    }

    private func setPrimaryKey(_ cell: CanvasController.Cell, to isKey: Bool) {
        guard case .column(let id) = cell.row, let index = model.tables.firstIndex(where: { $0.id == cell.table }),
              let row = model.tables[index].columns.firstIndex(where: { $0.id == id }),
              model.tables[index].columns[row].isPrimaryKey != isKey else { return }
        model.tables[index].columns[row].isPrimaryKey = isKey
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
            .gesture(itemGesture(.zipTie(tie.id)) { _ in if isBendPoint { model.removeZipTie(tie.id) } })
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
        #if DEBUG
        if canvas.isFeedbackMode { return feedbackClick(at: point) }
        #endif
        let isExtending = NSEvent.modifierFlags.contains(.shift)
        guard let hit = simulation.hit(near: point, within: Metrics.wireHitRadius / canvas.zoom) else {
            if !isExtending { canvas.selection = [] }
            lastClick = nil
            return
        }
        let item = CanvasController.Item.relationship(hit.relationship)
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastClick, last.item == item, now - last.time < NSEvent.doubleClickInterval,
           let bend = model.addBendPoint(on: hit.relationship, at: hit.point, direction: hit.tangent, segment: hit.segment) {
            canvas.selection = [.zipTie(bend)]
            lastClick = nil
        } else {
            canvas.click(item, extending: isExtending)
            lastClick = (item, now)
        }
    }

    /// With the zip-tie tool or Option, draws a line to tie the wires it crosses; otherwise drags out a selection
    /// rectangle. Only once it's gone a few points, so a click stays a click. In view points.
    private func dragBackground(from startLocation: CGPoint, to location: CGPoint) {
        guard canvas.backgroundDrag != nil || startLocation.distance(to: location) >= 3 else { return }
        let start = canvas.canvasPoint(startLocation), now = canvas.canvasPoint(location)
        if canvas.backgroundDrag == nil {
            isCanvasFocused = true
            let flags = NSEvent.modifierFlags
            if canvas.isTying || flags.contains(.option) {
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

    private func finishBackgroundDrag() {
        switch canvas.backgroundDrag {
        case .stroke:
            finishStroke()
        case .marquee, nil:
            canvas.marquee = nil
        }
        canvas.backgroundDrag = nil
    }

    /// What a selection rectangle picks up: only what's wholly inside it, tables, ties and wires alike, so it can be
    /// drawn across a crowded canvas without catching what it passes over.
    private func items(in rect: CGRect) -> Set<CanvasController.Item> {
        CanvasController.boxSelection(
            tables: model.tables.filter { rect.contains(Metrics.frame(of: $0)) }.map(\.id),
            ties: model.zipTies.filter { tie in
                let reach = Metrics.tieHalfLength(holding: tie.relationships.count)
                return rect.contains(CGRect(x: tie.position.x - reach, y: tie.position.y - reach, width: reach * 2, height: reach * 2))
            }.map(\.id),
            wires: simulation.wires.filter { $0.value.points.allSatisfy(rect.contains) }.map(\.key),
            groups: model.groups.filter { model.frame(of: $0.id).map(rect.contains) == true }.map(\.id))
    }

    private func finishStroke() {
        if let stroke = canvas.stroke, let tie = model.zipTie(simulation, from: stroke.start, to: stroke.end) {
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
        model.move(tables: canvas.selectedTables, ties: canvas.selectedTies, by: delta)
    }

    // MARK: Overlay

    /// The wire being dragged out, the tie line and the selection rectangle, above the tables.
    private func gestureOverlay(_ routing: Routing) -> some View {
        let zoom = canvas.zoom, offset = canvas.offset, connection = canvas.connection, stroke = canvas.stroke
        let marquee = canvas.marquee, guides = canvas.guides
        #if DEBUG
        let feedback = canvas.feedback.map { (routed: routing.routes[$0.relationship]?.points ?? [], expected: $0.expected) }
        #endif
        // Previews the color it'll take once dropped, and on a table, the column it'll add.
        let color = connection.map { connection in
            switch connection.target {
            case .column(let id)?: model.columnLocations[id]?.table.color.color ?? Theme.socket
            case .table?: model.columnLocations[connection.from]?.table.color.color ?? Theme.socket
            case nil: Theme.socket
            }
        }
        let newColumn: String? = if let connection, case .table(let id)? = connection.target {
            model.newColumnName(referencing: connection.from, in: id)
        } else { nil }
        return Canvas { screen, _ in
            var context = screen
            context.translateBy(x: offset.x, y: offset.y)
            context.scaleBy(x: zoom, y: zoom)
            // Muted, a point wide on screen, a little past the tables they join.
            for guide in guides {
                var line = Path()
                let overhang = 12 / zoom
                if guide.isVertical {
                    line.move(to: CGPoint(x: guide.position, y: guide.start - overhang))
                    line.addLine(to: CGPoint(x: guide.position, y: guide.end + overhang))
                } else {
                    line.move(to: CGPoint(x: guide.start - overhang, y: guide.position))
                    line.addLine(to: CGPoint(x: guide.end + overhang, y: guide.position))
                }
                context.stroke(line, with: .color(Theme.guide), lineWidth: 1 / zoom)
            }
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
            #if DEBUG
            // The correction: grey, with the gap between it and the routed wire shaded.
            if let feedback, !feedback.routed.isEmpty {
                var gap = Path()
                gap.addLines(feedback.routed + feedback.expected.reversed())
                gap.closeSubpath()
                context.fill(gap, with: .color(.gray.opacity(0.22)), style: FillStyle(eoFill: true))
                var line = Path()
                line.addLines(feedback.expected)
                context.stroke(line, with: .color(.gray), style: StrokeStyle(lineWidth: Metrics.wireWidth, lineCap: .round, lineJoin: .round))
            }
            #endif
        }
        .allowsHitTesting(false)
    }
}

#if DEBUG
extension CanvasView {
    /// In feedback mode, a click on the correction adds a point there; on another wire, starts correcting it.
    fileprivate func feedbackClick(at point: CGPoint) {
        let tolerance = Metrics.wireHitRadius / canvas.zoom
        if var edit = canvas.feedback, let index = edit.insertionIndex(near: point, within: tolerance) {
            edit.points.insert(point, at: index)
            edit.isAnchor.insert(false, at: index)
            canvas.feedback = edit
        } else if let hit = simulation.hit(near: point, within: tolerance),
                  let route = Routing(model: model, avoidingTables: wiresAvoidTables).routes[hit.relationship] {
            canvas.feedback = FeedbackEdit(relationship: hit.relationship, route: route)
        }
    }

    /// Saves the correction with the model and routing as they are now.
    fileprivate func saveFeedback() {
        guard let edit = canvas.feedback,
              let route = Routing(model: model, avoidingTables: wiresAvoidTables).routes[edit.relationship],
              let relationship = model.relationships.first(where: { $0.id == edit.relationship }) else { return }
        let foreignKey = "\(model.qualifiedName(of: relationship.from) ?? "?") → \(model.qualifiedName(of: relationship.to) ?? "?")"
        do {
            try RoutingFeedback.save(RoutingFeedbackCase(
                modelName: Library.shared.open?.name ?? "", note: edit.note, routingVersion: Routing.version,
                routingParameters: Routing.parameters, avoidingTables: wiresAvoidTables, model: model,
                relationship: edit.relationship, foreignKey: foreignKey, routed: route.points, expected: edit.expected,
                controlPoints: edit.points))
            canvas.feedback = nil
        } catch {
            Library.shared.failure = "Couldn't save the correction: \(error.localizedDescription)"
        }
    }

    /// The correction's movable points: drag to reshape, right-click to remove.
    fileprivate func feedbackHandles(_ edit: FeedbackEdit) -> some View {
        ForEach(edit.points.indices.filter { !edit.isAnchor[$0] }, id: \.self) { index in
            Circle()
                .fill(Color.gray)
                .strokeBorder(Theme.card, lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .frame(width: Metrics.minimumTarget, height: Metrics.minimumTarget)
                .contentShape(.circle)
                .position(canvas.viewPoint(edit.points[index]))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .canvas).onChanged { value in
                    canvas.feedback?.points[index] = canvas.canvasPoint(value.location)
                })
                .contextMenu {
                    Button("Remove Point", systemImage: "minus.circle") {
                        canvas.feedback?.points.remove(at: index)
                        canvas.feedback?.isAnchor.remove(at: index)
                    }
                }
                .pointerStyle(.grabIdle)
        }
    }
}

/// Routing feedback mode's instructions and controls.
private struct FeedbackBar: View {
    @Bindable var canvas: CanvasController
    let save: () -> Void
    @State private var saved = RoutingFeedback.count

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .foregroundStyle(.secondary)
            if canvas.feedback != nil {
                TextField("What's wrong? (optional)", text: Binding { canvas.feedback?.note ?? "" } set: { canvas.feedback?.note = $0 })
                    .textFieldStyle(.plain)
                    .frame(width: 240)
                    .onSubmit(saveAndCount)
                Button("Save", action: saveAndCount).keyboardShortcut(.return, modifiers: [])
                Button("Discard") { canvas.feedback = nil }
            } else {
                Text("Click a cable, then drag its grey line to where it should run.")
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 16)
            Text("\(saved) saved").foregroundStyle(.secondary).monospacedDigit()
            Button("Done") { canvas.isFeedbackMode = false; canvas.feedback = nil }
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect()
    }

    private func saveAndCount() {
        save()
        saved = RoutingFeedback.count
    }
}
#endif

/// The grid's keys, in a capsule at the bottom of the canvas while its cursor is on a table. Those that change the
/// table are also buttons.
private struct GridHints: View {
    let perform: (CanvasController.CellCommand) -> Void

    var body: some View {
        HStack(spacing: 16) {
            hint("Type", "to edit")
            hint("⇥", "Next")
            hint("↩", "Down")
            Button { perform(.toggleKey) } label: { hint("Space", "Key") }
            Button { perform(.toggleRequired) } label: { hint("⇧⌘R", "Required") }
            Button { perform(.toggleUnique) } label: { hint("⇧⌘U", "Unique") }
            Button { perform(.insertColumn) } label: { hint("⌘↩", "Insert") }
            Button { perform(.deleteColumn) } label: { hint("⌘⌫", "Delete") }
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

/// The last routing worked out, kept while nothing it depends on changes: a redraw that only moves the grid cursor or
/// the selection needn't route every wire again.
@MainActor
private final class RoutingCache {
    private var inputs: (model: DataModel, tables: [Table.ID: CGPoint], ties: [ZipTie.ID: CGPoint], avoiding: Bool)?
    private var routing: Routing?

    private var colors: (model: DataModel, colors: [Relationship.ID: Color])?

    /// Each wire's color, the color of the table it references, worked out again only when the model changes.
    func wireColors(for model: DataModel) -> [Relationship.ID: Color] {
        if let colors, colors.model == model { return colors.colors }
        let locations = model.columnLocations
        let wireColors = Dictionary(model.relationships.compactMap { r in locations[r.to].map { (r.id, $0.table.color.color) } },
                                    uniquingKeysWith: { first, _ in first })
        colors = (model, wireColors)
        return wireColors
    }

    func routing(for model: DataModel, tableOffsets: [Table.ID: CGPoint], tieOffsets: [ZipTie.ID: CGPoint],
                 avoidingTables: Bool) -> Routing {
        if let inputs, let routing, inputs.avoiding == avoidingTables, inputs.tables == tableOffsets,
           inputs.ties == tieOffsets, inputs.model == model {
            return routing
        }
        // From the last one, so only routes whose ends, ties or nearby tables moved are worked out again.
        let route = { [routing] in
            Routing(model: model, tableOffsets: tableOffsets, tieOffsets: tieOffsets, avoidingTables: avoidingTables,
                    reusing: routing)
        }
        #if DEBUG
        let (routing, milliseconds) = FrameMeter.time(route)
        FrameMeter.shared.routed(in: milliseconds)
        #else
        let routing = route()
        #endif
        inputs = (model, tableOffsets, tieOffsets, avoidingTables)
        self.routing = routing
        return routing
    }
}

/// Each wire's drawn path, kept while its points stay put: most wires are at rest most of the time, and smoothing a
/// path through them is most of the cost of drawing one.
@MainActor
private final class WirePaths {
    private var paths: [Relationship.ID: (points: [CGPoint], path: Path)] = [:]

    func path(for wire: Relationship.ID, through points: [CGPoint]) -> Path {
        if let cached = paths[wire], cached.points == points { return cached.path }
        let path = Path(smoothing: points)
        paths[wire] = (points, path)
        return path
    }
}

/// Dots every 24 points, thinned out as you zoom out so they never crowd.
private struct GridLayer: View {
    let zoom: CGFloat
    let offset: CGPoint

    var body: some View {
        // One dot on a tile, repeated across the view by the GPU, rather than a shape per dot: on a big display at a close
        // zoom there are tens of thousands, and drawing each one cost more the bigger the window.
        Canvas { context, size in
            var spacing = 24 * zoom
            while spacing < 12 { spacing *= 4 }
            let scale = context.environment.displayScale
            let pixels = max(Int((spacing * scale).rounded()), 2)
            guard let tile = Self.tile(pixels: pixels, dot: 1.6 * scale,
                                       color: Theme.gridDot.resolve(in: context.environment).cgColor) else { return }
            // The tile's dot is at its middle, and the dots sit on multiples of the spacing from the offset.
            let origin = CGPoint(x: offset.x - spacing / 2, y: offset.y - spacing / 2)
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .tiledImage(Image(decorative: tile, scale: scale), origin: origin,
                                           scale: spacing * scale / CGFloat(pixels)))
        }
        .background(Theme.canvas)
        .allowsHitTesting(false)
    }

    /// A square of `pixels` with a dot of `dot` pixels across in the middle.
    private static func tile(pixels: Int, dot: CGFloat, color: CGColor) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let middle = CGFloat(pixels) / 2
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: middle - dot / 2, y: middle - dot / 2, width: dot, height: dot))
        return context.makeImage()
    }
}

extension Path {
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
