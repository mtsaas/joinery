import CoreGraphics
import Foundation

extension Schema {
    func table(_ id: Table.ID) -> Table? {
        tables.first { $0.id == id }
    }

    /// The table that owns each column, and the column's row in it.
    var columnLocations: [Column.ID: (table: Table, row: Int)] {
        var locations: [Column.ID: (table: Table, row: Int)] = [:]
        for table in tables {
            for (row, column) in table.columns.enumerated() { locations[column.id] = (table, row) }
        }
        return locations
    }

    /// "orders.user_id", or nil for a column that isn't in the schema.
    func qualifiedName(of column: Column.ID) -> String? {
        columnLocations[column].map { "\($0.table.name).\($0.table.columns[$0.row].name)" }
    }

    /// The smallest rectangle around every table, or nil when there are none.
    var bounds: CGRect? {
        tables.map(Metrics.frame).reduce(nil) { $0?.union($1) ?? $1 }
    }

    /// The column under `point`. Anywhere on a table counts, so a wire can be dropped on a row rather than its
    /// socket; the header stands for the primary key.
    func column(at point: CGPoint) -> Column.ID? {
        for table in tables.reversed() {
            let frame = Metrics.frame(of: table).insetBy(dx: -Metrics.socketHitRadius, dy: 0)
            guard frame.contains(point) else { continue }
            let row = Int(((point.y - frame.minY - Metrics.headerHeight) / Metrics.rowHeight).rounded(.down))
            if table.columns.indices.contains(row) { return table.columns[row].id }
            return (table.columns.first(where: \.isPrimaryKey) ?? table.columns.first)?.id
        }
        return nil
    }

    @discardableResult
    mutating func addTable(at position: CGPoint) -> Table.ID {
        var number = tables.count + 1
        while tables.contains(where: { $0.name == "table_\(number)" }) { number += 1 }
        // The color used least so far, so neighbors tend to differ.
        let color = TableColor.allCases.min { a, b in tables.count { $0.color == a } < tables.count { $0.color == b } } ?? .blue
        let table = Table(name: "table_\(number)", position: position, color: color,
                          columns: [Column(name: "id", type: .uuid, isPrimaryKey: true)])
        tables.append(table)
        return table.id
    }

    mutating func removeTable(_ id: Table.ID) {
        guard let table = table(id) else { return }
        let columns = Set(table.columns.map(\.id))
        tables.removeAll { $0.id == id }
        removeRelationships { columns.contains($0.from) || columns.contains($0.to) }
    }

    mutating func removeColumn(_ id: Column.ID) {
        for index in tables.indices { tables[index].columns.removeAll { $0.id == id } }
        removeRelationships { $0.from == id || $0.to == id }
    }

    /// Adds a foreign key from `from` to `to`, unless it would be to itself or already exists.
    @discardableResult
    mutating func connect(_ from: Column.ID, to: Column.ID) -> Relationship.ID? {
        guard from != to, !relationships.contains(where: { $0.from == from && $0.to == to }) else { return nil }
        let relationship = Relationship(from: from, to: to)
        relationships.append(relationship)
        return relationship.id
    }

    mutating func removeRelationships(where shouldRemove: (Relationship) -> Bool) {
        let removed = Set(relationships.filter(shouldRemove).map(\.id))
        guard !removed.isEmpty else { return }
        relationships.removeAll { removed.contains($0.id) }
        for index in zipTies.indices { zipTies[index].relationships.removeAll(where: removed.contains) }
        // A tie holding one wire is just a kink in it.
        for tie in zipTies where tie.relationships.count < 2 { removeZipTie(tie.id) }
    }

    mutating func removeZipTie(_ id: ZipTie.ID) {
        zipTies.removeAll { $0.id == id }
        for index in relationships.indices { relationships[index].zipTies.removeAll { $0 == id } }
    }

    /// Drops references to anything that isn't there, so a hand-edited or damaged file can't make the canvas draw
    /// wires to nowhere. A wire and a tie stay joined only if each lists the other.
    mutating func repair() {
        let columns = Set(tables.flatMap(\.columns).map(\.id))
        relationships.removeAll { !columns.contains($0.from) || !columns.contains($0.to) }
        let tiesOf = Dictionary(relationships.map { ($0.id, Set($0.zipTies)) }, uniquingKeysWith: { first, _ in first })
        let wiresOf = Dictionary(zipTies.map { ($0.id, Set($0.relationships)) }, uniquingKeysWith: { first, _ in first })
        for index in zipTies.indices {
            let tie = zipTies[index].id
            zipTies[index].relationships = zipTies[index].relationships.uniqued.filter { tiesOf[$0]?.contains(tie) == true }
            zipTies[index].direction = zipTies[index].direction.normalized ?? CGPoint(x: 1, y: 0)
        }
        for index in relationships.indices {
            let wire = relationships[index].id
            relationships[index].zipTies = relationships[index].zipTies.uniqued.filter { wiresOf[$0]?.contains(wire) == true }
        }
        for tie in zipTies where tie.relationships.count < 2 { removeZipTie(tie.id) }
    }
}

private extension Array where Element: Hashable {
    var uniqued: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
