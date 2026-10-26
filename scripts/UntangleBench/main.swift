import Foundation

// Measures untangling's tuning: scrambled made-up models of a few sizes, untangled with each variant, the crossings
// left, how much more area the tables span, and the time taken. Usage: scripts/untangle-bench.sh
let variants: [(String, Untangler.Tuning)] = [
    ("as tuned", .init()),
    ("no room", .init(room: 0)),
    ("unbounded", .init(room: 100)),
    ("lighter depth", .init(depthWeight: 0.01)),
]
let cases: [(tables: Int, keys: Int, shuffle: Int)] = [(24, 36, 7), (40, 60, 7), (40, 60, 11), (60, 90, 13)]
for (name, tuning) in variants {
    var total = 0.0, line = "", seconds = 0.0
    for c in cases {
        var model = DataModel.synthetic(tables: c.tables, foreignKeys: c.keys)
        let positions = model.tables.map(\.position)
        for index in model.tables.indices { model.tables[index].position = positions[(index * c.shuffle) % positions.count] }
        let started = Date()
        var untangler = Untangler(model: model, moving: Set(model.tables.map(\.id)), tuning: tuning)
        while !untangler.isDone { untangler.step() }
        seconds += Date().timeIntervalSince(started)
        total += Double(untangler.best.crossings) / Double(untangler.startingCrossings)
        // How much more room the result takes than the start, by the area its tables span.
        let span = { (offsets: [Table.ID: CGPoint]) in model.tables.map { CGRect(origin: $0.position + offsets[$0.id, default: .zero], size: Metrics.size(of: $0)) }.reduce(CGRect.null) { $0.union($1) } }
        let (before, after) = (span([:]), span(untangler.bestOffsets))
        line += String(format: "%d→%d ×%.1f  ", untangler.startingCrossings, untangler.best.crossings, after.width * after.height / (before.width * before.height))
    }
    print(String(format: "%-32@ %@ mean left %.0f%%, %.1f s", name as NSString, line, total / Double(cases.count) * 100, seconds))
}
