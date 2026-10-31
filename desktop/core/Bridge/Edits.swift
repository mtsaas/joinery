import Foundation

/// The canvas's edits, by name, each made with the core's own editing code, so the desktop app's change a model just
/// as the Mac's do. Arguments are JSON; IDs are UUID strings and points `[x, y]`.
enum Edits {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Makes the edit `name` on the open model, as one change and one undo.
    /// - Returns: JSON for whatever it made (a new table's ID, say), or `null`.
    static func edit(_ name: String, _ a: [String: Any], in workspace: Workspace) throws -> String {
        var model = workspace.model
        var result: Any = NSNull()
        switch name {
        case "move":
            model.move(tables: ids(a["tables"]), ties: ids(a["ties"]), by: point(a["by"]))
            model.regroup(ids(a["tables"]))
        case "addTable":
            result = model.addTable(at: point(a["at"])).uuidString
        case "removeTables":
            for id in ids(a["tables"]) as Set<UUID> { model.removeTable(id) }
            for id in ids(a["ties"]) as Set<UUID> { model.removeZipTie(id) }
            for id in ids(a["groups"]) as Set<UUID> { model.ungroup(id) }
            model.removeRelationships { ids(a["relationships"]).contains($0.id) }
            for id in ids(a["ports"]) as Set<UUID> { model.removePort(id) }
        case "renameTable":
            try update(&model, table: a["table"]) { $0.name = string(a["name"]) }
        case "setNotes":
            try update(&model, table: a["table"]) { $0.notes = string(a["notes"]) }
        case "recolor":
            guard let color = TableColor(rawValue: string(a["color"])) else { throw Failure("No color \(string(a["color"])).") }
            model.recolor(tables: ids(a["tables"]), groups: ids(a["groups"]), color)
        case "addColumn":
            result = model.addColumn(to: try uuid(a["table"]), after: a["after"].flatMap(optionalUUID))?.uuidString ?? NSNull()
        case "removeColumns":
            for id in ids(a["columns"]) as Set<UUID> { model.removeColumn(id) }
        case "setColumn":
            let id = try uuid(a["column"])
            guard let (table, row) = model.columnLocations[id], let index = model.tables.firstIndex(where: { $0.id == table.id }) else {
                throw Failure("No such column.")
            }
            var column = model.tables[index].columns[row]
            if let name = a["name"] as? String { column.name = name }
            if let type = a["type"] as? String {
                guard let parsed = DataType.parse(type) else { throw Failure("Unknown type “\(type)”.") }
                column.type = parsed.type
                if parsed.isNullable { column.isNullable = true }
            }
            if let flag = a["primaryKey"] as? Bool { column.isPrimaryKey = flag }
            if let flag = a["nullable"] as? Bool { column.isNullable = flag }
            if let flag = a["unique"] as? Bool { column.isUnique = flag }
            model.tables[index].columns[row] = column
        case "moveColumn":
            model.moveColumn(try uuid(a["column"]), in: try uuid(a["table"]), to: int(a["to"]))
        case "setSample":
            let table = try uuid(a["table"])
            guard let index = model.tables.firstIndex(where: { $0.id == table }) else { throw Failure("No such table.") }
            model.tables[index].setSample(int(a["row"]), try uuid(a["column"]), to: string(a["value"]))
        case "connect":
            let target: DataModel.DropTarget
            if let column = a["toColumn"].flatMap(optionalUUID) { target = .column(column) }
            else if let port = a["toPort"].flatMap(optionalUUID) { target = .port(port) }
            else { target = .table(try uuid(a["toTable"])) }
            result = model.connect(dragging: try uuid(a["column"]), onto: target)?.uuidString ?? NSNull()
        case "addBendPoint":
            let direction = point(a["direction"])
            result = model.addBendPoint(on: try uuid(a["wire"]), at: point(a["at"]), direction: direction, segment: int(a["segment"]))?
                .uuidString ?? NSNull()
        case "untie":
            model.untie(try uuid(a["wire"]), from: try uuid(a["tie"]))
        case "tie":
            model.tie(try uuid(a["wire"]), into: try uuid(a["tie"]), at: int(a["index"]), from: point(a["from"]), along: point(a["along"]))
        case "releaseTie":
            // Turns with its wires again, rather than held the way it was lined up.
            for id in ids(a["ties"]) as Set<UUID> {
                if let index = model.zipTies.firstIndex(where: { $0.id == id }) { model.zipTies[index].heldDirection = nil }
            }
        case "pullCable":
            // A pulled cable let go: out of the ties it was tugged out of, and into the one it's over.
            let cable = try uuid(a["cable"])
            for tie in ids(a["popped"]) as Set<UUID> { model.untie(cable, from: tie) }
            if let target = optionalUUID(a["into"]) {
                model.tie(cable, into: target, at: int(a["segment"]), from: point(a["point"]), along: point(a["along"]))
            }
        case "mergeTies":
            model.merge(try uuid(a["tie"]), by: point(a["by"]), into: try uuid(a["into"]), along: point(a["along"]))
        case "align":
            let alignments: [String: DataModel.Alignment] = ["left": .left, "center": .center, "right": .right,
                                                              "top": .top, "middle": .middle, "bottom": .bottom]
            guard let alignment = alignments[string(a["alignment"])] else { throw Failure("No alignment \(string(a["alignment"])).") }
            model.align(ids(a["tables"]), ties: ids(a["ties"]), alignment)
        case "distribute":
            model.distribute(ids(a["tables"]), horizontally: a["horizontally"] as? Bool ?? true)
        case "group":
            result = model.group(ids(a["tables"]), named: a["name"] as? String).uuidString
        case "renameGroup":
            let id = try uuid(a["group"])
            guard let index = model.groups.firstIndex(where: { $0.id == id }) else { throw Failure("No such group.") }
            model.groups[index].name = string(a["name"])
        case "ungroup":
            for id in ids(a["groups"]) as Set<UUID> { model.ungroup(id) }
        case "removeFromGroups":
            model.removeFromGroups(ids(a["tables"]))
        case "arrange":
            guard let layout = DataModel.Layout(rawValue: string(a["layout"])) else { throw Failure("No layout \(string(a["layout"])).") }
            let only: Set<UUID> = ids(a["tables"])
            model.arrange(layout, only: only.isEmpty ? nil : only)
        case "addPort":
            let group = try uuid(a["group"])
            if let column = a["column"].flatMap(optionalUUID) {
                result = model.addPort(to: group, for: column)?.uuidString ?? NSNull()
            } else {
                guard let side = Side4(rawValue: string(a["side"])) else { throw Failure("No side.") }
                result = model.addPort(to: group, at: (side, CGFloat(a["along"] as? Double ?? 0.5)))?.uuidString ?? NSNull()
            }
        case "plugPort":
            model.plug(try uuid(a["port"]), into: try uuid(a["column"]))
        case "movePort":
            let side = (a["side"] as? String).flatMap(Side4.init(rawValue:))
            model.movePort(try uuid(a["port"]), to: side.map { ($0, CGFloat(a["along"] as? Double ?? 0.5)) })
        case "bundle":
            for id in ids(a["groups"]) as Set<UUID> { _ = model.bundleSharedWires(in: id) }
        case "removePorts":
            for id in ids(a["groups"]) as Set<UUID> { model.removePorts(from: id) }
        case "paste":
            let clip = try JSONDecoder().decode(DataModel.self, from: Data(string(a["clip"]).utf8))
            let pasted = model.paste(clip, offset: point(a["offset"]))
            result = ["tables": pasted.tables.map(\.uuidString), "ties": pasted.ties.map(\.uuidString), "groups": pasted.groups.map(\.uuidString)]
        case "replace":
            // A whole model, as untangling's result or a version restored.
            model = try JSONDecoder().decode(DataModel.self, from: Data(string(a["model"]).utf8))
        default:
            // The assistant's tools work here too: create_tables, alter_table and the rest.
            guard ModelTools.names.contains(name) else { throw Failure("There's no edit called \(name).") }
            result = try ModelTools.call(name, a, on: &model)
        }
        workspace.change(to: model)
        return json(["result": result])
    }

    /// A clip of the selection, to copy: the tables, their groups and the wires among them.
    static func copy(_ a: [String: Any], in workspace: Workspace) -> String {
        let clip = workspace.model.clip(tables: ids(a["tables"]), groups: ids(a["groups"]))
        return (try? clip.fileData).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    // MARK: Arguments

    private static func update(_ model: inout DataModel, table: Any?, _ change: (inout Table) -> Void) throws {
        let id = try uuid(table)
        guard let index = model.tables.firstIndex(where: { $0.id == id }) else { throw Failure("No such table.") }
        change(&model.tables[index])
    }

    static func uuid(_ value: Any?) throws -> UUID {
        guard let id = optionalUUID(value) else { throw Failure("Expected an ID, not \(value ?? "nothing").") }
        return id
    }

    static func optionalUUID(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }

    static func ids(_ value: Any?) -> Set<UUID> { Set((value as? [String] ?? []).compactMap(UUID.init(uuidString:))) }

    static func point(_ value: Any?) -> CGPoint {
        let xy = value as? [Double] ?? []
        return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : .zero
    }

    static func offsets(_ value: Any?) -> [UUID: CGPoint] {
        Dictionary((value as? [String: [Double]] ?? [:]).compactMap { key, xy in
            UUID(uuidString: key).flatMap { id in xy.count == 2 ? (id, CGPoint(x: xy[0], y: xy[1])) : nil }
        }, uniquingKeysWith: { first, _ in first })
    }

    private static func string(_ value: Any?) -> String { value as? String ?? "" }
    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
}
