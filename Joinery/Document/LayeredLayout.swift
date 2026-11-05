import CoreGraphics
import Foundation

extension DataModel {
    /// A block of tables read left to right: each table right of the tables its foreign keys reference, as near them as
    /// it can be, and level with them, so most wires run straight across. In the steps of a layered (Sugiyama) layout:
    /// break cycles, put each table in a column, order each column so wires cross little, then place tables down each
    /// column and space the columns by how far their wires have to bend.
    func layered(_ block: [Table]) -> (positions: [Table.ID: CGPoint], size: CGSize) {
        let count = block.count
        let index = Dictionary(uniqueKeysWithValues: block.enumerated().map { ($1.id, $0) })
        let owner = columnLocations
        // Each foreign key between two of the block's tables, as its table and row at each end.
        let keys = relationships.compactMap { wire -> (parent: Int, parentRow: Int, child: Int, childRow: Int)? in
            guard let from = owner[wire.from], let to = owner[wire.to], let child = index[from.table.id], let parent = index[to.table.id],
                  child != parent else { return nil }
            return (parent, to.row, child, from.row)
        }

        // Cycles broken where a walk from the tables first by name finds them: those keys point right to left.
        var children = [[Int]](repeating: [], count: count)
        for key in keys { children[key.parent].append(key.child) }
        var state = [UInt8](repeating: 0, count: count), backward = Set<[Int]>()
        func visit(_ table: Int) {
            state[table] = 1
            for child in children[table] {
                if state[child] == 1 { backward.insert([table, child]) } else if state[child] == 0 { visit(child) }
            }
            state[table] = 2
        }
        let byName = (0..<count).sorted { (block[$0].name, $0) < (block[$1].name, $1) }
        for table in byName where state[table] == 0 { visit(table) }
        // Each key as an arrow left to right, with where it meets the table at each end, down from the table's top.
        func port(_ row: Int) -> CGFloat { Metrics.headerHeight + (CGFloat(row) + 0.5) * Metrics.rowHeight }
        let arrows = keys.map { key in
            backward.contains([key.parent, key.child])
                ? (left: key.child, leftPort: port(key.childRow), right: key.parent, rightPort: port(key.parentRow))
                : (left: key.parent, leftPort: port(key.parentRow), right: key.child, rightPort: port(key.childRow))
        }

        // Columns: first each table one right of the furthest it references; then, while it shortens the wires, each
        // table moved toward whichever side has more of them, so a table referenced from far right comes over to it.
        var before = [[Int]](repeating: [], count: count), after = [[Int]](repeating: [], count: count)
        for arrow in arrows { before[arrow.right].append(arrow.left); after[arrow.left].append(arrow.right) }
        var column = [Int](repeating: -1, count: count)
        func longest(_ table: Int) -> Int {
            if column[table] < 0 { column[table] = before[table].map { longest($0) + 1 }.max() ?? 0 }
            return column[table]
        }
        for table in 0..<count { _ = longest(table) }
        for _ in 0..<count {
            var isMoved = false
            for table in byName {
                let low = before[table].map { column[$0] + 1 }.max(), high = after[table].map { column[$0] - 1 }.min()
                let wanted: Int? = switch (low, high) {
                case (nil, nil): nil
                case (let low?, nil): low
                case (nil, let high?): high
                case (let low?, let high?): before[table].count > after[table].count ? low : before[table].count < after[table].count ? high : nil
                }
                if let wanted, wanted != column[table] { column[table] = wanted; isMoved = true }
            }
            if !isMoved { break }
        }
        let first = column.min() ?? 0
        column = column.map { $0 - first }

        // Nodes: the tables, then a point for each column a wire passes through on its way to a table further over,
        // so long wires get a lane of their own. Segments join nodes in neighboring columns.
        var nodeColumn = column, height = block.map { Metrics.size(of: $0).height }
        var segments: [(left: Int, leftPort: CGFloat, right: Int, rightPort: CGFloat)] = []
        for arrow in arrows {
            var left = arrow.left, leftPort = arrow.leftPort
            for passing in stride(from: column[arrow.left] + 1, to: column[arrow.right], by: 1) {
                nodeColumn.append(passing)
                height.append(0)
                segments.append((left, leftPort, nodeColumn.count - 1, 0))
                left = nodeColumn.count - 1
                leftPort = 0
            }
            segments.append((left, leftPort, arrow.right, arrow.rightPort))
        }
        let nodes = nodeColumn.count
        let isTable = { (node: Int) in node < count }
        var leftOf = [[(node: Int, port: CGFloat, own: CGFloat)]](repeating: [], count: nodes), rightOf = leftOf
        for segment in segments {
            rightOf[segment.left].append((segment.right, segment.rightPort, segment.leftPort))
            leftOf[segment.right].append((segment.left, segment.leftPort, segment.rightPort))
        }

        // Order down each column: sweeps back and forth, each node to the average place of its neighbors on the side
        // just swept, keeping the order that crossed least.
        let columns = (nodeColumn.max() ?? 0) + 1
        var layers = [[Int]](repeating: [], count: columns)
        for node in byName + Array(count..<nodes) { layers[nodeColumn[node]].append(node) }
        var place = [Double](repeating: 0, count: nodes)
        func number() { for layer in layers { for (at, node) in layer.enumerated() { place[node] = Double(at) } } }
        // Where a wire meets a node, as its place plus how far down the node, so wires from one table keep their order.
        func spot(_ node: Int, _ port: CGFloat) -> Double { place[node] + Double(port / max(height[node], 1)) * 0.9 }
        let segmentsAfter = Dictionary(grouping: segments, by: { nodeColumn[$0.left] })
        // Wires crossing between a column and the next.
        func crossings(after gap: Int) -> Int {
            let between = (segmentsAfter[gap] ?? []).map { (spot($0.left, $0.leftPort), spot($0.right, $0.rightPort)) }
            var total = 0
            for a in between.indices { for b in between.indices where b > a && (between[a].0 - between[b].0) * (between[a].1 - between[b].1) < 0 { total += 1 } }
            return total
        }
        func crossings() -> Int { (0..<columns).reduce(0) { $0 + crossings(after: $1) } }
        number()
        var best = layers, fewest = crossings()
        for sweep in 0..<24 where fewest > 0 {
            let forward = sweep.isMultiple(of: 2)
            for layer in forward ? Array(1..<max(columns, 1)) : Array((0..<max(columns - 1, 0)).reversed()) {
                let wanted = Dictionary(uniqueKeysWithValues: layers[layer].map { node in
                    let near = forward ? leftOf[node] : rightOf[node]
                    return (node, near.isEmpty ? place[node] : near.map { spot($0.node, $0.port) }.reduce(0, +) / Double(near.count))
                })
                layers[layer].sort { (wanted[$0]!, place[$0]) < (wanted[$1]!, place[$1]) }
                for (at, node) in layers[layer].enumerated() { place[node] = Double(at) }
            }
            let crossed = crossings()
            if crossed < fewest { best = layers; fewest = crossed }
        }
        layers = best
        number()
        // Then neighbors in a column swapped while that crosses fewer wires either side.
        var isSwapped = true
        for _ in 0..<8 where isSwapped {
            isSwapped = false
            for layer in 0..<columns {
                for at in layers[layer].indices.dropLast() {
                    let (a, b) = (layers[layer][at], layers[layer][at + 1])
                    let crossed = crossings(after: layer - 1) + crossings(after: layer)
                    (place[a], place[b]) = (place[b], place[a])
                    if crossings(after: layer - 1) + crossings(after: layer) < crossed {
                        layers[layer].swapAt(at, at + 1)
                        isSwapped = true
                    } else {
                        (place[a], place[b]) = (place[b], place[a])
                    }
                }
            }
        }

        // Down each column: sweeps back and forth, each node as near as it can get to level with its neighbors (the
        // median of where they'd have it), kept in order and apart. Wire lanes weigh more, so long wires run straight.
        func spacing(_ a: Int, _ b: Int) -> CGFloat { isTable(a) && isTable(b) ? 36 : isTable(a) || isTable(b) ? 24 : 14 }
        func placedDown(resorting: Bool = true) -> [CGFloat] {
            var y = [CGFloat](repeating: 0, count: nodes)
            for layer in layers {
                var top: CGFloat = 0
                for (at, node) in layer.enumerated() {
                    y[node] = top
                    top += height[node] + (at + 1 < layer.count ? spacing(node, layer[at + 1]) : 0)
                }
            }
            for sweep in 0..<12 {
                let forward = sweep.isMultiple(of: 2), both = sweep >= 8
                for layer in forward ? Array(0..<columns) : Array((0..<columns).reversed()) {
                    let wanted = layers[layer].map { node -> CGFloat in
                        let near = both ? leftOf[node] + rightOf[node] : forward ? leftOf[node] : rightOf[node]
                        let levels = near.map { y[$0.node] + $0.port - $0.own }.sorted()
                        guard !levels.isEmpty else { return y[node] }
                        return levels.count.isMultiple(of: 2) ? (levels[levels.count / 2 - 1] + levels[levels.count / 2]) / 2 : levels[levels.count / 2]
                    }
                    // Resorting, lanes go wherever their wires want them among the tables, which keep their order.
                    var floor = -CGFloat.infinity
                    let keys = zip(layers[layer], wanted).map { node, value -> CGFloat in
                        guard isTable(node) || !resorting else { return value }
                        floor = max(floor, value)
                        return floor
                    }
                    let sorted = layers[layer].indices.sorted { (keys[$0], $0) < (keys[$1], $1) }
                    layers[layer] = sorted.map { layers[layer][$0] }
                    let placed = Self.inOrder(sorted.map { wanted[$0] }, heights: layers[layer].map { height[$0] },
                                              spacing: zip(layers[layer], layers[layer].dropFirst()).map(spacing),
                                              weights: layers[layer].map { isTable($0) ? 1 : 3 })
                    for (node, value) in zip(layers[layer], placed) { y[node] = value }
                }
            }
            return y
        }
        // How good a placement is: wires crossing, each worth a lot of up-and-down travel. As they're drawn, straight
        // from socket to socket, not along their lanes; columns about as far apart as they'll be.
        func score(_ y: [CGFloat]) -> CGFloat {
            let step = Metrics.tableWidth + 160
            let wires = arrows.map { (CGPoint(x: CGFloat(column[$0.left]) * step + Metrics.width(of: block[$0.left]), y: y[$0.left] + $0.leftPort),
                                      CGPoint(x: CGFloat(column[$0.right]) * step, y: y[$0.right] + $0.rightPort)) }
            return CGFloat(Untangler.crossings(wires)) * 400 + wires.reduce(0) { $0 + abs($1.0.y - $1.1.y) }
        }
        // Then, placed for real, tables a few apart in a column swapped while that crosses fewer wires (the slots
        // above only guess where wires land: a tall table or a wire lane between moves them).
        // Lanes kept where the ordering put them, or moved as their wires pull: whichever comes out better.
        let ordered = layers
        var y = placedDown(), lowest = score(y), isBetter = true
        let resorted = layers
        layers = ordered
        let unsorted = placedDown(resorting: false)
        if score(unsorted) < lowest { (y, lowest) = (unsorted, score(unsorted)) } else { layers = resorted }
        for _ in 0..<4 where isBetter {
            isBetter = false
            for layer in 0..<columns {
                let tables = layers[layer].filter(isTable)
                for (n, a) in tables.enumerated() {
                    for b in tables.dropFirst(n + 1).prefix(4) {
                        let kept = layers
                        layers[layer].swapAt(layers[layer].firstIndex(of: a)!, layers[layer].firstIndex(of: b)!)
                        let tried = placedDown(), value = score(tried)
                        if value < lowest - 1 { (y, lowest, isBetter) = (tried, value, true) } else { layers = kept }
                    }
                }
            }
        }
        let topmost = y.min() ?? 0

        // Across: each column as wide as its widest table, and the gap after it wide enough for its wires to bend
        // smoothly, wider the further they have to go up or down and the more there are.
        var x: [CGFloat] = [], right: CGFloat = 0
        for layer in 0..<columns {
            x.append(right)
            let width = layers[layer].filter(isTable).map { Metrics.width(of: block[$0]) }.max() ?? 0
            let crossing = segments.filter { nodeColumn[$0.left] == layer }
            let rise = crossing.map { abs(y[$0.left] + $0.leftPort - y[$0.right] - $0.rightPort) }.max() ?? 0
            right += width + min(80 + rise * 0.2 + CGFloat(crossing.count) * 4, 360)
        }

        var positions: [Table.ID: CGPoint] = [:], size = CGSize.zero
        for table in 0..<count {
            let point = CGPoint(x: x[column[table]], y: y[table] - topmost)
            positions[block[table].id] = point
            size = CGSize(width: max(size.width, point.x + Metrics.width(of: block[table])), height: max(size.height, point.y + height[table]))
        }
        return (positions, size)
    }

    /// Tops for things stacked in order, each at least its height and `spacing` below the last, as near as they can be
    /// to `wanted`, by weighted least squares: pool-adjacent-violators on the tops less the room above each.
    static func inOrder(_ wanted: [CGFloat], heights: [CGFloat], spacing: [CGFloat], weights: [Double]) -> [CGFloat] {
        var room: [CGFloat] = [0]
        for at in spacing.indices { room.append(room[at] + heights[at] + spacing[at]) }
        var pools: [(total: Double, weight: Double, count: Int)] = []
        for at in wanted.indices {
            pools.append((Double(wanted[at] - room[at]) * weights[at], weights[at], 1))
            while pools.count > 1, pools[pools.count - 2].total / pools[pools.count - 2].weight > pools[pools.count - 1].total / pools[pools.count - 1].weight {
                let last = pools.removeLast()
                pools[pools.count - 1].total += last.total
                pools[pools.count - 1].weight += last.weight
                pools[pools.count - 1].count += last.count
            }
        }
        return pools.flatMap { pool in [CGFloat](repeating: CGFloat(pool.total / pool.weight), count: pool.count) }
            .enumerated().map { $1 + room[$0] }
    }
}
