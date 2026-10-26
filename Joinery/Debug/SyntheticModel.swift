#if DEBUG
import CoreGraphics

extension DataModel {
    /// A made-up model of a given size, the same every time for a seed, for measuring how things scale: tables `t0`,
    /// `t1`… in a grid, each with an `id` key and a few columns, and foreign keys mostly between near neighbors (as in
    /// real models) with some reaching across.
    static func synthetic(tables count: Int, foreignKeys: Int, seed: UInt64 = 1) -> DataModel {
        var random = SplitMix(seed: seed)
        var model = DataModel()
        let perRow = max(1, Int(Double(count).squareRoot().rounded(.up)))
        for index in 0..<count {
            let position = CGPoint(x: CGFloat(index % perRow) * (Metrics.tableWidth + 120), y: CGFloat(index / perRow) * 260)
            model.addTable(at: position)
            let row = model.tables.count - 1
            model.tables[row].name = "t\(index)"
            for column in 0..<random.next(below: 5) {
                model.tables[row].columns.append(Column(name: "c\(column)", type: DataType.allCases[random.next(below: DataType.allCases.count)]))
            }
        }
        guard count > 1 else { return model }
        for key in 0..<foreignKeys {
            let child = random.next(below: count)
            // Three in four to a table within two places in the grid.
            var parent = random.next(below: 4) == 0 ? random.next(below: count)
                : min(max(child + [-perRow - 1, -perRow, -1, 1, perRow, perRow + 1, -2, 2][random.next(below: 8)], 0), count - 1)
            if parent == child { parent = (child + 1) % count }
            let column = Column(name: "fk\(key)", type: .uuid)
            model.tables[child].columns.append(column)
            model.connect(column.id, to: model.tables[parent].columns[0].id)
        }
        return model
    }
}

/// A small seedable generator (SplitMix64), as the system's can't be seeded.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next(below bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}
#endif
