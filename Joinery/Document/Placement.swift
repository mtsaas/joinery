import CoreGraphics
import Foundation

/// Putting tables somewhere open: for tables an AI assistant makes or moves, so they never land on others or inside a
/// group they're not in.
extension DataModel {
    /// Lays `ids` out together as a compact block, in rows, and puts the block in the open space nearest `anchor`
    /// (all the other tables, if nil), preferring right of it and below. Clear of every other table and of groups
    /// the block isn't in, by enough that a group of its own wouldn't touch them either. `ignoring` tables, not yet
    /// placed, aren't in the way.
    /// `keepingArrangement`, they're moved together as they are, not laid out afresh in rows.
    mutating func place(_ ids: [Table.ID], near anchor: CGRect?, ignoring: Set<Table.ID> = [], keepingArrangement: Bool = false) {
        let block = Set(ids)
        let others = tables.filter { !block.contains($0.id) && !ignoring.contains($0.id) }
        let fallback = others.map(Metrics.frame).reduce(nil) { $0?.union($1) ?? $1 }
        let layout = keepingArrangement ? currentLayout(ids) : blockLayout(ids)
        guard let anchor = anchor ?? fallback else { return arrangeBlock(layout, at: .zero) }

        // The block's group, if it's all in one, keeps its tables' company; the rest is in the way.
        let groupIDs = Set(ids.compactMap { table($0)?.group })
        let own = groupIDs.count == 1 && ids.allSatisfy({ table($0)?.group != nil }) ? groupIDs.first : nil
        let clearance: CGFloat = 64 + (own == nil ? 0 : Metrics.groupPadding + Metrics.groupLabelHeight)
        // Its own group's other tables, kept a little apart from; and the box around them, which the group's boundary
        // will span with the block, so has to be clear of everything else too.
        let company = others.filter { $0.group != nil && $0.group == own }.map(Metrics.frame)
        let companyFrame = company.reduce(nil) { $0?.union($1) ?? $1 }
        let nearCompany = company.map { $0.insetBy(dx: -40, dy: -40) }
        var obstacles = others.filter { $0.group == nil || $0.group != own }.map { Metrics.frame(of: $0).insetBy(dx: -clearance, dy: -clearance) }
        for group in groups where group.id != own {
            guard let frame = frame(of: group.id, excluding: block.union(ignoring)) else { continue }
            obstacles.append(frame.insetBy(dx: -clearance, dy: -clearance))
        }
        func isOpen(_ rect: CGRect) -> Bool {
            let spanned = companyFrame.map { $0.union(rect) } ?? rect
            return !nearCompany.contains { $0.intersects(rect) } && !obstacles.contains { $0.intersects(spanned) }
        }

        // Nearest the anchor first, a little against left and above; searched wider until something's open.
        func score(_ rect: CGRect) -> CGFloat {
            let dx = max(anchor.minX - rect.maxX, rect.minX - anchor.maxX, 0)
            let dy = max(anchor.minY - rect.maxY, rect.minY - anchor.maxY, 0)
            return dx + dy + (rect.maxX <= anchor.minX ? 200 : 0) + (rect.maxY <= anchor.minY ? 100 : 0)
        }
        let step: CGFloat = 40
        var reach = max(layout.size.width, layout.size.height) + clearance * 2
        while reach < 40_000 {
            var best: (origin: CGPoint, score: CGFloat)?
            let area = anchor.insetBy(dx: -reach, dy: -reach)
            // ponytail: a grid search, O(candidates × tables); fine to hundreds of tables.
            for y in stride(from: area.minY, through: area.maxY - layout.size.height, by: step) {
                for x in stride(from: area.minX, through: area.maxX - layout.size.width, by: step) {
                    let rect = CGRect(origin: CGPoint(x: x, y: y), size: layout.size)
                    let value = score(rect)
                    guard value < best?.score ?? .infinity, isOpen(rect) else { continue }
                    best = (rect.origin, value)
                }
            }
            if let best { return arrangeBlock(layout, at: best.origin) }
            reach *= 2
        }
        arrangeBlock(layout, at: CGPoint(x: (fallback ?? anchor).maxX + clearance, y: anchor.minY))
    }

    /// Moves `ids` together, as a block in rows, its top left at `origin`.
    mutating func place(_ ids: [Table.ID], at origin: CGPoint) {
        arrangeBlock(blockLayout(ids), at: origin)
    }

    /// Whether `group`'s boundary runs over tables not in it, or other groups.
    func isCrowded(_ group: TableGroup.ID) -> Bool {
        guard let frame = frame(of: group) else { return false }
        return tables.contains { $0.group != group && Metrics.frame(of: $0).intersects(frame) }
            || groups.contains { $0.id != group && self.frame(of: $0.id)?.intersects(frame) == true }
    }

    /// `ids` as they are: where each is in the box around them all, and its size.
    private func currentLayout(_ ids: [Table.ID]) -> (positions: [(Table.ID, CGPoint)], size: CGSize) {
        let frames = ids.compactMap { id in table(id).map { (id, Metrics.frame(of: $0)) } }
        let bounds = frames.map(\.1).reduce(CGRect.null) { $0.union($1) }
        return (frames.map { ($0.0, $0.1.origin - bounds.origin) }, bounds.size)
    }

    private func blockLayout(_ ids: [Table.ID]) -> (positions: [(Table.ID, CGPoint)], size: CGSize) {
        let gap = CGSize(width: 96, height: 48)
        let columns = max(1, Int(CGFloat(ids.count).squareRoot().rounded(.up)))
        var positions: [(Table.ID, CGPoint)] = [], y: CGFloat = 0, width: CGFloat = 0
        for start in stride(from: 0, to: ids.count, by: columns) {
            let row = ids[start..<min(start + columns, ids.count)].compactMap { table($0) }
            for (column, table) in row.enumerated() {
                positions.append((table.id, CGPoint(x: CGFloat(column) * (Metrics.tableWidth + gap.width), y: y)))
            }
            width = max(width, CGFloat(row.count) * (Metrics.tableWidth + gap.width) - gap.width)
            y += (row.map { Metrics.size(of: $0).height }.max() ?? 0) + gap.height
        }
        return (positions, CGSize(width: width, height: max(y - gap.height, 0)))
    }

    private mutating func arrangeBlock(_ layout: (positions: [(Table.ID, CGPoint)], size: CGSize), at origin: CGPoint) {
        for (id, position) in layout.positions {
            if let index = tables.firstIndex(where: { $0.id == id }) { tables[index].position = origin + position }
        }
    }
}
