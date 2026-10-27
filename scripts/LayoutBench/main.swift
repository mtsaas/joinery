import Foundation

// How good each layout is: the crossings of wires drawn straight between tables' middles, their total length and the
// area taken, with and without refining, on made-up models and any .joinery files named.
// Usage: scripts/layout-bench.sh [model.joinery …]
func measure(_ model: DataModel) -> (crossings: Int, length: Int, area: String) {
    let middles = Dictionary(uniqueKeysWithValues: model.tables.map { ($0.id, CGPoint(x: Metrics.frame(of: $0).midX, y: Metrics.frame(of: $0).midY)) })
    let owner = model.columnLocations
    let segments = model.relationships.compactMap { wire -> (CGPoint, CGPoint)? in
        guard let a = owner[wire.from].flatMap({ middles[$0.table.id] }), let b = owner[wire.to].flatMap({ middles[$0.table.id] }) else { return nil }
        return (a, b)
    }
    let bounds = model.bounds ?? .zero
    return (Untangler.crossings(segments), Int(segments.reduce(0) { $0 + $1.0.distance(to: $1.1) }), "\(Int(bounds.width))×\(Int(bounds.height))")
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
        for rounds in [0, 6] {
            DataModel.refinementRounds = rounds
            var arranged = model
            let start = Date()
            arranged.arrange(layout)
            let m = measure(arranged)
            line += String(format: "  %@ %d crossings, %d long, %@, %.0f ms", rounds == 0 ? "unrefined" : "refined", m.crossings, m.length, m.area, Date().timeIntervalSince(start) * 1000)
        }
        print(line)
    }
}
