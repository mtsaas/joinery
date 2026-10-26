import CoreGraphics
import Foundation

/// Ports on groups' edges, bundling the wires between a group's tables and a column outside it into one cable.
extension DataModel {
    /// Where a port sits and what runs through it.
    struct PortPlacement: Equatable {
        var group: TableGroup.ID
        /// The column outside the group it stands for.
        var column: Column.ID
        /// On the group's edge.
        var point: CGPoint
        /// Out of the group, square to its edge.
        var normal: CGPoint
        /// The column's name, with its table's: `entity.id`.
        var label: String
        /// The wires bundled through it.
        var wires: [Relationship.ID]
    }

    /// Every port's place, with tables moved by `offsets`: on the edge of its group facing its column, as near the
    /// column as the edge reaches, kept clear of the corners and of the other ports on that edge.
    func portPlacements(offsets: [Table.ID: CGPoint] = [:]) -> [GroupPort.ID: PortPlacement] {
        guard groups.contains(where: { !$0.ports.isEmpty }) else { return [:] }
        let locations = columnLocations
        let frameOf = { (table: Table) in Metrics.frame(of: table).offsetBy(dx: offsets[table.id]?.x ?? 0, dy: offsets[table.id]?.y ?? 0) }
        var placements: [GroupPort.ID: PortPlacement] = [:]
        for group in groups where !group.ports.isEmpty {
            guard let frame = frame(of: group.id, offsets: offsets) else { continue }
            // Ports on each side, with where along it they'd like to be.
            var sides: [Side4: [(id: GroupPort.ID, along: CGFloat, placement: PortPlacement)]] = [:]
            for port in group.ports {
                guard let target = locations[port.column], target.table.group != group.id else { continue }
                let targetFrame = frameOf(target.table)
                let aim = CGPoint(x: targetFrame.midX, y: targetFrame.minY + Metrics.headerHeight + (CGFloat(target.row) + 0.5) * Metrics.rowHeight)
                // The side the column is beyond, by which way out of the middle it's furthest, for the group's shape.
                let dx = (aim.x - frame.midX) / frame.width, dy = (aim.y - frame.midY) / frame.height
                let side: Side4 = port.side ?? (abs(dx) >= abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .top : .bottom))
                // Put somewhere, it stays that far along its side; otherwise it's as near the column as the side reaches.
                let span = Self.span(of: side, in: frame)
                let along = port.along.map { span.lowerBound + $0 * (span.upperBound - span.lowerBound) }
                    ?? (side.isVertical ? aim.y : aim.x)
                let wires = relationships.filter { wire in
                    let other = wire.to == port.column ? wire.from : wire.from == port.column ? wire.to : nil
                    return other.flatMap { locations[$0] }?.table.group == group.id
                }.map(\.id)
                let placement = PortPlacement(group: group.id, column: port.column, point: .zero, normal: side.normal,
                                              label: "\(target.table.name).\(target.table.columns[target.row].name)", wires: wires)
                sides[side, default: []].append((port.id, along, placement))
            }
            for (side, ports) in sides {
                // Along the edge, clear of the rounded corners, a pill apart.
                let spacing = Self.spacing(on: side), span = Self.span(of: side, in: frame)
                let (low, high) = (span.lowerBound, span.upperBound)
                var previous = -CGFloat.infinity
                for var port in ports.sorted(by: { $0.along < $1.along }) {
                    let along = max(min(port.along, high), low, previous + spacing)
                    previous = along
                    port.placement.point = switch side {
                    case .left: CGPoint(x: frame.minX, y: along)
                    case .right: CGPoint(x: frame.maxX, y: along)
                    case .top: CGPoint(x: along, y: frame.minY)
                    case .bottom: CGPoint(x: along, y: frame.maxY)
                    }
                    placements[port.id] = port.placement
                }
            }
        }
        return placements
    }

    /// How far apart ports on a side are kept.
    private static func spacing(on side: Side4) -> CGFloat {
        side.isVertical ? Metrics.portHeight + 8 : Metrics.portWidth + 8
    }

    /// Where along a side of a group's `frame` a port's middle can be: clear of the rounded corners, and on the left
    /// and right, of the name's line.
    private static func span(of side: Side4, in frame: CGRect) -> ClosedRange<CGFloat> {
        let margin = Metrics.groupCornerRadius + spacing(on: side) / 2
        let low = (side.isVertical ? frame.minY + Metrics.groupLabelHeight : frame.minX) + margin
        let high = (side.isVertical ? frame.maxY : frame.maxX) - margin
        return low <= high ? low...high : (low + high) / 2...(low + high) / 2
    }

    /// The spot on `group`'s edge nearest `point`, for a port dragged there: its side, and how far along.
    func portSpot(nearest point: CGPoint, on group: TableGroup.ID) -> (side: Side4, along: CGFloat)? {
        guard let frame = frame(of: group) else { return nil }
        let spots = [Side4.left, .right, .top, .bottom].map { side -> (side: Side4, along: CGFloat, distance: CGFloat) in
            let span = Self.span(of: side, in: frame)
            let along = min(max(side.isVertical ? point.y : point.x, span.lowerBound), span.upperBound)
            let spot = switch side {
            case .left: CGPoint(x: frame.minX, y: along)
            case .right: CGPoint(x: frame.maxX, y: along)
            case .top: CGPoint(x: along, y: frame.minY)
            case .bottom: CGPoint(x: along, y: frame.maxY)
            }
            let length = span.upperBound - span.lowerBound
            return (side, length > 0 ? (along - span.lowerBound) / length : 0.5, spot.distance(to: point))
        }
        return spots.min { $0.distance < $1.distance }.map { ($0.side, $0.along) }
    }

    /// The port whose pill is under `point`, with tables moved by `offsets`.
    func port(at point: CGPoint, offsets: [Table.ID: CGPoint] = [:]) -> GroupPort.ID? {
        portPlacements(offsets: offsets).first { _, port in
            let size = Metrics.portSize(label: port.label)
            return CGRect(x: port.point.x - size.width / 2, y: port.point.y - size.height / 2, width: size.width, height: size.height).contains(point)
        }?.key
    }

    /// The group a port is on.
    func group(ofPort id: GroupPort.ID) -> TableGroup.ID? {
        groups.first { $0.ports.contains { $0.id == id } }?.id
    }

    /// Puts a port somewhere on its group's edge, or back facing its column with nil.
    mutating func movePort(_ id: GroupPort.ID, to spot: (side: Side4, along: CGFloat)?) {
        for group in groups.indices {
            guard let index = groups[group].ports.firstIndex(where: { $0.id == id }) else { continue }
            groups[group].ports[index].side = spot?.side
            groups[group].ports[index].along = spot?.along
        }
    }

    /// Adds a port to `group` for `column`, which has to be outside it, and takes the wires it bundles out of their zip
    /// ties: those were placed where the wires ran before.
    @discardableResult
    mutating func addPort(to group: TableGroup.ID, for column: Column.ID) -> GroupPort.ID? {
        guard let index = groups.firstIndex(where: { $0.id == group }), let target = columnLocations[column],
              target.table.group != group, !groups[index].ports.contains(where: { $0.column == column }) else { return nil }
        let port = GroupPort(column: column)
        groups[index].ports.append(port)
        let wires = Set(portPlacements()[port.id]?.wires ?? [])
        for index in relationships.indices where wires.contains(relationships[index].id) { relationships[index].zipTies = [] }
        repair()
        return port.id
    }

    /// Bundles the wires from `group`'s tables to each column outside it that `minimum` or more of them go to.
    /// - Returns: How many ports were added.
    @discardableResult
    mutating func bundleSharedWires(in group: TableGroup.ID, minimum: Int = 3) -> Int {
        let locations = columnLocations
        var counts: [Column.ID: Int] = [:]
        for wire in relationships {
            let (from, to) = (locations[wire.from]?.table.group == group, locations[wire.to]?.table.group == group)
            if from && !to { counts[wire.to, default: 0] += 1 }
            if to && !from { counts[wire.from, default: 0] += 1 }
        }
        // Most shared first, so they take the best places.
        let shared = counts.filter { $0.value >= minimum }.sorted { ($0.value, $0.key.uuidString) > ($1.value, $1.key.uuidString) }
        return shared.reduce(0) { count, entry in count + (addPort(to: group, for: entry.key) == nil ? 0 : 1) }
    }

    /// Takes away `group`'s ports, so its wires run all the way again.
    mutating func removePorts(from group: TableGroup.ID) {
        guard let index = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[index].ports = []
    }
}

/// A side of a rectangle.
enum Side4: String, Codable, Hashable {
    case left, right, top, bottom

    var isVertical: Bool { self == .left || self == .right }

    var normal: CGPoint {
        switch self {
        case .left: CGPoint(x: -1, y: 0)
        case .right: CGPoint(x: 1, y: 0)
        case .top: CGPoint(x: 0, y: -1)
        case .bottom: CGPoint(x: 0, y: 1)
        }
    }
}
