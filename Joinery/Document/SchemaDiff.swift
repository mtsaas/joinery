import Foundation

/// What changed from one data model to another: tables, columns and foreign keys added, removed or changed. Tables and
/// columns are matched by ID, so a rename is a change, not one removed and another added; foreign keys by the columns
/// they join. Where things are, their colors, notes and sample data aren't changes.
struct SchemaDiff: Equatable {
    enum Change { case added, removed, modified }

    /// The later model with everything removed since put back, where it was, to draw the two at once.
    private(set) var model: DataModel
    private(set) var tables: [Table.ID: Change] = [:]
    private(set) var columns: [Column.ID: Change] = [:]
    private(set) var relationships: [Relationship.ID: Change] = [:]
    /// Rows in `model` for changed columns as they were, each just above the column as it is, marked removed.
    private(set) var formerly: Set<Column.ID> = []
    /// Renamed tables' earlier names.
    private(set) var oldNames: [Table.ID: String] = [:]

    init(from before: DataModel, to after: DataModel) {
        model = after
        let earlier = Dictionary(before.tables.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let later = Set(after.tables.map(\.id))
        for index in model.tables.indices {
            let table = model.tables[index]
            guard let old = earlier[table.id] else {
                tables[table.id] = .added
                for column in table.columns { columns[column.id] = .added }
                continue
            }
            if old.name != table.name { oldNames[table.id] = old.name }
            let now = Set(table.columns.map(\.id))
            let then = Dictionary(old.columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var merged: [Column] = []
            for column in table.columns {
                if let was = then[column.id], was != column {
                    // As a line diff shows a changed line: the old struck through, then the new.
                    var former = was
                    former.id = Self.former(of: column.id)
                    merged.append(former)
                    formerly.insert(former.id)
                    columns[former.id] = .removed
                    columns[column.id] = .modified
                } else if then[column.id] == nil {
                    columns[column.id] = .added
                }
                merged.append(column)
            }
            // Removed columns go back after the column they followed.
            for (row, column) in old.columns.enumerated() where !now.contains(column.id) {
                columns[column.id] = .removed
                let at = row == 0 ? 0 : merged.firstIndex { $0.id == old.columns[row - 1].id }.map { $0 + 1 } ?? merged.count
                merged.insert(column, at: at)
            }
            model.tables[index].columns = merged
            if oldNames[table.id] != nil || merged.contains(where: { columns[$0.id] != nil }) { tables[table.id] = .modified }
        }
        let groups = Set(after.groups.map(\.id))
        for var table in before.tables where !later.contains(table.id) {
            tables[table.id] = .removed
            for column in table.columns { columns[column.id] = .removed }
            if let group = table.group, !groups.contains(group) { table.group = nil }
            model.tables.append(table)
        }

        struct Ends: Hashable { let from, to: Column.ID }
        let then = Set(before.relationships.map { Ends(from: $0.from, to: $0.to) })
        let now = Set(after.relationships.map { Ends(from: $0.from, to: $0.to) })
        for relationship in after.relationships where !then.contains(Ends(from: relationship.from, to: relationship.to)) {
            relationships[relationship.id] = .added
        }
        for var relationship in before.relationships where !now.contains(Ends(from: relationship.from, to: relationship.to)) {
            relationships[relationship.id] = .removed
            relationship.zipTies = []
            model.relationships.append(relationship)
        }
    }

    /// The same every time for a column, so the model drawn doesn't change from one comparison to the next.
    private static func former(of id: Column.ID) -> Column.ID {
        var bytes = id.uuid
        bytes.0 ^= 0xFF
        return UUID(uuid: bytes)
    }

    var isEmpty: Bool { tables.isEmpty && relationships.isEmpty }

    /// "1 table added, 2 removed, 4 columns changed, 1 key removed", or "No changes".
    var summary: String {
        func count(_ changes: [UUID: Change], _ change: Change) -> Int { changes.values.count { $0 == change } }
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        // Columns of tables added or removed come with them; only the rest count, and a changed one once.
        let owners = model.columnLocations
        let changedColumns = columns.keys.count { !formerly.contains($0) && owners[$0].map { tables[$0.table.id] == .modified } ?? false }
        var parts: [String] = []
        for (noun, changes) in [("table", tables), ("key", relationships)] {
            let added = count(changes, .added), removed = count(changes, .removed)
            if added > 0 { parts.append(plural(added, noun) + " added") }
            if removed > 0 { parts.append((added > 0 ? "\(removed)" : plural(removed, noun)) + " removed") }
            if noun == "table", !oldNames.isEmpty { parts.append(plural(oldNames.count, "table") + " renamed") }
            if noun == "table", changedColumns > 0 { parts.append(plural(changedColumns, "column") + " changed") }
        }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

extension SchemaDiff {
    /// The changes listed, for an AI assistant to check against what it meant to change and to sum up: tables added,
    /// removed and changed, column by column, then foreign keys. `from` and `to` name the two sides.
    func report(from: String, to: String) -> String {
        guard !isEmpty else { return "No changes from \(from) to \(to)." }
        func describe(_ column: Column) -> String {
            [column.name, column.type.rawValue, column.isNullable ? "nullable" : nil, column.isPrimaryKey ? "primary key" : nil,
             column.isUnique ? "unique" : nil].compactMap { $0 }.joined(separator: " ")
        }
        var lines = ["\(from) → \(to): \(summary)."]
        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("\n\(title):")
            lines += items
        }
        section("Tables added", model.tables.filter { tables[$0.id] == .added }.map { table in
            "- \(table.name): " + table.columns.map(describe).joined(separator: ", ")
        })
        section("Tables removed", model.tables.filter { tables[$0.id] == .removed }.map { "- \($0.name)" })
        section("Tables changed", model.tables.filter { tables[$0.id] == .modified }.flatMap { table in
            ["- " + (oldNames[table.id].map { "\($0), renamed to \(table.name)" } ?? table.name)] + table.columns.compactMap { column in
                switch columns[column.id] {
                case .added: "  + \(describe(column))"
                case .removed where !formerly.contains(column.id): "  - \(describe(column))"
                case .modified:
                    table.columns.first { $0.id == Self.former(of: column.id) }.map { "  ~ \(describe($0)) → \(describe(column))" }
                default: nil
                }
            }
        })
        for (title, change) in [("Foreign keys added", Change.added), ("Foreign keys removed", .removed)] {
            section(title, model.relationships.filter { relationships[$0.id] == change }.compactMap { relationship in
                guard let from = model.qualifiedName(of: relationship.from), let to = model.qualifiedName(of: relationship.to) else { return nil }
                return "- \(from) → \(to)"
            })
        }
        return lines.joined(separator: "\n")
    }
}
