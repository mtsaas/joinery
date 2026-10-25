import SwiftUI

/// The infinite canvas: tables, the springy wires between their columns, and the zip ties that bundle them.
///
/// Drag empty space to pan (or scroll), pinch or ⌘-scroll to zoom. Drag from a column's socket onto another column to
/// add a foreign key. Option-drag across wires, or drag with the Zip Tie tool, to tie them together.
struct CanvasView: View {
    @Binding var schema: Schema
    @Bindable var canvas: CanvasController

    @State private var simulation = WireSimulation()
    @State private var isAnimating = false
    @FocusState private var isFocused: Bool

    var body: some View {
        let routing = Routing(schema: schema, tableOffsets: canvas.tableDrag, tieOffsets: canvas.tieDrag)
        let socketColors = socketColors(routing)
        ZStack(alignment: .topLeading) {
            GridLayer(zoom: canvas.zoom, offset: canvas.offset)
            wireLayer(routing)
            ForEach(schema.tables) { table in
                tableView(table, socketColors: socketColors)
            }
            ForEach(schema.zipTies) { tie in
                if let frame = routing.ties[tie.id] { tieHandle(tie, frame) }
            }
            gestureOverlay
        }
        .coordinateSpace(.canvas)
        .clipped()
        .background { ScrollWheelReader(canvas: canvas) }
        .onGeometryChange(for: CGSize.self, of: \.size) { canvas.resize(to: $0, fitting: schema.bounds) }
        .overlay {
            if schema.tables.isEmpty {
                ContentUnavailableView {
                    Label("No Tables", systemImage: "tablecells")
                } description: {
                    Text("Add a table, then drag between column sockets to draw foreign keys.")
                } actions: {
                    Button("Add Table") { canvas.addTable(to: &schema) }
                }
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onDeleteCommand { canvas.deleteSelection(in: &schema) }
        .onExitCommand { canvas.selection = nil; canvas.tool = .select }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .finishStroke)) { note in
            if note.object as AnyObject? === canvas { finishStroke() }
        }
        #endif
    }

    // MARK: Wires

    private func wireLayer(_ routing: Routing) -> some View {
        // Read here, not in the renderer, so changes redraw the canvas.
        let zoom = canvas.zoom, offset = canvas.offset, highlighted = highlightedRelationships
        let tieCrossings = canvas.stroke.map { Set(simulation.crossings(from: $0.start, to: $0.end).map(\.relationship)) } ?? []
        let selectedTie: ZipTie.ID? = if case .zipTie(let id) = canvas.selection { id } else { nil }
        let hoveredTie = canvas.hoveredTie
        let colors = wireColors
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
                    context.stroke(path, with: .color(color.opacity(isDimmed ? 0.28 : 1)),
                                   style: StrokeStyle(lineWidth: Metrics.wireWidth, lineCap: .round))
                }
                for (id, tie) in routing.ties {
                    drawTie(tie, isSelected: id == selectedTie, isHovered: id == hoveredTie, in: context,
                            relationships: relationships, tieID: id)
                }
            }
        }
        .contentShape(.rect)
        .onTapGesture(coordinateSpace: .canvas) { location in
            isFocused = true
            let point = canvas.canvasPoint(location)
            canvas.selection = simulation.wire(near: point, within: 6 / canvas.zoom).map(CanvasController.Selection.relationship)
        }
        .gesture(panOrTieGesture)
        .pointerStyle(canvas.tool == .zipTie ? .rectSelection : nil)
    }

    /// Drawn where its wires actually are, so it rides along as they spring into place.
    private func drawTie(_ tie: Routing.Tie, isSelected: Bool, isHovered: Bool, in context: GraphicsContext,
                         relationships: [Relationship], tieID: ZipTie.ID) {
        let slots = tie.relationships.compactMap { id -> CGPoint? in
            guard let wire = simulation.wires[id],
                  let index = relationships.first(where: { $0.id == id })?.zipTies.firstIndex(of: tieID) else { return nil }
            let sample = (index + 1) * Routing.samplesPerSegment
            return wire.points.indices.contains(sample) ? wire.points[sample] : nil
        }
        guard !slots.isEmpty else { return }
        var context = context
        let center = slots.reduce(.zero, +) / CGFloat(slots.count)
        context.translateBy(x: center.x, y: center.y)
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
    private func socketColors(_ routing: Routing) -> [Routing.Socket: Color] {
        let wireColors = wireColors
        var colors: [Routing.Socket: Color] = [:]
        for (id, sockets) in routing.sockets {
            colors[sockets.from] = colors[sockets.from] ?? wireColors[id]
            colors[sockets.to] = wireColors[id]
        }
        return colors
    }

    /// The wires to show over the rest, which fade: those of the selected table, wire, or tie. Nil highlights none.
    private var highlightedRelationships: Set<Relationship.ID>? {
        switch canvas.selection {
        case .table(let id):
            let columns = Set(schema.table(id)?.columns.map(\.id) ?? [])
            return Set(schema.relationships.filter { columns.contains($0.from) || columns.contains($0.to) }.map(\.id))
        case .relationship(let id): return [id]
        case .zipTie(let id): return Set(schema.zipTies.first { $0.id == id }?.relationships ?? [])
        case nil: return nil
        }
    }

    // MARK: Tables

    private func tableView(_ table: Table, socketColors: [Routing.Socket: Color]) -> some View {
        let frame = Metrics.frame(of: table).offsetBy(dx: canvas.tableDrag[table.id]?.x ?? 0, dy: canvas.tableDrag[table.id]?.y ?? 0)
        let origin = canvas.viewPoint(frame.origin)
        return ZStack(alignment: .topLeading) {
            TableCard(table: table, zoom: canvas.zoom, isSelected: canvas.selection == .table(table.id),
                      targetColumn: canvas.connection?.target)
                .position(x: origin.x + frame.width * canvas.zoom / 2, y: origin.y + frame.height * canvas.zoom / 2)
                .gesture(moveGesture(table))
                .contextMenu {
                    Button("Edit Table…", systemImage: "info.circle") { select(.table(table.id)); canvas.showsInspector = true }
                    Divider()
                    Button("Delete Table", systemImage: "trash", role: .destructive) { schema.removeTable(table.id) }
                }
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

    private func moveGesture(_ table: Table) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .canvas)
            .onChanged { value in
                select(.table(table.id))
                canvas.tableDrag[table.id] = CGPoint(value.translation) / canvas.zoom
            }
            .onEnded { value in
                canvas.tableDrag[table.id] = nil
                let delta = CGPoint(value.translation) / canvas.zoom
                guard delta != .zero, let index = schema.tables.firstIndex(where: { $0.id == table.id }) else { return }
                schema.tables[index].position += delta
            }
    }

    private func connectGesture(from column: Column, at socket: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .canvas)
            .onChanged { value in
                let end = canvas.canvasPoint(value.location)
                let target = schema.column(at: end).flatMap { $0 == column.id ? nil : $0 }
                canvas.connection = .init(from: column.id, start: socket, end: end, target: target)
            }
            .onEnded { _ in
                if let connection = canvas.connection, let target = connection.target,
                   let id = schema.connect(connection.from, to: target) {
                    canvas.selection = .relationship(id)
                }
                canvas.connection = nil
            }
    }

    // MARK: Zip ties

    private func tieHandle(_ tie: ZipTie, _ frame: Routing.Tie) -> some View {
        let length = Metrics.tieHalfLength(holding: tie.relationships.count) * 2 + Metrics.socketHitRadius
        // Never smaller than a comfortable target on screen, however far out you've zoomed.
        return Color.clear
            .frame(width: max(Metrics.socketHitRadius * 2 * canvas.zoom, Metrics.minimumTarget),
                   height: max(length * canvas.zoom, Metrics.minimumTarget))
            .contentShape(.rect)
            .rotationEffect(.radians(atan2(frame.direction.y, frame.direction.x)))
            .position(canvas.viewPoint(frame.center))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .canvas)
                .onChanged { value in
                    select(.zipTie(tie.id))
                    canvas.tieDrag[tie.id] = CGPoint(value.translation) / canvas.zoom
                }
                .onEnded { value in
                    canvas.tieDrag[tie.id] = nil
                    let delta = CGPoint(value.translation) / canvas.zoom
                    guard delta != .zero, let index = schema.zipTies.firstIndex(where: { $0.id == tie.id }) else { return }
                    schema.zipTies[index].position += delta
                })
            .contextMenu {
                Button("Cut Zip Tie", systemImage: "scissors", role: .destructive) { schema.removeZipTie(tie.id) }
            }
            .onHover { isHovered in
                if isHovered { canvas.hoveredTie = tie.id } else if canvas.hoveredTie == tie.id { canvas.hoveredTie = nil }
            }
            .pointerStyle(canvas.tieDrag[tie.id] == nil ? .grabIdle : .grabActive)
            .help("Zip tie: drag to move, Delete to cut")
    }

    /// Pans, or with Option or the Zip Tie tool, draws a line that ties the wires it crosses.
    private var panOrTieGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .canvas)
            .onChanged { value in
                if canvas.stroke == nil, canvas.panOrigin == nil {
                    if canvas.tool == .zipTie || NSEvent.modifierFlags.contains(.option) {
                        canvas.stroke = .init(start: canvas.canvasPoint(value.startLocation), end: canvas.canvasPoint(value.location))
                    } else {
                        canvas.panOrigin = canvas.offset
                    }
                }
                if let origin = canvas.panOrigin {
                    canvas.pan(by: origin + CGPoint(value.translation) - canvas.offset)
                } else {
                    canvas.stroke?.end = canvas.canvasPoint(value.location)
                }
            }
            .onEnded { _ in finishStroke() }
    }

    private func finishStroke() {
        if let stroke = canvas.stroke, let tie = schema.zipTie(simulation, from: stroke.start, to: stroke.end) {
            canvas.selection = .zipTie(tie)
        }
        canvas.stroke = nil
        canvas.panOrigin = nil
    }

    // MARK: Overlay

    /// The wire being dragged out and the tie line being drawn, above the tables.
    private var gestureOverlay: some View {
        let zoom = canvas.zoom, offset = canvas.offset, connection = canvas.connection, stroke = canvas.stroke
        // Previews the color it'll take once dropped.
        let color = connection.map { connection in
            connection.target.flatMap { schema.columnLocations[$0]?.table.color.color } ?? Theme.socket
        }
        return Canvas { context, _ in
            context.translateBy(x: offset.x, y: offset.y)
            context.scaleBy(x: zoom, y: zoom)
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
        }
        .allowsHitTesting(false)
    }

    private func select(_ selection: CanvasController.Selection) {
        isFocused = true
        if canvas.selection != selection { canvas.selection = selection }
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
