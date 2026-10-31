import SwiftUI

/// Where each column's socket is in the table designer's column grid, for the index cables drawn over it.
struct SocketAnchors: PreferenceKey {
    static let defaultValue: [Column.ID: Anchor<CGPoint>] = [:]

    static func reduce(value: inout [Column.ID: Anchor<CGPoint>], nextValue: () -> [Column.ID: Anchor<CGPoint>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A cable being drawn from a socket: a new index from `from`, or with `index`, more of that one.
struct CableDrag: Equatable {
    var from: Column.ID
    var index: TableIndex.ID?
    var location: CGPoint
}

/// How the index cables lie beside the sockets: each index in a lane of its own, out to the left of them, so no two
/// overlap. The shortest reach the nearest lane, so the cables nest rather than cross. Every turn is a right angle,
/// rounded: out from a socket, along the lane, back in to the next.
struct CableLayout {
    static let socketDiameter: CGFloat = 10
    /// From a socket's edge to the nearest lane, and between lanes.
    static let stub: CGFloat = 10
    /// Between two lanes, as between two cables into the same socket (`fan`), so the gaps are the same both ways.
    static let laneSpacing: CGFloat = fan
    static let lineWidth: CGFloat = 2
    /// The rounding of a cable's turns: no more than half the lane's own reach, so a short one still turns cleanly.
    static let cornerRadius: CGFloat = 5

    /// Each index's lane, 0 the nearest the sockets.
    let lanes: [TableIndex.ID: Int]

    init(indexes: [TableIndex], socketY: [Column.ID: CGFloat]) {
        let spans = indexes.map { index -> (TableIndex.ID, CGFloat) in
            let ys = index.columns.compactMap { socketY[$0] }
            return (index.id, (ys.max() ?? 0) - (ys.min() ?? 0))
        }
        // Sorted by reach, keeping the indexes' own order among equals.
        let ordered = spans.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
        lanes = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, $0) })
    }

    /// How much room to leave left of the sockets for `count` lanes.
    static func gutter(lanes count: Int) -> CGFloat {
        stub + CGFloat(max(count, 1)) * laneSpacing
    }

    /// Between two cables into the same socket, fanned out up and down it so each one's color shows.
    static let fan: CGFloat = 3
    /// A lane's strip to drag from: wider than the lanes are apart, to be easy to catch.
    static let grabWidth: CGFloat = 8
    /// The dot that ends a single column's cable, in its lane.
    static let endDiameter: CGFloat = 5

    /// How far up or down its socket each index's cable meets each of its columns: apart, when more than one meets the
    /// same socket, in lane order, centered on it.
    func offsets(_ indexes: [TableIndex]) -> [TableIndex.ID: [Column.ID: CGFloat]] {
        var meeting: [Column.ID: [TableIndex.ID]] = [:]
        for index in indexes { for column in index.columns { meeting[column, default: []].append(index.id) } }
        var offsets: [TableIndex.ID: [Column.ID: CGFloat]] = [:]
        for (column, ids) in meeting {
            let sorted = ids.sorted { (lanes[$0] ?? 0) < (lanes[$1] ?? 0) }
            for (position, id) in sorted.enumerated() {
                offsets[id, default: [:]][column] = (CGFloat(position) - CGFloat(sorted.count - 1) / 2) * Self.fan
            }
        }
        return offsets
    }

    static func laneX(_ lane: Int, socketX: CGFloat) -> CGFloat {
        socketX - socketDiameter / 2 - stub - CGFloat(lane) * laneSpacing
    }

    /// A cable along `laneX`, out from and back in to each of `points`' sockets: one line from the top socket round
    /// into the lane, down it and round into the bottom socket, the ones between meeting the lane square on.
    static func path(through points: [CGPoint], laneX: CGFloat) -> Path {
        Path { path in
            guard let top = points.min(by: { $0.y < $1.y }), let bottom = points.max(by: { $0.y < $1.y }) else { return }
            let edge = { (point: CGPoint) in CGPoint(x: point.x - socketDiameter / 2, y: point.y) }
            // On one column: out to its lane, where a dot ends it.
            guard points.count > 1 else {
                path.move(to: edge(top))
                path.addLine(to: CGPoint(x: laneX, y: top.y))
                return
            }
            path.addPath(rounded([edge(top), CGPoint(x: laneX, y: top.y), CGPoint(x: laneX, y: bottom.y), edge(bottom)]))
            for point in points where point != top && point != bottom {
                path.move(to: edge(point))
                path.addLine(to: CGPoint(x: laneX, y: point.y))
            }
        }
    }

    /// Straight lines through `points`, each turn rounded, as far as the lines either side of it allow.
    static func rounded(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for index in points.indices.dropFirst() {
                let point = points[index]
                guard index + 1 < points.count else {
                    path.addLine(to: point)
                    break
                }
                let before = points[index - 1], after = points[index + 1]
                let reach = min(hypot(point.x - before.x, point.y - before.y), hypot(after.x - point.x, after.y - point.y)) / 2
                path.addArc(tangent1End: point, tangent2End: after, radius: min(cornerRadius, reach))
            }
        }
    }
}

/// The index cables over the column grid, and the lanes to drag from to add a column to an index. A lane's right-click
/// menu takes a column out of its index, or deletes it.
struct IndexCables: View {
    let table: Table
    let sockets: [Column.ID: CGPoint]
    let drag: CableDrag?
    /// The socket a cable being drawn would plug into.
    let target: Column.ID?
    let isReadOnly: Bool
    let dragged: (CableDrag) -> Void
    let dropped: () -> Void
    let change: ((inout Table) -> Void) -> Void

    var body: some View {
        let indexes = table.liveIndexes
        let layout = CableLayout(indexes: indexes, socketY: sockets.mapValues(\.y))
        let socketX = sockets.values.first?.x ?? 0
        let offsets = layout.offsets(indexes)
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for index in indexes {
                    let points = index.columns.compactMap { column in
                        sockets[column].map { CGPoint(x: $0.x, y: $0.y + (offsets[index.id]?[column] ?? 0)) }
                    }
                    let x = CableLayout.laneX(layout.lanes[index.id] ?? 0, socketX: socketX)
                    context.stroke(CableLayout.path(through: points, laneX: x), with: .color(index.color.color),
                                   style: StrokeStyle(lineWidth: CableLayout.lineWidth, lineCap: .round, lineJoin: .round))
                    if points.count == 1, let point = points.first {
                        let d = CableLayout.endDiameter
                        context.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: point.y - d / 2, width: d, height: d)), with: .color(index.color.color))
                    }
                }
                if let drag, let start = sockets[drag.from] {
                    // Out to its lane (a new one past the rest, or the index's own), along it, and on to the pointer.
                    let lane = drag.index.flatMap { layout.lanes[$0] } ?? indexes.count
                    let x = CableLayout.laneX(lane, socketX: socketX)
                    let color = drag.index.flatMap { id in indexes.first { $0.id == id }?.color.color } ?? Color.accentColor
                    let end = target.flatMap { sockets[$0] }
                    let path = CableLayout.rounded([
                        CGPoint(x: start.x - CableLayout.socketDiameter / 2, y: start.y),
                        CGPoint(x: x, y: start.y),
                        CGPoint(x: x, y: end?.y ?? drag.location.y),
                        end.map { CGPoint(x: $0.x - CableLayout.socketDiameter / 2, y: $0.y) } ?? drag.location,
                    ])
                    context.stroke(path, with: .color(color.opacity(end == nil ? 0.6 : 1)),
                                   style: StrokeStyle(lineWidth: CableLayout.lineWidth, lineCap: .round, lineJoin: .round))
                }
            }
            .allowsHitTesting(false)
            if !isReadOnly {
                ForEach(indexes) { index in lane(index, layout: layout, socketX: socketX) }
            }
        }
    }

    /// A strip down an index's lane, to drag from, a little wider than the cable so it's easy to catch.
    @ViewBuilder
    private func lane(_ index: TableIndex, layout: CableLayout, socketX: CGFloat) -> some View {
        let ys = index.columns.compactMap { sockets[$0]?.y }
        if let top = ys.min(), let bottom = ys.max(), let first = index.columns.first(where: { sockets[$0] != nil }) {
            let x = CableLayout.laneX(layout.lanes[index.id] ?? 0, socketX: socketX)
            Color.clear
                .frame(width: CableLayout.grabWidth, height: bottom - top + CableLayout.grabWidth)
                .contentShape(.rect)
                .position(x: x, y: (top + bottom) / 2)
                .pointerStyle(.grabIdle)
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(TableDesigner.columnsSpace))
                    .onChanged { dragged(CableDrag(from: first, index: index.id, location: $0.location)) }
                    .onEnded { _ in dropped() })
                .contextMenu {
                    ForEach(table.columns(of: index)) { column in
                        Button("Remove “\(column.name)” from Index") {
                            change { table in
                                if let row = table.indexes.firstIndex(where: { $0.id == index.id }) {
                                    table.indexes[row].columns.removeAll { $0 == column.id }
                                    table.indexes.removeAll { $0.columns.isEmpty }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Delete Index", role: .destructive) { change { $0.indexes.removeAll { $0.id == index.id } } }
                }
                .help("\(table.name(of: index)): drag to another column's socket to add it")
        }
    }
}
