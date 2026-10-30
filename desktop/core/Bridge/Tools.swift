import Foundation
import JavaScriptKit

// The canvas's tools that need more of the core than an edit: a table in full for the designer, the selection as
// Markdown, focus's neighborhood, and untangling, which runs a step at a time so the canvas can show it moving.

/// One table in full, for the designer: the table as its file holds it (columns, samples by column ID, notes), and
/// what each foreign key references, as "table.column". "null" if there's no such table.
@JS public func tableDetail(_ id: String) -> String {
    let model = App.workspace.model
    guard let uuid = UUID(uuidString: id), let table = model.tables.first(where: { $0.id == uuid }),
          let data = try? JSONEncoder().encode(table), let encoded = try? JSONSerialization.jsonObject(with: data) else { return "null" }
    var references: [String: String] = [:]
    for relationship in model.relationships where table.columns.contains(where: { $0.id == relationship.from }) {
        references[relationship.from.uuidString] = model.qualifiedName(of: relationship.to) ?? ""
    }
    return json(["table": encoded, "references": references])
}

/// The tables (or, with none, the whole model) as Markdown, as Copy as Markdown puts them on the clipboard.
@JS public func markdown(_ tables: String, title: String) -> String {
    let ids = Edits.ids(object(tables)["tables"])
    let model = App.workspace.model
    let clipped = Set(model.clip(tables: ids, groups: []).tables.map(\.id))
    return model.markdown(of: clipped.isEmpty ? nil : clipped, title: title)
}

/// The tables, and every table joined to them: what focus keeps bright.
@JS public func neighborhood(_ tables: String) -> String {
    json(App.workspace.model.neighborhood(of: Edits.ids(object(tables)["tables"])).map(\.uuidString))
}

/// Untangling the selection, while it runs.
enum Untangling {
    nonisolated(unsafe) static var untangler: Untangler?
    /// The model it started from, and the ties it removes when it's done.
    nonisolated(unsafe) static var start = DataModel()
    nonisolated(unsafe) static var ties: Set<ZipTie.ID> = []
}

/// Starts untangling `tables` (and their groups' members): moving them to cross fewer wires. The ties on their wires go,
/// as on the Mac, since they'd hold wires where they were. Returns the zip ties to hide while it runs.
@JS public func untangleStart(_ tables: String) -> String {
    let model = App.workspace.model
    let moving = Edits.ids(object(tables)["tables"])
    guard !moving.isEmpty else { return "[]" }
    let columns = Set(model.tables.filter { moving.contains($0.id) }.flatMap(\.columns).map(\.id))
    let wires = Set(model.relationships.filter { columns.contains($0.from) || columns.contains($0.to) }.map(\.id))
    Untangling.ties = Set(model.zipTies.filter { $0.relationships.contains(where: wires.contains) }.map(\.id))
    Untangling.start = model
    Untangling.untangler = Untangler(model: model, moving: moving)
    return json(Untangling.ties.map(\.uuidString))
}

/// Runs untangling for about `milliseconds`, and returns where the tables are now, by how far they've moved:
/// `{"offsets": {id: [dx, dy]}, "progress": 0…1, "starting": n, "best": n, "done": bool}`.
@JS public func untangleStep(_ milliseconds: Double) -> String {
    guard var untangler = Untangling.untangler else { return "null" }
    let began = Date.now
    repeat { untangler.step() } while !untangler.isDone && Date.now.timeIntervalSince(began) * 1000 < milliseconds
    Untangling.untangler = untangler
    let offsets = Dictionary(uniqueKeysWithValues: untangler.offsets.map { ($0.key.uuidString, [$0.value.x, $0.value.y]) })
    return json(["offsets": offsets, "progress": untangler.progress, "starting": untangler.startingCrossings,
                 "best": untangler.best.crossings, "done": untangler.isDone])
}

/// Ends untangling: with `apply`, the tables go to the best arrangement found, if it crosses fewer wires than they
/// started with, and the ties on their wires are removed, as one change. Returns the crossings before and after.
@JS public func untangleFinish(apply: Bool) -> String {
    defer { Untangling.untangler = nil }
    guard apply, let untangler = Untangling.untangler else { return "null" }
    var untangled = App.workspace.model
    let improved = untangler.best.crossings < untangler.startingCrossings
    if improved {
        let offsets = untangler.bestOffsets
        for index in untangled.tables.indices {
            if let offset = offsets[untangled.tables[index].id] { untangled.tables[index].position += offset }
        }
    }
    for tie in Untangling.ties { untangled.removeZipTie(tie) }
    App.workspace.change(to: untangled)
    return json(["before": untangler.startingCrossings, "after": improved ? untangler.best.crossings : untangler.startingCrossings])
}
