import Foundation

/// Copying part of a data model and pasting it into the same one or another, by way of the pasteboard.
extension DataModel {
    /// A data model of `tables` (and the tables of `groups`), with their foreign keys, whichever tables those reference,
    /// the zip ties all of whose wires come too, and their groups, with only the tables copied.
    func clip(tables ids: Set<Table.ID>, groups groupIDs: Set<TableGroup.ID> = []) -> DataModel {
        let ids = ids.union(tables.filter { $0.group.map(groupIDs.contains) == true }.map(\.id))
        let copied = tables.filter { ids.contains($0.id) }
        let columns = Set(copied.flatMap(\.columns).map(\.id))
        let wires = relationships.filter { columns.contains($0.from) }
        let wireIDs = Set(wires.map(\.id))
        let ties = zipTies.filter { $0.relationships.allSatisfy(wireIDs.contains) }
        let used = Set(copied.compactMap(\.group))
        return DataModel(tables: copied, relationships: wires, zipTies: ties, groups: groups.filter { used.contains($0.id) })
    }

    /// The tables joined to `ids` by foreign keys, either way, and how many keys away each is: 1 for those joined to
    /// them directly, 2 for those joined to those, and so on. Not `ids` themselves.
    func joinedTables(to ids: Set<Table.ID>) -> [Table.ID: Int] {
        let owner = columnLocations
        var neighbors: [Table.ID: Set<Table.ID>] = [:]
        for relationship in relationships {
            guard let from = owner[relationship.from]?.table.id, let to = owner[relationship.to]?.table.id, from != to else { continue }
            neighbors[from, default: []].insert(to)
            neighbors[to, default: []].insert(from)
        }
        var distances: [Table.ID: Int] = [:], seen = ids, frontier = ids, distance = 0
        while !frontier.isEmpty {
            distance += 1
            frontier = Set(frontier.flatMap { neighbors[$0] ?? [] }).subtracting(seen)
            for id in frontier { distances[id] = distance }
            seen.formUnion(frontier)
        }
        return distances
    }

    /// Adds a copy of `clip`, moved by `offset`, with everything in it new: tables renamed if theirs are taken, groups
    /// joined if one here has the same name, and foreign keys to tables left behind kept only where those tables are here.
    /// - Returns: What was added, to select.
    mutating func paste(_ clip: DataModel, offset: CGPoint) -> (tables: [Table.ID], ties: [ZipTie.ID], groups: [TableGroup.ID]) {
        var groupIDs: [TableGroup.ID: TableGroup.ID] = [:]
        for group in clip.groups {
            if let same = groups.first(where: { $0.name.lowercased() == group.name.lowercased() }) {
                groupIDs[group.id] = same.id
            } else {
                var copy = group
                copy.id = UUID()
                groups.append(copy)
                groupIDs[group.id] = copy.id
            }
        }
        var columnIDs: [Column.ID: Column.ID] = [:], tableIDs: [Table.ID] = []
        for var table in clip.tables {
            table.id = UUID()
            table.position += offset
            table.group = table.group.flatMap { groupIDs[$0] }
            var name = table.name, number = 2
            while tables.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                name = "\(table.name)_\(number)"
                number += 1
            }
            table.name = name
            for index in table.columns.indices {
                let id = UUID()
                columnIDs[table.columns[index].id] = id
                table.columns[index].id = id
            }
            // Its sample data, under its columns' new IDs.
            table.samples = table.samples.map { row in
                Dictionary(uniqueKeysWithValues: row.compactMap { key, value in
                    UUID(uuidString: key).flatMap { columnIDs[$0] }.map { ($0.uuidString, value) }
                })
            }
            tables.append(table)
            tableIDs.append(table.id)
        }
        let here = Set(tables.flatMap(\.columns).map(\.id))
        // Copied groups' ports, for the copied columns, or the same ones if they're here.
        for group in clip.groups {
            guard let index = groups.firstIndex(where: { $0.id == groupIDs[group.id] && $0.id != group.id }), groups[index].ports == group.ports else { continue }
            // Where they were put, plugged into the copied column, or the same one if it's here; their buses' ties stay behind.
            groups[index].ports = group.ports.map { port in
                let column = port.column.flatMap { columnIDs[$0] ?? (here.contains($0) ? $0 : nil) }
                return GroupPort(column: column, side: port.side, along: port.along)
            }
        }
        var wireIDs: [Relationship.ID: Relationship.ID] = [:]
        for wire in clip.relationships {
            guard let from = columnIDs[wire.from] else { continue }
            let to = columnIDs[wire.to] ?? (here.contains(wire.to) ? wire.to : nil)
            guard let to, let id = connect(from, to: to) else { continue }
            wireIDs[wire.id] = id
        }
        // The ties whose wires all came, then each wire through its ties in the same order as before.
        var tieIDs: [ZipTie.ID: ZipTie.ID] = [:]
        for var tie in clip.zipTies {
            let wires = tie.relationships.compactMap { wireIDs[$0] }
            guard wires.count == tie.relationships.count else { continue }
            let old = tie.id
            tie.id = UUID()
            tie.position += offset
            tie.relationships = wires
            zipTies.append(tie)
            tieIDs[old] = tie.id
        }
        for wire in clip.relationships {
            guard let id = wireIDs[wire.id], let index = relationships.firstIndex(where: { $0.id == id }) else { continue }
            relationships[index].zipTies = wire.zipTies.compactMap { tieIDs[$0] }
        }
        repair()
        return (tableIDs, Array(tieIDs.values), Array(Set(groupIDs.values)))
    }
}
