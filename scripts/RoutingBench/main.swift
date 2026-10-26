import Foundation

// How long routing takes on big models, as a whole and as each frame of dragging a table recomputes it: made-up models
// (the same every run) and any .joinery files named, with each group's shared wires bundled into ports.
// Usage: scripts/routing-bench.sh [-Onone] [model.joinery …]
func time(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

var models: [(String, DataModel)] = [("synthetic 200/300", DataModel.synthetic(tables: 200, foreignKeys: 300, groups: 6)),
                                     ("synthetic 160/500", DataModel.synthetic(tables: 160, foreignKeys: 500, groups: 4))]
for path in CommandLine.arguments.dropFirst() {
    var model = try! JSONDecoder().decode(DataModel.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    model.repair()
    models.append((URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, model))
}
for (name, plain) in models {
    var bundled = plain
    for group in bundled.groups.map(\.id) { bundled.bundleSharedWires(in: group, minimum: 2) }
    for (label, model) in [("", plain), (" bundled", bundled)] {
        for avoiding in [false, true] {
            var full = 0.0, routing = Routing(model: model, avoidingTables: avoiding)
            full = time { routing = Routing(model: model, avoidingTables: avoiding) }
            // A table in the middle dragged about, a frame at a time, each reusing the last.
            let table = model.tables[model.tables.count / 2].id
            var frames: [Double] = []
            for step in 0..<40 {
                let offset = CGPoint(x: CGFloat(step) * 6, y: CGFloat(step % 7) * 4)
                frames.append(time { routing = Routing(model: model, tableOffsets: [table: offset], avoidingTables: avoiding, reusing: routing) })
            }
            frames.sort()
            let ports = time { _ = model.portPlacements() }
            let bussed = model.portPlacements().values.map(\.wires.count).reduce(0, +)
            print(String(format: "%@%@ (%d tables, %d keys, %d ports, %d wires through them), avoiding %@: full %.1f ms, drag frame %.1f ms median, %.1f worst; ports %.2f ms",
                         name, label, model.tables.count, model.relationships.count, model.groups.flatMap(\.ports).count, bussed,
                         avoiding ? "yes" : "no", full, frames[frames.count / 2], frames.last!, ports))
        }
    }
}
