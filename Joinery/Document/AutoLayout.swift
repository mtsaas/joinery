import CoreGraphics
import Foundation

extension DataModel {
    /// Ways to lay every table out afresh, for a starting point, say after importing a big schema.
    enum Layout: String, CaseIterable, Identifiable {
        /// As DataGrip's: each group, or each set of tables joined by foreign keys, as a compact block of related tables;
        /// the blocks packed in rows.
        case orthogonalGroups
        /// Referenced tables to the left of those that reference them, in columns.
        case hierarchical

        var id: Self { self }

        var title: String {
            switch self {
            case .orthogonalGroups: "Orthogonal Groups"
            case .hierarchical: "Hierarchical"
            }
        }

        var symbol: String {
            switch self {
            case .orthogonalGroups: "square.grid.3x3.topleft.filled"
            case .hierarchical: "arrow.right.to.line.compact"
            }
        }
    }

    /// Room between tables across, for wires to pass, and down.
    private static let layoutGap = CGSize(width: 96, height: 48)
    /// Room between blocks of tables, groups' labels and padding included.
    private static let blockGap: CGFloat = 120

    /// Moves every table to where `layout` puts it, starting from where the tables are now, and each zip tie to the
    /// middle of its wires' ends. One change, to undo whole.
    mutating func arrange(_ layout: Layout) {
        guard !tables.isEmpty else { return }
        let origin = bounds.map { CGPoint(x: $0.minX, y: $0.minY) } ?? .zero
        let neighbors = adjacency()
        // Either way, each group's tables (or each set of joined ones) together as a block, so groups stay apart.
        let positions = switch layout {
        case .orthogonalGroups: packedBlocks { Self.block($0, neighbors: neighbors) }
        case .hierarchical: packedBlocks(hierarchical)
        }
        for index in tables.indices {
            if let position = positions[tables[index].id] { tables[index].position = origin + position }
        }
        placeTies()
    }

    // MARK: Blocks

    /// The tables in blocks: each group's; then the rest, by what joins them; then those joined to nothing, together.
    /// Each block is laid out by `arrange`, then the blocks are packed in rows, tallest first, about twice as wide as
    /// tall, with room for groups' boundaries and names.
    private func packedBlocks(_ arrange: ([Table]) -> (positions: [Table.ID: CGPoint], size: CGSize)) -> [Table.ID: CGPoint] {
        let neighbors = adjacency()
        // Blocks: each group's tables; then the rest, by what joins them; then those joined to nothing, together.
        var blocks: [(tables: [Table], isGroup: Bool)] = groups.map { (members(of: $0.id), true) }.filter { !$0.tables.isEmpty }
        let loose = tables.filter { $0.group == nil }
        let looseByID = Dictionary(uniqueKeysWithValues: loose.map { ($0.id, $0) })
        var seen = Set<Table.ID>(), alone: [Table] = []
        for table in loose where !seen.contains(table.id) {
            var component: [Table] = [], queue = [table.id]
            seen.insert(table.id)
            while let id = queue.popLast() {
                guard let next = looseByID[id] else { continue }
                component.append(next)
                for neighbor in neighbors[id, default: []] where !seen.contains(neighbor) && looseByID[neighbor] != nil {
                    seen.insert(neighbor)
                    queue.append(neighbor)
                }
            }
            if component.count == 1 { alone += component } else { blocks.append((component, false)) }
        }
        if !alone.isEmpty { blocks.append((alone, false)) }

        let laidOut = blocks.map { block in (layout: arrange(block.tables), isGroup: block.isGroup) }
        let margins = laidOut.map { block -> (left: CGFloat, top: CGFloat, size: CGSize) in
            let padding = block.isGroup ? Metrics.groupPadding : 0, label = block.isGroup ? Metrics.groupLabelHeight : 0
            return (padding, padding + label, CGSize(width: block.layout.size.width + padding * 2,
                                                    height: block.layout.size.height + padding * 2 + label))
        }
        let area = margins.reduce(0) { $0 + ($1.size.width + Self.blockGap) * ($1.size.height + Self.blockGap) }
        let rowWidth = max((area * 2).squareRoot(), margins.map(\.size.width).max() ?? 0)
        var positions: [Table.ID: CGPoint] = [:]
        var cursor = CGPoint.zero, rowHeight: CGFloat = 0
        for index in margins.indices.sorted(by: { margins[$0].size.height > margins[$1].size.height }) {
            let block = margins[index]
            if cursor.x > 0 && cursor.x + block.size.width > rowWidth {
                cursor = CGPoint(x: 0, y: cursor.y + rowHeight + Self.blockGap)
                rowHeight = 0
            }
            for (id, position) in laidOut[index].layout.positions {
                positions[id] = cursor + CGPoint(x: block.left, y: block.top) + position
            }
            cursor.x += block.size.width + Self.blockGap
            rowHeight = max(rowHeight, block.size.height)
        }
        return positions
    }

    // MARK: Orthogonal groups

    /// A block of tables in columns, about as wide as tall: from the most joined, outward along foreign keys, each into
    /// the shortest column, so tables sit near those they're joined to.
    private static func block(_ tables: [Table], neighbors: [Table.ID: Set<Table.ID>]) -> (positions: [Table.ID: CGPoint], size: CGSize) {
        let byID = Dictionary(uniqueKeysWithValues: tables.map { ($0.id, $0) })
        let degree = { (id: Table.ID) in neighbors[id, default: []].count }
        var order: [Table] = [], seen = Set<Table.ID>()
        for start in tables.sorted(by: { degree($0.id) > degree($1.id) }) where !seen.contains(start.id) {
            var queue = [start.id]
            seen.insert(start.id)
            while !queue.isEmpty {
                let id = queue.removeFirst()
                order.append(byID[id]!)
                for next in neighbors[id, default: []].filter({ byID[$0] != nil && !seen.contains($0) }).sorted(by: { degree($0) > degree($1) }) {
                    seen.insert(next)
                    queue.append(next)
                }
            }
        }
        let height = tables.map { Metrics.size(of: $0).height }.reduce(0, +) / CGFloat(tables.count)
        let columns = max(1, Int((CGFloat(tables.count) * (height + layoutGap.height) / (Metrics.tableWidth + layoutGap.width)).squareRoot().rounded()))
        var bottoms = [CGFloat](repeating: 0, count: columns), positions: [Table.ID: CGPoint] = [:]
        for table in order {
            let column = bottoms.indices.min { bottoms[$0] < bottoms[$1] }!
            positions[table.id] = CGPoint(x: CGFloat(column) * (Metrics.tableWidth + layoutGap.width), y: bottoms[column])
            bottoms[column] += Metrics.size(of: table).height + layoutGap.height
        }
        let used = bottoms.filter { $0 > 0 }.count
        return (positions, CGSize(width: CGFloat(used) * (Metrics.tableWidth + layoutGap.width) - layoutGap.width,
                                  height: (bottoms.max() ?? 0) - layoutGap.height))
    }

    // MARK: Hierarchical

    /// A block of tables in columns by what they reference: each one column right of the furthest table its foreign
    /// keys reference (a cycle broken where it's found), and down each column in the order of those tables' places, so
    /// wires cross as little as they can.
    private func hierarchical(_ block: [Table]) -> (positions: [Table.ID: CGPoint], size: CGSize) {
        let inBlock = Set(block.map(\.id))
        let owner = columnLocations.mapValues(\.table.id)
        var parents: [Table.ID: Set<Table.ID>] = [:]
        for relationship in relationships {
            guard let child = owner[relationship.from], let parent = owner[relationship.to], child != parent,
                  inBlock.contains(child), inBlock.contains(parent) else { continue }
            parents[child, default: []].insert(parent)
        }
        var columns: [Table.ID: Int] = [:], visiting = Set<Table.ID>()
        func column(of id: Table.ID) -> Int {
            if let known = columns[id] { return known }
            guard visiting.insert(id).inserted else { return 0 }
            let value = parents[id, default: []].map { column(of: $0) + 1 }.max() ?? 0
            visiting.remove(id)
            columns[id] = value
            return value
        }
        for table in block { _ = column(of: table.id) }

        var rows: [Table.ID: CGFloat] = [:], positions: [Table.ID: CGPoint] = [:], height: CGFloat = 0
        let last = columns.values.max() ?? 0
        for index in 0...last {
            let members = block.filter { columns[$0.id] == index }.sorted { a, b in
                let place = { (table: Table) -> CGFloat in
                    let known = parents[table.id, default: []].compactMap { rows[$0] }
                    return known.isEmpty ? .infinity : known.reduce(0, +) / CGFloat(known.count)
                }
                return (place(a), a.name) < (place(b), b.name)
            }
            var y: CGFloat = 0
            for table in members {
                positions[table.id] = CGPoint(x: CGFloat(index) * (Metrics.tableWidth + Self.layoutGap.width), y: y)
                rows[table.id] = y + Metrics.size(of: table).height / 2
                y += Metrics.size(of: table).height + Self.layoutGap.height
            }
            height = max(height, y - Self.layoutGap.height)
        }
        return (positions, CGSize(width: CGFloat(last + 1) * (Metrics.tableWidth + Self.layoutGap.width) - Self.layoutGap.width,
                                  height: height))
    }

    // MARK: Helpers

    /// Which tables each table is joined to, either way.
    private func adjacency() -> [Table.ID: Set<Table.ID>] {
        let owner = columnLocations.mapValues(\.table.id)
        var neighbors: [Table.ID: Set<Table.ID>] = [:]
        for relationship in relationships {
            guard let a = owner[relationship.from], let b = owner[relationship.to], a != b else { continue }
            neighbors[a, default: []].insert(b)
            neighbors[b, default: []].insert(a)
        }
        return neighbors
    }

    /// Each zip tie (and bend point) to the middle of its wires' tables, where it's likely to be in their way.
    private mutating func placeTies() {
        let owner = columnLocations.mapValues(\.table)
        for index in zipTies.indices {
            let middles = zipTies[index].relationships.compactMap { id -> CGPoint? in
                guard let wire = relationships.first(where: { $0.id == id }),
                      let from = owner[wire.from].map(Metrics.frame), let to = owner[wire.to].map(Metrics.frame) else { return nil }
                return CGPoint(x: (from.midX + to.midX) / 2, y: (from.midY + to.midY) / 2)
            }
            if !middles.isEmpty { zipTies[index].position = middles.reduce(.zero, +) / CGFloat(middles.count) }
        }
    }
}
