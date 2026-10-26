import CoreGraphics
import Foundation

/// Ports on groups' edges, bundling the wires between a group's tables and a column outside it into one cable.
extension DataModel {
    /// Where a port sits and what runs through it.
    struct PortPlacement: Equatable {
        var group: TableGroup.ID
        /// The column outside the group it stands for, if it's plugged into one.
        var column: Column.ID?
        /// On the group's edge.
        var point: CGPoint
        /// Out of the group, square to its edge.
        var normal: CGPoint
        /// The column's name, with its table's: `entity.id`; empty while it's plugged into none.
        var label: String
        /// The wires bundled through it.
        var wires: [Relationship.ID]

        /// How big its pill is: as long as its name, along the edge.
        var size: CGSize { Metrics.portSize(label: label) }
        /// Its sockets, just past the ends of its pill square to the edge: the inside one, for the group's tables'
        /// wires, and the outside one, for its bus.
        var inside: CGPoint { point - normal * socketDistance }
        var outside: CGPoint { point + normal * socketDistance }
        /// Where the `index`th of `count` wires through it plugs in: side by side across its inside end, a tie's
        /// spacing apart, so they leave as separate wires, not one bundle.
        func insideSlot(_ index: Int, of count: Int) -> CGPoint {
            guard count > 1 else { return inside }
            return insideTie + normal.perpendicular * ((CGFloat(index) - CGFloat(count - 1) / 2) * Metrics.tieSpacing)
        }
        /// The middle of the tie holding several wires across its inside end, against the pill.
        var insideTie: CGPoint { point - normal * (extent / 2 + Metrics.tieThickness / 2) }
        private var socketDistance: CGFloat { extent / 2 + Metrics.socketDiameter / 2 + 1 }
        /// How far the pill reaches square to the edge.
        private var extent: CGFloat { normal.x == 0 ? size.height : size.width }
    }

    // MARK: Cables

    /// Every cable: each foreign key's wire, and each port's bus, by the port's ID. Zip ties and bend points hold
    /// either.
    var cableIDs: [UUID] { relationships.map(\.id) + groups.flatMap(\.ports).map(\.id) }

    /// The ties a cable runs through, in order from its start; nil if there's no such cable.
    func zipTies(onCable id: UUID) -> [ZipTie.ID]? {
        relationships.first { $0.id == id }?.zipTies ?? groups.lazy.flatMap(\.ports).first { $0.id == id }?.zipTies
    }

    mutating func setZipTies(onCable id: UUID, _ ties: [ZipTie.ID]) {
        if let index = relationships.firstIndex(where: { $0.id == id }) { return relationships[index].zipTies = ties }
        for group in groups.indices {
            if let port = groups[group].ports.firstIndex(where: { $0.id == id }) { groups[group].ports[port].zipTies = ties }
        }
    }

    /// Whether a cable is a port's bus.
    func isBus(_ id: UUID) -> Bool { groups.contains { $0.ports.contains { $0.id == id } } }

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
                let target = port.column.flatMap { locations[$0] }.flatMap { $0.table.group == group.id ? nil : $0 }
                // Toward its column, if it has one: the side the column is beyond, by which way out of the middle it's
                // furthest, for the group's shape.
                let aim = target.map { target in
                    let frame = frameOf(target.table)
                    return CGPoint(x: frame.midX, y: frame.minY + Metrics.headerHeight + (CGFloat(target.row) + 0.5) * Metrics.rowHeight)
                } ?? CGPoint(x: frame.maxX, y: frame.midY)
                let dx = (aim.x - frame.midX) / frame.width, dy = (aim.y - frame.midY) / frame.height
                let side: Side4 = port.side ?? (abs(dx) >= abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .top : .bottom))
                // Put somewhere, it stays that far along its side; otherwise it's as near the column as the side reaches.
                let span = Self.span(of: side, in: frame)
                let along = port.along.map { span.lowerBound + $0 * (span.upperBound - span.lowerBound) }
                    ?? (side.isVertical ? aim.y : aim.x)
                let wires = target == nil ? [] : relationships.filter { wire in
                    let other = wire.to == port.column ? wire.from : wire.from == port.column ? wire.to : nil
                    return other.flatMap { locations[$0] }?.table.group == group.id
                }.map(\.id)
                let placement = PortPlacement(group: group.id, column: target == nil ? nil : port.column, point: .zero, normal: side.normal,
                                              label: target.map { "\($0.table.name).\($0.table.columns[$0.row].name)" } ?? "", wires: wires)
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
    func portSpot(nearest point: CGPoint, on group: TableGroup.ID, offsets: [Table.ID: CGPoint] = [:]) -> (side: Side4, along: CGFloat)? {
        guard let frame = frame(of: group, offsets: offsets) else { return nil }
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

    /// Where on `group`'s edge a spot is.
    func edgePoint(of group: TableGroup.ID, at spot: (side: Side4, along: CGFloat), offsets: [Table.ID: CGPoint] = [:]) -> CGPoint? {
        guard let frame = frame(of: group, offsets: offsets) else { return nil }
        let span = Self.span(of: spot.side, in: frame)
        let along = span.lowerBound + spot.along * (span.upperBound - span.lowerBound)
        return switch spot.side {
        case .left: CGPoint(x: frame.minX, y: along)
        case .right: CGPoint(x: frame.maxX, y: along)
        case .top: CGPoint(x: along, y: frame.minY)
        case .bottom: CGPoint(x: along, y: frame.maxY)
        }
    }

    /// The port whose pill is under `point`, with tables moved by `offsets`.
    func port(at point: CGPoint, offsets: [Table.ID: CGPoint] = [:]) -> GroupPort.ID? {
        portPlacements(offsets: offsets).first { _, port in
            CGRect(x: port.point.x - port.size.width / 2, y: port.point.y - port.size.height / 2,
                   width: port.size.width, height: port.size.height).contains(point)
        }?.key
    }

    /// A port's socket within `reach` of `point`: its outside one, or its inside.
    func portSocket(at point: CGPoint, within reach: CGFloat, offsets: [Table.ID: CGPoint] = [:]) -> (port: GroupPort.ID, isOutside: Bool, center: CGPoint)? {
        for (id, port) in portPlacements(offsets: offsets) {
            if port.outside.distance(to: point) <= reach { return (id, true, port.outside) }
            if port.inside.distance(to: point) <= reach { return (id, false, port.inside) }
        }
        return nil
    }

    /// Adds a nameless port to `group`, at `spot` on its edge, plugged into nothing yet.
    @discardableResult
    mutating func addPort(to group: TableGroup.ID, at spot: (side: Side4, along: CGFloat)) -> GroupPort.ID? {
        guard let index = groups.firstIndex(where: { $0.id == group }) else { return nil }
        let port = GroupPort(column: nil, side: spot.side, along: spot.along)
        groups[index].ports.append(port)
        return port.id
    }

    /// Plugs a port's outside into `column`, outside its group, in place of whatever it was plugged into; the wires
    /// it then bundles come out of their zip ties, which were placed where they ran before.
    mutating func plug(_ id: GroupPort.ID, into column: Column.ID) {
        guard let group = group(ofPort: id), columnLocations[column].map({ $0.table.group != group }) == true else { return }
        for g in groups.indices {
            guard let index = groups[g].ports.firstIndex(where: { $0.id == id }) else { continue }
            groups[g].ports[index].column = column
            groups[g].ports[index].zipTies = []
        }
        let wires = Set(portPlacements()[id]?.wires ?? [])
        for index in relationships.indices where wires.contains(relationships[index].id) { relationships[index].zipTies = [] }
        repair()
    }

    /// Takes a port away, so its wires run all the way again.
    mutating func removePort(_ id: GroupPort.ID) {
        for group in groups.indices { groups[group].ports.removeAll { $0.id == id } }
        repair()
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
        repair()
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
