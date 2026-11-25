import Foundation

/// What changed from one data model to another: tables, columns, indexes, notes, schemas and foreign keys added,
/// removed or changed. Tables, columns and indexes are matched by ID, so a rename is a change, not one removed and
/// another added; foreign keys by the columns they join. Where things are, their colors and sample data aren't changes.
struct SchemaDiff: Equatable {
    enum Change { case added, removed, modified }
    /// A line about a table besides its columns: its schema, an index or a line of its notes, as it was or as it is.
    struct Detail: Equatable {
        var change: Change
        var text: String
    }

    /// The later model with everything removed since put back, where it was, to draw the two at once.
    private(set) var model: DataModel
    private(set) var tables: [Table.ID: Change] = [:]
    private(set) var columns: [Column.ID: Change] = [:]
    private(set) var relationships: [Relationship.ID: Change] = [:]
    /// Rows in `model` for changed columns as they were, each just above the column as it is, marked removed.
    private(set) var formerly: Set<Column.ID> = []
    /// Renamed tables' earlier names.
    private(set) var oldNames: [Table.ID: String] = [:]
    /// Tables' schema, index and notes changes, the old lines before the new; for tables added, all they have.
    private(set) var details: [Table.ID: [Detail]] = [:]

    init(from before: DataModel, to after: DataModel) {
        model = after
        let earlier = Dictionary(before.tables.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let later = Set(after.tables.map(\.id))
        for index in model.tables.indices {
            let table = model.tables[index]
            guard let old = earlier[table.id] else {
                tables[table.id] = .added
                for column in table.columns { columns[column.id] = .added }
                let added = Self.details(from: nil, before, to: table, after)
                if !added.isEmpty { details[table.id] = added }
                continue
            }
            if old.name != table.name { oldNames[table.id] = old.name }
            let changed = Self.details(from: old, before, to: table, after)
            if !changed.isEmpty { details[table.id] = changed }
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
            if oldNames[table.id] != nil || details[table.id] != nil || merged.contains(where: { columns[$0.id] != nil }) {
                tables[table.id] = .modified
            }
        }
        // A removed table keeps its group, and a group removed with it comes back too, so laying them out keeps it.
        var groups = Set(after.groups.map(\.id))
        for table in before.tables where !later.contains(table.id) {
            tables[table.id] = .removed
            for column in table.columns { columns[column.id] = .removed }
            if let id = table.group, !groups.contains(id), let group = before.groups.first(where: { $0.id == id }) {
                groups.insert(id)
                model.groups.append(group)
            }
            model.tables.append(table)
        }

        struct Ends: Hashable { let from, to: Column.ID }
        let then = Set(before.relationships.map { Ends(from: $0.from, to: $0.to) })
        let now = Set(after.relationships.map { Ends(from: $0.from, to: $0.to) })
        let wasImplicit = Dictionary(before.relationships.map { (Ends(from: $0.from, to: $0.to), $0.isImplicit) }, uniquingKeysWith: { first, _ in first })
        for relationship in after.relationships {
            let ends = Ends(from: relationship.from, to: relationship.to)
            if !then.contains(ends) {
                relationships[relationship.id] = .added
            } else if wasImplicit[ends] != relationship.isImplicit {
                relationships[relationship.id] = .modified
            }
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

    /// How a table's schema, indexes and notes changed from `old` (nil, it's new): each changed index as it was then as
    /// it is, matched by ID; notes line by line, all the old then all the new.
    private static func details(from old: Table?, _ before: DataModel, to new: Table, _ after: DataModel) -> [Detail] {
        func schema(_ table: Table?, _ model: DataModel) -> String? {
            table?.group.flatMap { id in model.groups.first { $0.id == id }?.name }
        }
        func describe(_ index: TableIndex, in table: Table) -> String {
            (index.isUnique ? "unique " : "") + "index \(table.name(of: index)) (\(table.columns(of: index).map(\.name).joined(separator: ", ")))"
        }
        func notes(_ table: Table?) -> [String] {
            let text = table?.notes.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? [] : text.components(separatedBy: .newlines).map { "note: \($0)" }
        }
        var lines: [Detail] = []
        let then = schema(old, before), now = schema(new, after)
        if then != now {
            if let then { lines.append(Detail(change: .removed, text: "schema \(then)")) }
            if let now { lines.append(Detail(change: .added, text: "schema \(now)")) }
        }
        // Colors aren't changes; what an index is on, whether it's unique and its name are.
        let was = Dictionary((old?.liveIndexes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(new.liveIndexes.map(\.id))
        for index in new.liveIndexes {
            if let old, let former = was[index.id] {
                guard old.columns(of: former).map(\.id) != new.columns(of: index).map(\.id) || former.isUnique != index.isUnique
                        || former.name != index.name else { continue }
                lines.append(Detail(change: .removed, text: describe(former, in: old)))
            }
            lines.append(Detail(change: .added, text: describe(index, in: new)))
        }
        if let old {
            lines += old.liveIndexes.filter { !kept.contains($0.id) }.map { Detail(change: .removed, text: describe($0, in: old)) }
        }
        let oldNotes = notes(old), newNotes = notes(new)
        if oldNotes != newNotes {
            lines += oldNotes.map { Detail(change: .removed, text: $0) } + newNotes.map { Detail(change: .added, text: $0) }
        }
        return lines
    }

    /// `model` without the tables and foreign keys removed: the changes to what's still there.
    var modelWithoutRemoved: DataModel {
        var shown = model
        shown.tables.removeAll { tables[$0.id] == .removed }
        shown.relationships.removeAll { relationships[$0.id] == .removed }
        shown.removeEmptyGroups()
        return shown
    }

    var isEmpty: Bool { tables.isEmpty && relationships.isEmpty }

    /// "1 table added, 2 removed, 4 columns changed, 1 key removed", or "No changes".
    var summary: String {
        func count(_ changes: [UUID: Change], _ change: Change) -> Int { changes.values.count { $0 == change } }
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        // Columns of tables added or removed come with them; only the rest count, and a changed one once.
        let owners = model.columnLocations
        let changedColumns = columns.keys.count { !formerly.contains($0) && owners[$0].map { tables[$0.table.id] == .modified } ?? false }
        // Tables changed only in their indexes, notes or schema, which nothing above counts.
        let otherChanges = details.keys.count { id in
            tables[id] == .modified && oldNames[id] == nil
                && !(model.table(id)?.columns.contains { columns[$0.id] != nil } ?? false)
        }
        var parts: [String] = []
        for (noun, changes) in [("table", tables), ("key", relationships)] {
            let added = count(changes, .added), removed = count(changes, .removed)
            if added > 0 { parts.append(plural(added, noun) + " added") }
            if removed > 0 { parts.append((added > 0 ? "\(removed)" : plural(removed, noun)) + " removed") }
            if noun == "table", !oldNames.isEmpty { parts.append(plural(oldNames.count, "table") + " renamed") }
            if noun == "table", changedColumns > 0 { parts.append(plural(changedColumns, "column") + " changed") }
            if noun == "table", otherChanges > 0 { parts.append("indexes, notes or schema changed on " + plural(otherChanges, "table")) }
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
        section("Tables added", model.tables.filter { tables[$0.id] == .added }.map { table -> String in
            let head = "- \(table.name): " + table.columns.map(describe).joined(separator: ", ")
            let rest: [String] = (details[table.id] ?? []).map { "  \($0.text)" }
            return ([head] + rest).joined(separator: "\n")
        })
        section("Tables removed", model.tables.filter { tables[$0.id] == .removed }.map { "- \($0.name)" })
        section("Tables changed", model.tables.filter { tables[$0.id] == .modified }.flatMap { table -> [String] in
            let head = "- " + (oldNames[table.id].map { "\($0), renamed to \(table.name)" } ?? table.name)
            let changed: [String] = table.columns.compactMap { column -> String? in
                switch columns[column.id] {
                case .added: "  + \(describe(column))"
                case .removed where !formerly.contains(column.id): "  - \(describe(column))"
                case .modified:
                    table.columns.first { $0.id == Self.former(of: column.id) }.map { "  ~ \(describe($0)) → \(describe(column))" }
                default: nil
                }
            }
            let other: [String] = (details[table.id] ?? []).map { "  \($0.change == .removed ? "-" : "+") \($0.text)" }
            return [head] + changed + other
        })
        for (title, change) in [("Foreign keys added", Change.added), ("Foreign keys removed", .removed), ("Foreign keys changed", .modified)] {
            section(title, model.relationships.filter { relationships[$0.id] == change }.compactMap { relationship in
                guard let from = model.qualifiedName(of: relationship.from), let to = model.qualifiedName(of: relationship.to) else { return nil }
                // Only whether it's implicit changes one that's still there.
                let kind = change == .modified ? (relationship.isImplicit ? ", now implicit (no constraint)" : ", now a foreign key constraint")
                    : relationship.isImplicit ? " (implicit, no constraint)" : ""
                return "- \(from) → \(to)\(kind)"
            })
        }
        return lines.joined(separator: "\n")
    }

    /// The changes as Markdown, for an AI assistant to make them, in code or migrations: like a patch, only what
    /// changed, as + and - lines. A changed column is its old line then its new one.
    func markdown(from: String, to: String, title: String) -> String {
        var lines = ["# \(title): \(from) → \(to)", ""]
        guard !isEmpty else { return (lines + ["No changes.", ""]).joined(separator: "\n") }
        func describe(_ column: Column) -> String {
            [column.name, column.type.rawValue, column.isNullable ? "nullable" : nil, column.isPrimaryKey ? "primary key" : nil,
             column.isUnique ? "unique" : nil].compactMap { $0 }.joined(separator: " ")
        }
        func detailLines(_ table: Table) -> [String] {
            (details[table.id] ?? []).map { "\($0.change == .removed ? "-" : "+")   \($0.text)" }
        }
        var blocks: [[String]] = []
        for table in model.tables {
            switch tables[table.id] {
            case .added:
                let added: [String] = table.columns.map { "+   \(describe($0))" }
                blocks.append(["+ table \(table.name)"] + added + detailLines(table))
            case .removed: blocks.append(["- table \(table.name)"])
            case .modified:
                // Old rows of changed columns sit just above the new, so in order they read as a patch does.
                let head: [String] = oldNames[table.id].map { ["- table \($0)", "+ table \(table.name)"] } ?? ["  table \(table.name)"]
                let changed: [String] = table.columns.compactMap { column -> String? in
                    switch columns[column.id] {
                    case .added, .modified: "+   \(describe(column))"
                    case .removed: "-   \(describe(column))"
                    default: nil
                    }
                }
                blocks.append(head + changed + detailLines(table))
            default: break
            }
        }
        let keys = model.relationships.compactMap { relationship -> [String]? in
            guard let change = relationships[relationship.id], let from = model.qualifiedName(of: relationship.from),
                  let to = model.qualifiedName(of: relationship.to) else { return nil }
            let line = { (implicit: Bool) in "foreign key \(from) → \(to)" + (implicit ? " (implicit, no constraint)" : "") }
            return switch change {
            case .added: ["+ " + line(relationship.isImplicit)]
            case .removed: ["- " + line(relationship.isImplicit)]
            case .modified: ["- " + line(!relationship.isImplicit), "+ " + line(relationship.isImplicit)]
            }
        }
        if !keys.isEmpty { blocks.append(keys.flatMap { $0 }) }
        lines += ["\(summary).", "", "```diff", blocks.map { $0.joined(separator: "\n") }.joined(separator: "\n\n"), "```", ""]
        return lines.joined(separator: "\n")
    }
}
