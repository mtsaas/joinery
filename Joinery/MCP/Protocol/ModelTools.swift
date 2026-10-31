import CoreGraphics
import Foundation

/// What an AI assistant can do to a model over MCP: read it, add, change and drop tables, and add and remove foreign
/// keys. Each call works on a copy and either applies whole or not at all, so it's one change, and one undo.
enum ModelTools {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Definitions

    nonisolated(unsafe) private static let columnSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["type": "string"],
            "type": ["type": "string", "description": "uuid, integer, bigint, numeric, text, varchar, boolean, date, timestamp, json or bytea; SQL spellings and aliases such as int, serial, decimal(10,2), varchar(255), jsonb also work. Defaults to text."],
            "primary_key": ["type": "boolean"],
            "nullable": ["type": "boolean", "description": "Columns are required (NOT NULL) unless nullable. A type ending in ? is nullable too."],
            "required": ["type": "boolean", "description": "The opposite of nullable."],
            "unique": ["type": "boolean"],
            "references": ["type": "string", "description": "Makes this a foreign key: \"table.column\", or just \"table\" for its primary key."],
        ],
        "required": ["name"],
    ]

    nonisolated(unsafe) private static let tableReference: [String: Any] = ["type": "string", "description": "The table's name."]

    nonisolated(unsafe) static let definitions: [[String: Any]] = [
        [
            "name": "get_model",
            "description": "The open data model: its schemas, and every table with its schema, its columns (type, primary key, nullable, unique), the foreign keys between them, and its notes and sample rows, if it has any. Columns not marked nullable are required. Also where everything is on the canvas, in points (y grows downward): each table's and schema's frame [x, y, width, height], and the bounds of it all. Read this before changing anything. With version, a named version instead (see list_versions), without changing anything.",
            "inputSchema": ["type": "object", "properties": ["version": ["type": "string", "description": "A named version to read instead of the model as it is."]]],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "create_tables",
            "description": "Adds one or more tables. Columns can reference tables created in the same call, so a whole data model can be made at once. They're placed for you, clear of every other table and schema: a schema's new tables together, beside the rest of that schema; otherwise beside the tables they reference; otherwise beside everything. Use move_tables to put them somewhere else.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "tables": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string"],
                                "columns": ["type": "array", "items": columnSchema],
                                "color": ["type": "string", "enum": TableColor.allCases.map(\.rawValue)],
                                "schema": ["type": "string", "description": "The schema it's in; made if there isn't one. Schemas are drawn as groups around their tables, and new tables are placed beside the rest of theirs."],
                                "notes": ["type": "string", "description": "What it's for, where its data comes from, anything to remember."],
                                "sample_rows": ["type": "array", "description": "Made-up rows showing the kind of data it holds: objects of column name to value.",
                                                "items": ["type": "object"]],
                            ],
                            "required": ["name", "columns"],
                        ],
                    ],
                ],
                "required": ["tables"],
            ],
        ],
        [
            "name": "alter_table",
            "description": "Changes a table: renames it, recolors it, adds, drops or changes columns, and adds or drops indexes on one or more columns (unique, as a compound unique constraint, or plain). A changed column's references can be set to a table or column, or to an empty string to drop its foreign key. A compound primary key is every column marked primary_key.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "table": tableReference,
                    "rename_to": ["type": "string"],
                    "color": ["type": "string", "enum": TableColor.allCases.map(\.rawValue)],
                    "schema": ["type": "string", "description": "Moves it into this schema (made if need be), or out of any for an empty string."],
                    "notes": ["type": "string", "description": "Replaces its notes: what it's for, where its data comes from, anything to remember."],
                    "add_columns": ["type": "array", "items": columnSchema],
                    "drop_columns": ["type": "array", "items": ["type": "string"]],
                    "change_columns": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string", "description": "The column's current name."],
                                "rename_to": ["type": "string"],
                                "type": ["type": "string"],
                                "primary_key": ["type": "boolean"],
                                "nullable": ["type": "boolean"],
                                "required": ["type": "boolean"],
                                "unique": ["type": "boolean"],
                                "references": ["type": "string"],
                            ],
                            "required": ["name"],
                        ],
                    ],
                    "add_indexes": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "columns": ["type": "array", "items": ["type": "string"], "description": "One or more of its columns, in order."],
                                "unique": ["type": "boolean", "description": "Defaults to true: no two rows with the same values in all of them."],
                                "name": ["type": "string", "description": "Its name in SQL; left out, one made from the table's and columns' names."],
                            ],
                            "required": ["columns"],
                        ],
                    ],
                    "drop_indexes": ["type": "array", "items": ["type": "string"], "description": "Indexes to drop, by name."],
                ],
                "required": ["table"],
            ],
        ],
        [
            "name": "drop_tables",
            "description": "Removes tables, and every foreign key to or from them.",
            "inputSchema": [
                "type": "object",
                "properties": ["tables": ["type": "array", "items": tableReference]],
                "required": ["tables"],
            ],
            "annotations": ["destructiveHint": true],
        ],
        [
            "name": "set_schema",
            "description": "Makes or changes a schema, drawn as a group around its tables: puts tables in it (out of any other), renames or recolors it. Tables that would stretch the schema over others are moved beside the rest of it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "schema": ["type": "string"],
                    "tables": ["type": "array", "items": tableReference],
                    "rename_to": ["type": "string"],
                    "color": ["type": "string", "enum": TableColor.allCases.map(\.rawValue)],
                ],
                "required": ["schema"],
            ],
        ],
        [
            "name": "drop_schema",
            "description": "Removes a schema's grouping; its tables stay, in no schema.",
            "inputSchema": ["type": "object", "properties": ["schema": ["type": "string"]], "required": ["schema"]],
        ],
        [
            "name": "arrange",
            "description": "Lays tables out afresh: every table, or only `tables` (kept where they were, clear of the rest). orthogonal_groups packs each schema (and each set of joined tables) as a compact block, as DataGrip does; hierarchical puts referenced tables left of those referencing them. Removes the zip ties and bend points on their wires, which the old positions placed. Good after making many tables.",
            "inputSchema": [
                "type": "object",
                "properties": ["layout": ["type": "string", "enum": ["orthogonal_groups", "hierarchical"]],
                               "tables": ["type": "array", "items": tableReference]],
                "required": ["layout"],
            ],
        ],
        [
            "name": "move_tables",
            "description": "Moves tables, together as a compact block in rows. Give `near` (a table or schema) to put them in the nearest open space beside it, clear of everything else; or `x` and `y` for the block's top left, in canvas points (y grows downward), as get_model reports them.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "tables": ["type": "array", "items": tableReference],
                    "near": ["type": "string", "description": "A table or schema to put them beside."],
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                ],
                "required": ["tables"],
            ],
        ],
        [
            "name": "set_sample_data",
            "description": "Sets a table's sample data: made-up rows showing the kind of data it holds, shown as a spreadsheet in its designer. Each row is an object of column name to value; columns left out are blank. Replaces the rows there, unless `append`.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "table": tableReference,
                    "rows": ["type": "array", "items": ["type": "object", "additionalProperties": ["type": ["string", "number", "boolean", "null"]]]],
                    "append": ["type": "boolean"],
                ],
                "required": ["table", "rows"],
            ],
        ],
        [
            "name": "add_foreign_key",
            "description": "Makes a column a foreign key to another: from \"orders.user_id\" to \"users.id\", or to \"users\" for its primary key.",
            "inputSchema": [
                "type": "object",
                "properties": ["from": ["type": "string"], "to": ["type": "string"]],
                "required": ["from", "to"],
            ],
        ],
        [
            "name": "remove_foreign_key",
            "description": "Removes the foreign keys from a column (\"orders.user_id\"), or only the one to `to`.",
            "inputSchema": [
                "type": "object",
                "properties": ["from": ["type": "string"], "to": ["type": "string"]],
                "required": ["from"],
            ],
        ],
    ]

    static var names: Set<String> { Set(definitions.compactMap { $0["name"] as? String }) }

    // MARK: Calls

    /// Runs `name` on `model`, which is left alone if it fails.
    /// - Returns: What happened, for the assistant.
    static func call(_ name: String, _ arguments: [String: Any], on model: inout DataModel) throws -> String {
        var draft = model
        let result: String
        switch name {
        case "get_model": return try describe(model)
        case "create_tables": result = try createTables(arguments, in: &draft)
        case "alter_table": result = try alterTable(arguments, in: &draft)
        case "drop_tables": result = try dropTables(arguments, in: &draft)
        case "set_schema": result = try setSchema(arguments, in: &draft)
        case "move_tables": result = try moveTables(arguments, in: &draft)
        case "set_sample_data":
            let id = try table(named: string("table", in: arguments), in: draft).id
            let rows = arguments["rows"] as? [[String: Any]] ?? []
            try setSamples(rows, of: id, appending: arguments["append"] as? Bool ?? false, in: &draft)
            let count = draft.table(id)?.samples.count ?? 0
            result = "\(draft.table(id)?.name ?? "") has \(count) sample row\(count == 1 ? "" : "s")."
        case "arrange":
            let name = try string("layout", in: arguments)
            guard let layout = DataModel.Layout.allCases.first(where: { $0.rawValue == name.replacingOccurrences(of: "_g", with: "G") })
            else { throw Failure("Unknown layout “\(name)”: use orthogonal_groups or hierarchical.") }
            let only = try (arguments["tables"] as? [String]).map { try Set($0.map { try table(named: $0, in: draft).id }) }
            draft.arrange(layout, only: only)
            result = "Laid out \(only?.count ?? draft.tables.count) tables, \(layout.title.lowercased())."
        case "drop_schema":
            let name = try string("schema", in: arguments)
            draft.ungroup(try group(named: name, in: draft).id)
            result = "Dropped the schema \(name); its tables stay."
        case "add_foreign_key":
            let from = try column(named: string("from", in: arguments), in: draft)
            let to = try column(named: string("to", in: arguments), in: draft)
            guard draft.connect(from, to: to) != nil else { throw Failure("That foreign key already exists.") }
            result = "Added \(draft.qualifiedName(of: from)!) → \(draft.qualifiedName(of: to)!)."
        case "remove_foreign_key":
            let from = try column(named: string("from", in: arguments), in: draft)
            let to = try (arguments["to"] as? String).map { try column(named: $0, in: draft) }
            let count = draft.relationships.count
            draft.removeRelationships { $0.from == from && (to == nil || $0.to == to) }
            guard draft.relationships.count < count else { throw Failure("There's no such foreign key.") }
            result = "Removed \(count - draft.relationships.count) foreign key\(count - draft.relationships.count == 1 ? "" : "s")."
        default: throw Failure("There's no tool called \(name).")
        }
        model = draft
        return result
    }

    /// The model as JSON: tables in order, each column's foreign key as "table.column".
    static func describe(_ model: DataModel) throws -> String {
        let references = Dictionary(model.relationships.compactMap { r in model.qualifiedName(of: r.to).map { (r.from, $0) } },
                                    uniquingKeysWith: { first, _ in first })
        let groupNames = Dictionary(model.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let schemas: [[String: Any]] = model.groups.map { group in
            ["name": group.name, "color": group.color.rawValue, "tables": model.members(of: group.id).map(\.name),
             "frame": model.frame(of: group.id).map(frame) ?? NSNull()]
        }
        let tables: [[String: Any]] = model.tables.map { table in
            var description: [String: Any] = [
                "name": table.name,
                "schema": table.group.flatMap { groupNames[$0] } ?? NSNull(),
                "color": table.color.rawValue,
                "frame": frame(Metrics.frame(of: table)),
                "columns": table.columns.map { column -> [String: Any] in
                    var description: [String: Any] = ["name": column.name, "type": column.type.rawValue]
                    if column.isPrimaryKey { description["primary_key"] = true }
                    if column.isNullable { description["nullable"] = true }
                    if column.isUnique { description["unique"] = true }
                    if let reference = references[column.id] { description["references"] = reference }
                    return description
                },
            ]
            if !table.liveIndexes.isEmpty {
                description["indexes"] = table.liveIndexes.map { index -> [String: Any] in
                    ["name": table.name(of: index), "columns": table.columns(of: index).map(\.name), "unique": index.isUnique]
                }
            }
            if !table.notes.isEmpty { description["notes"] = table.notes }
            // Its sample rows, by column name.
            if !table.samples.isEmpty {
                description["sample_rows"] = table.samples.indices.map { row in
                    Dictionary(table.columns.compactMap { column in
                        let value = table.sample(row, column.id)
                        return value.isEmpty ? nil : (column.name, value)
                    }, uniquingKeysWith: { first, _ in first })
                }
            }
            return description
        }
        let data = try JSONSerialization.data(withJSONObject: ["schemas": schemas, "tables": tables, "bounds": model.bounds.map(frame) ?? NSNull()],
                                              options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func createTables(_ arguments: [String: Any], in model: inout DataModel) throws -> String {
        guard let specs = arguments["tables"] as? [[String: Any]], !specs.isEmpty else { throw Failure("Give at least one table.") }
        // Every table first, so columns can reference any of them.
        var pending: [(column: Column.ID, references: String)] = []
        var names: [String] = [], created: [Table.ID] = []
        for spec in specs {
            let name = try string("name", in: spec)
            guard model.tables.allSatisfy({ $0.name.lowercased() != name.lowercased() }) else {
                throw Failure("There's already a table called \(name).")
            }
            let id = model.addTable(at: .zero)
            let index = model.tables.count - 1
            model.tables[index].name = name
            if let color = spec["color"] as? String { model.tables[index].color = try tableColor(color) }
            let columns = try (spec["columns"] as? [Any] ?? []).map { try column($0) }
            if !columns.isEmpty { model.tables[index].columns = columns.map(\.column) }
            try requireUniqueColumns(model.tables[index])
            if let notes = spec["notes"] as? String { model.tables[index].notes = notes }
            if let rows = spec["sample_rows"] as? [[String: Any]] { try setSamples(rows, of: id, appending: false, in: &model) }
            pending += columns.compactMap { column in column.references.map { (column.column.id, $0) } }
            if let schema = spec["schema"] as? String, !schema.isEmpty { assign([id], toSchema: schema, in: &model) }
            created.append(id)
            names.append(name)
        }
        for (column, reference) in pending {
            model.connect(column, to: try self.column(named: reference, in: model))
        }
        // Each schema's new tables together, beside the rest of the schema; or beside the tables they're joined to;
        // or beside everything. Clear of the rest either way.
        var unplaced = Set(created)
        let batches = Dictionary(grouping: created) { model.table($0)?.group }
        for (group, batch) in batches.sorted(by: { ($0.key?.uuidString ?? "") < ($1.key?.uuidString ?? "") }) {
            unplaced.subtract(batch)
            let placed = Set(created).subtracting(unplaced)
            let company = group.map { group in model.members(of: group).filter { !placed.contains($0.id) && !unplaced.contains($0.id) } } ?? []
            let joined = model.neighborhood(of: Set(batch)).subtracting(created).compactMap { model.table($0) }
            let anchor = (company.isEmpty ? joined : company).map(Metrics.frame).reduce(nil) { $0?.union($1) ?? $1 }
            model.place(batch, near: anchor, ignoring: unplaced)
        }
        let keys = pending.count
        return "Created \(names.joined(separator: ", "))" + (keys > 0 ? " with \(keys) foreign key\(keys == 1 ? "" : "s")." : ".")
    }

    /// Rows of column name to value, as a table's sample rows, in place of those there or after them.
    private static func setSamples(_ rows: [[String: Any]], of id: Table.ID, appending: Bool, in model: inout DataModel) throws {
        guard let index = model.tables.firstIndex(where: { $0.id == id }) else { return }
        let table = model.tables[index]
        let columns = Dictionary(table.columns.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
        let samples = try rows.map { row in
            try row.reduce(into: [String: String]()) { sample, entry in
                guard let column = columns[entry.key.lowercased()] else {
                    throw Failure("\(table.name) has no column called \(entry.key). Columns: \(table.columns.map(\.name).joined(separator: ", ")).")
                }
                let value: String? = switch entry.value {
                case let text as String: text
                case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): number.boolValue ? "true" : "false"
                case let number as NSNumber: number.stringValue
                default: nil
                }
                if let value, !value.isEmpty { sample[column.uuidString] = value }
            }
        }
        model.tables[index].samples = (appending ? table.samples : []) + samples
    }

    private static func moveTables(_ arguments: [String: Any], in model: inout DataModel) throws -> String {
        let ids = try (arguments["tables"] as? [String] ?? []).map { try table(named: $0, in: model).id }
        guard !ids.isEmpty else { throw Failure("Give at least one table.") }
        if let near = arguments["near"] as? String, !near.isEmpty {
            let frames: [CGRect]
            if let table = model.tables.first(where: { $0.name.lowercased() == near.lowercased() }) {
                frames = [Metrics.frame(of: table)]
            } else {
                frames = try model.members(of: group(named: near, in: model).id).filter { !ids.contains($0.id) }.map(Metrics.frame)
            }
            model.place(ids, near: frames.reduce(nil) { $0?.union($1) ?? $1 })
        } else if let x = arguments["x"] as? Double, let y = arguments["y"] as? Double {
            model.place(ids, at: CGPoint(x: x, y: y))
        } else {
            throw Failure("Give `near`, or `x` and `y`.")
        }
        let frame = ids.compactMap { model.table($0) }.map(Metrics.frame).reduce(nil) { $0?.union($1) ?? $1 } ?? .zero
        return "Moved \(ids.count) table\(ids.count == 1 ? "" : "s") to \(Self.frame(frame))."
    }

    /// A frame as get_model gives it: [x, y, width, height], whole points.
    private static func frame(_ rect: CGRect) -> [Int] {
        [Int(rect.minX.rounded()), Int(rect.minY.rounded()), Int(rect.width.rounded()), Int(rect.height.rounded())]
    }

    private static func alterTable(_ arguments: [String: Any], in model: inout DataModel) throws -> String {
        let id = try table(named: string("table", in: arguments), in: model).id
        var index: Int { model.tables.firstIndex { $0.id == id }! }
        var changes: [String] = []
        if let name = arguments["rename_to"] as? String, !name.isEmpty {
            guard model.tables.allSatisfy({ $0.id == id || $0.name.lowercased() != name.lowercased() }) else {
                throw Failure("There's already a table called \(name).")
            }
            model.tables[index].name = name
            changes.append("renamed it \(name)")
        }
        if let notes = arguments["notes"] as? String {
            model.tables[index].notes = notes
            changes.append("set its notes")
        }
        if let color = arguments["color"] as? String {
            model.tables[index].color = try tableColor(color)
            changes.append("made it \(color)")
        }
        if let schema = arguments["schema"] as? String {
            if schema.isEmpty {
                model.removeFromGroups([id])
                changes.append("took it out of its schema")
            } else {
                assign([id], toSchema: schema, in: &model)
                changes.append("put it in \(schema)")
            }
        }
        for name in arguments["drop_columns"] as? [String] ?? [] {
            model.removeColumn(try column(named: name, in: model.tables[index]).id)
            changes.append("dropped \(name)")
        }
        for spec in arguments["change_columns"] as? [[String: Any]] ?? [] {
            let name = try string("name", in: spec)
            let columnID = try column(named: name, in: model.tables[index]).id
            let row = model.tables[index].columns.firstIndex { $0.id == columnID }!
            if let newName = spec["rename_to"] as? String, !newName.isEmpty { model.tables[index].columns[row].name = newName }
            if let type = spec["type"] as? String {
                let parsed = try dataType(type)
                model.tables[index].columns[row].type = parsed.type
                if parsed.isNullable { model.tables[index].columns[row].isNullable = true }
            }
            if let isPrimaryKey = spec["primary_key"] as? Bool { model.tables[index].columns[row].isPrimaryKey = isPrimaryKey }
            if let isNullable = nullability(spec) { model.tables[index].columns[row].isNullable = isNullable }
            if let isUnique = spec["unique"] as? Bool { model.tables[index].columns[row].isUnique = isUnique }
            if let reference = spec["references"] as? String {
                model.removeRelationships { $0.from == columnID }
                if !reference.isEmpty { model.connect(columnID, to: try column(named: reference, in: model)) }
            }
            changes.append("changed \(name)")
        }
        let added = try (arguments["add_columns"] as? [Any] ?? []).map { try column($0) }
        model.tables[index].columns += added.map(\.column)
        for (column, reference) in added.compactMap({ c in c.references.map { (c.column.id, $0) } }) {
            model.connect(column, to: try self.column(named: reference, in: model))
        }
        if !added.isEmpty { changes.append("added \(added.map(\.column.name).joined(separator: ", "))") }
        for name in arguments["drop_indexes"] as? [String] ?? [] {
            let table = model.tables[index]
            guard let dropped = table.indexes.first(where: { table.name(of: $0).lowercased() == name.lowercased() }) else {
                throw Failure("\(table.name) has no index called \(name).")
            }
            model.tables[index].indexes.removeAll { $0.id == dropped.id }
            changes.append("dropped index \(name)")
        }
        for spec in arguments["add_indexes"] as? [[String: Any]] ?? [] {
            let names = spec["columns"] as? [String] ?? []
            let columns = try names.map { try column(named: $0, in: model.tables[index]).id }
            guard !columns.isEmpty, Set(columns).count == columns.count else { throw Failure("An index needs one or more columns, each once.") }
            let name = (spec["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let id = model.tables[index].addIndex(on: columns, isUnique: spec["unique"] as? Bool ?? true, name: name)
            let table = model.tables[index]
            changes.append("added index \(table.indexes.first { $0.id == id }.map(table.name(of:)) ?? names.joined(separator: ", "))")
        }
        try requireUniqueColumns(model.tables[index])
        guard !changes.isEmpty else {
            throw Failure("Nothing to change: give rename_to, color, schema, add_columns, drop_columns, change_columns, add_indexes or drop_indexes.")
        }
        return "\(model.tables[index].name): " + changes.joined(separator: "; ") + "."
    }

    private static func dropTables(_ arguments: [String: Any], in model: inout DataModel) throws -> String {
        guard let names = arguments["tables"] as? [String], !names.isEmpty else { throw Failure("Give the tables to drop.") }
        for name in names { model.removeTable(try table(named: name, in: model).id) }
        return "Dropped \(names.joined(separator: ", "))."
    }

    private static func setSchema(_ arguments: [String: Any], in model: inout DataModel) throws -> String {
        let name = try string("schema", in: arguments)
        let tables = try (arguments["tables"] as? [String] ?? []).map { try table(named: $0, in: model).id }
        let existing = model.groups.first { $0.name.lowercased() == name.lowercased() }
        guard existing != nil || !tables.isEmpty else { throw Failure("There's no schema called \(name); give tables to make it with.") }
        let before = existing.map { model.members(of: $0.id).map(\.id) } ?? []
        let id = assign(Set(tables), toSchema: name, in: &model)
        // Tables from elsewhere would stretch it over others: they're brought beside the rest of it, clear of the others.
        if model.isCrowded(id) {
            let joining = tables.filter { !before.contains($0) }
            let company = before.compactMap { model.table($0) }.map(Metrics.frame).reduce(nil) { $0?.union($1) ?? $1 }
            let moving = company == nil ? model.members(of: id).map(\.id) : joining
            model.place(moving, near: company ?? moving.compactMap { model.table($0) }.map(Metrics.frame).reduce(nil) { $0?.union($1) ?? $1 })
        }
        let index = model.groups.firstIndex { $0.id == id }!
        if let color = arguments["color"] as? String { model.groups[index].color = try tableColor(color) }
        if let rename = arguments["rename_to"] as? String, !rename.isEmpty {
            guard !model.groups.contains(where: { $0.id != id && $0.name.lowercased() == rename.lowercased() }) else {
                throw Failure("There's already a schema called \(rename).")
            }
            model.groups[index].name = rename
        }
        let members = model.members(of: id).map(\.name)
        return "\(model.groups[index].name): \(members.joined(separator: ", "))."
    }

    /// The schema (group) called `name`, with `ids` put in it; made if there isn't one.
    @discardableResult
    private static func assign(_ ids: Set<Table.ID>, toSchema name: String, in model: inout DataModel) -> TableGroup.ID {
        guard let group = model.groups.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            return model.group(ids, named: name)
        }
        for index in model.tables.indices where ids.contains(model.tables[index].id) { model.tables[index].group = group.id }
        model.removeEmptyGroups()
        return group.id
    }

    private static func group(named name: String, in model: DataModel) throws -> TableGroup {
        guard let group = model.groups.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw Failure("There's no schema called \(name). Schemas: \(model.groups.map(\.name).joined(separator: ", ")).")
        }
        return group
    }

    // MARK: Reading arguments

    private static func string(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else { throw Failure("“\(key)” is required.") }
        return value
    }

    private static func column(_ spec: Any) throws -> (column: Column, references: String?) {
        guard let spec = spec as? [String: Any] else { throw Failure("Each column is an object with a name and type.") }
        let parsed = try dataType(spec["type"] as? String ?? "text")
        let column = Column(name: try string("name", in: spec), type: parsed.type,
                            isPrimaryKey: spec["primary_key"] as? Bool ?? false,
                            isNullable: nullability(spec) ?? parsed.isNullable, isUnique: spec["unique"] as? Bool ?? false)
        return (column, (spec["references"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// From `nullable`, or `required`, its opposite.
    private static func nullability(_ spec: [String: Any]) -> Bool? {
        spec["nullable"] as? Bool ?? (spec["required"] as? Bool).map { !$0 }
    }

    /// A type as SQL might spell it: "VARCHAR(255)", "decimal(10, 2)", "timestamp with time zone", "int?".
    static func dataType(_ text: String) throws -> (type: DataType, isNullable: Bool) {
        let isNullable = text.hasSuffix("?")
        let word = text.split(whereSeparator: { "( ?".contains($0) }).first.map(String.init) ?? ""
        guard let parsed = DataType.parse(word) else {
            throw Failure("Unknown type “\(text)”. Use one of: \(DataType.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return (parsed.type, isNullable)
    }

    private static func tableColor(_ name: String) throws -> TableColor {
        guard let color = TableColor(rawValue: name.lowercased()) else {
            throw Failure("Unknown color “\(name)”. Use one of: \(TableColor.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return color
    }

    private static func table(named name: String, in model: DataModel) throws -> Table {
        guard let table = model.tables.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw Failure("There's no table called \(name). Tables: \(model.tables.map(\.name).joined(separator: ", ")).")
        }
        return table
    }

    private static func column(named name: String, in table: Table) throws -> Column {
        guard let column = table.columns.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw Failure("\(table.name) has no column called \(name). Its columns: \(table.columns.map(\.name).joined(separator: ", ")).")
        }
        return column
    }

    /// "table.column", or "table" for its primary key.
    private static func column(named reference: String, in model: DataModel) throws -> Column.ID {
        let parts = reference.split(separator: ".", maxSplits: 1).map(String.init)
        let table = try table(named: parts.first ?? reference, in: model)
        if parts.count == 2 { return try column(named: parts[1], in: table).id }
        let keys = table.columns.filter(\.isPrimaryKey)
        guard keys.count == 1 else {
            throw Failure("\(table.name) has \(keys.isEmpty ? "no" : "a compound") primary key; name the column: \(table.name).<column>.")
        }
        return keys[0].id
    }

    private static func requireUniqueColumns(_ table: Table) throws {
        var seen: Set<String> = []
        for column in table.columns where !seen.insert(column.name.lowercased()).inserted {
            throw Failure("\(table.name) would have two columns called \(column.name).")
        }
    }
}
