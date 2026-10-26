import AppKit
import Foundation

/// Copying part of a data model and pasting it into the same one or another, by way of the pasteboard.
extension DataModel {
    /// The pasteboard's name for a copied part of a data model: a `DataModel` as JSON.
    static let pasteboardType = NSPasteboard.PasteboardType("com.clarkmccauley.joinery.clip")

    /// A data model of `tables` (and the tables of `groups`), with their foreign keys, whichever tables those reference,
    /// the zip ties all of whose wires come too, and their groups.
    func clip(tables ids: Set<Table.ID>, groups groupIDs: Set<TableGroup.ID> = []) -> DataModel {
        let copied = tables.filter { ids.contains($0.id) || $0.group.map(groupIDs.contains) == true }
        let columns = Set(copied.flatMap(\.columns).map(\.id))
        let wires = relationships.filter { columns.contains($0.from) }
        let wireIDs = Set(wires.map(\.id))
        let ties = zipTies.filter { $0.relationships.allSatisfy(wireIDs.contains) }
        let used = Set(copied.compactMap(\.group))
        return DataModel(tables: copied, relationships: wires, zipTies: ties, groups: groups.filter { used.contains($0.id) })
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
            tables.append(table)
            tableIDs.append(table.id)
        }
        let here = Set(tables.flatMap(\.columns).map(\.id))
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
