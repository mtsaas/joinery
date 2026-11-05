import Foundation

// How good each layout is: the crossings of wires drawn straight between tables' middles, their total length and the
// area taken, with and without refining, on made-up models and any .joinery files named.
// Usage: scripts/layout-bench.sh [model.joinery …]
func measure(_ model: DataModel) -> (crossings: Int, length: Int, area: String, backward: Int, drift: Int, overlaps: Int) {
    let middles = Dictionary(uniqueKeysWithValues: model.tables.map { ($0.id, CGPoint(x: Metrics.frame(of: $0).midX, y: Metrics.frame(of: $0).midY)) })
    let owner = model.columnLocations
    let segments = model.relationships.compactMap { wire -> (CGPoint, CGPoint)? in
        guard let a = owner[wire.from].flatMap({ middles[$0.table.id] }), let b = owner[wire.to].flatMap({ middles[$0.table.id] }) else { return nil }
        return (a, b)
    }
    let bounds = model.bounds ?? .zero
    // Wires whose referencing table isn't right of the one it references, and how far wires go up or down, socket to socket.
    var backward = 0, drift: CGFloat = 0, sockets: [(CGPoint, CGPoint)] = []
    for wire in model.relationships {
        guard let child = owner[wire.from], let parent = owner[wire.to], child.table.id != parent.table.id else { continue }
        let c = Metrics.frame(of: child.table), p = Metrics.frame(of: parent.table)
        if c.minX < p.maxX { backward += 1 }
        sockets.append((Metrics.socket(row: child.row, side: .leading, in: c), Metrics.socket(row: parent.row, side: .trailing, in: p)))
        drift += abs(Metrics.socket(row: child.row, side: .leading, in: c).y - Metrics.socket(row: parent.row, side: .trailing, in: p).y)
    }
    let frames = model.tables.map(Metrics.frame)
    let overlaps = frames.indices.reduce(0) { total, a in total + frames.indices.filter { $0 > a && frames[$0].intersects(frames[a]) }.count }
    return (Untangler.crossings(sockets), Int(segments.reduce(0) { $0 + $1.0.distance(to: $1.1) }), "\(Int(bounds.width))×\(Int(bounds.height))",
            backward, Int(drift), overlaps)
}
var models: [(String, DataModel)] = [("synthetic 60/90", DataModel.synthetic(tables: 60, foreignKeys: 90, groups: 3)),
                                     ("synthetic 120/200", DataModel.synthetic(tables: 120, foreignKeys: 200, groups: 4))]
for path in CommandLine.arguments.dropFirst() {
    var model = try! JSONDecoder().decode(DataModel.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    model.repair()
    models.append((URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, model))
}
for (name, model) in models {
    for layout in DataModel.Layout.allCases {
        var line = "\(name), \(layout.title):"
        for rounds in [6] {
            DataModel.refinementRounds = rounds
            var arranged = model
            let start = Date()
            arranged.arrange(layout)
            let m = measure(arranged)
            line += String(format: "  %@ %d crossings, %d long, %d backward, %d drift, %d overlaps, %@, %.0f ms", rounds == 0 ? "unrefined" : "refined", m.crossings, m.length, m.backward, m.drift, m.overlaps, m.area, Date().timeIntervalSince(start) * 1000)
        }
        print(line)
    }
}
