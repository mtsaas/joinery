import Foundation

/// Part of a data model written out as Markdown, to paste into a chat with an AI assistant: each table's columns, the
/// SQL to make them, and their notes.
extension DataModel {
    /// `ids`, or every table if nil, as Markdown under `title`: a Tables section (each table's columns, keys and what
    /// references it), a Schema section (PostgreSQL to create them) and a Notes section, if any have notes.
    func markdown(of ids: Set<Table.ID>?, title: String) -> String {
        let chosen = tables.filter { ids?.contains($0.id) ?? true }
        let owner = columnLocations
        let groupName = { (table: Table) in table.group.flatMap { id in self.groups.first { $0.id == id }?.name } }
        func reference(_ column: Column.ID) -> String? {
            owner[column].map { "\($0.table.name).\($0.table.columns[$0.row].name)" }
        }
        let referencing = Dictionary(grouping: relationships, by: \.from)

        var lines = ["# \(title)", ""]
        if ids != nil, chosen.count < tables.count {
            lines += ["\(chosen.count) of the \(tables.count) tables in this data model.", ""]
        }

        lines += ["## Tables", ""]
        for table in chosen {
            lines.append("### \(table.name)")
            if let schema = groupName(table) { lines.append("Schema: `\(schema)`") }
            lines += ["", "| Column | Type | Key | Required | References |", "|---|---|---|---|---|"]
            for column in table.columns {
                let targets = referencing[column.id]?.compactMap { reference($0.to) } ?? []
                let keys = [column.isPrimaryKey ? "PK" : nil, targets.isEmpty ? nil : "FK", column.isUnique ? "unique" : nil].compactMap { $0 }
                lines.append("| \(column.name) | \(column.type.rawValue) | \(keys.joined(separator: ", ")) | "
                             + "\(column.isNullable ? "no" : "yes") | \(targets.joined(separator: ", ")) |")
            }
            let columns = Set(table.columns.map(\.id))
            let referencedBy = relationships.filter { columns.contains($0.to) }.compactMap { reference($0.from) }
            if !referencedBy.isEmpty { lines += ["", "Referenced by: " + referencedBy.joined(separator: ", ")] }
            lines.append("")
        }

        lines += ["## Schema", "", "```sql"]
        let schemas = Set(chosen.compactMap(groupName)).sorted()
        for schema in schemas { lines.append("CREATE SCHEMA IF NOT EXISTS \(Self.sqlName(schema));") }
        if !schemas.isEmpty { lines.append("") }
        let qualified = { (table: Table) in [groupName(table), table.name].compactMap { $0 }.map(Self.sqlName).joined(separator: ".") }
        for (number, table) in chosen.enumerated() {
            let keys = table.columns.filter(\.isPrimaryKey)
            var parts = table.columns.map { column in
                var part = "  \(Self.sqlName(column.name)) \(column.type.rawValue)"
                if column.isPrimaryKey, keys.count == 1 { part += " PRIMARY KEY" } else if !column.isNullable { part += " NOT NULL" }
                if column.isUnique, !column.isPrimaryKey { part += " UNIQUE" }
                for relationship in referencing[column.id] ?? [] {
                    guard let (target, row) = owner[relationship.to] else { continue }
                    part += " REFERENCES \(qualified(target)) (\(Self.sqlName(target.columns[row].name)))"
                }
                return part
            }
            if keys.count > 1 { parts.append("  PRIMARY KEY (\(keys.map { Self.sqlName($0.name) }.joined(separator: ", ")))") }
            let columnList = { (index: TableIndex) in table.columns(of: index).map { Self.sqlName($0.name) }.joined(separator: ", ") }
            for index in table.liveIndexes where index.isUnique {
                parts.append("  CONSTRAINT \(Self.sqlName(table.name(of: index))) UNIQUE (\(columnList(index)))")
            }
            lines.append("CREATE TABLE \(qualified(table)) (")
            lines.append(parts.joined(separator: ",\n"))
            lines.append(");")
            for index in table.liveIndexes where !index.isUnique {
                lines.append("CREATE INDEX \(Self.sqlName(table.name(of: index))) ON \(qualified(table)) (\(columnList(index)));")
            }
            if number < chosen.count - 1 { lines.append("") }
        }
        lines += ["```", ""]

        let noted = chosen.filter { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !noted.isEmpty {
            lines += ["## Notes", ""]
            for table in noted {
                lines += ["### \(table.name)", "", table.notes.trimmingCharacters(in: .whitespacesAndNewlines), ""]
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A name as SQL takes it: as it is if it's a plain lowercase identifier, otherwise in double quotes.
    static func sqlName(_ name: String) -> String {
        let plain = name.range(of: #"^[a-z_][a-z0-9_]*$"#, options: .regularExpression) != nil
        return plain ? name : "\"" + name.replacing("\"", with: "\"\"") + "\""
    }
}
