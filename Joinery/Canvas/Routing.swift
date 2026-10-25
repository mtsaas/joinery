import CoreGraphics
import Foundation

/// Where every wire comes to rest: a smooth curve from its foreign key's socket, through its zip ties, to the
/// referenced column's socket. The simulation springs the drawn wires toward these.
struct Routing {
    /// Points each segment between two waypoints (sockets or ties) is sampled at.
    static let samplesPerSegment = 20

    struct Route {
        var points: [CGPoint]
        /// How hard each point pulls its wire toward it; infinite at sockets, which wires are pinned to.
        var stiffness: [Double]
    }

    struct Tie {
        var center: CGPoint
        /// Along the bundle, a unit vector.
        var direction: CGPoint
        var relationships: [Relationship.ID]

        func slot(_ index: Int) -> CGPoint {
            center + direction.perpendicular * ((CGFloat(index) - CGFloat(relationships.count - 1) / 2) * Metrics.tieSpacing)
        }
    }

    private struct Waypoint {
        var point: CGPoint
        /// The direction the wire runs through this point.
        var tangent: CGPoint
        var isTie = false
    }

    struct Socket: Hashable {
        var column: Column.ID
        var side: Side
    }

    private(set) var routes: [Relationship.ID: Route] = [:]
    private(set) var ties: [ZipTie.ID: Tie] = [:]
    /// The sockets each wire is plugged into: its foreign key's, then the referenced column's.
    private(set) var sockets: [Relationship.ID: (from: Socket, to: Socket)] = [:]

    /// - Parameters:
    ///   - tableOffsets: How far tables being dragged have moved, not yet saved to `schema`.
    ///   - tieOffsets: The same for zip ties.
    ///   - avoidingTables: Whether wires bend around tables in their way rather than running under them.
    init(schema: Schema, tableOffsets: [Table.ID: CGPoint] = [:], tieOffsets: [ZipTie.ID: CGPoint] = [:],
         avoidingTables: Bool = false) {
        var frames: [Table.ID: CGRect] = [:]
        var rows: [Column.ID: (table: Table.ID, row: Int)] = [:]
        for table in schema.tables {
            frames[table.id] = Metrics.frame(of: table).offsetBy(dx: tableOffsets[table.id]?.x ?? 0, dy: tableOffsets[table.id]?.y ?? 0)
            for (row, column) in table.columns.enumerated() { rows[column.id] = (table.id, row) }
        }
        let tiePositions = Dictionary(schema.zipTies.map { ($0.id, $0.position + (tieOffsets[$0.id] ?? .zero)) },
                                      uniquingKeysWith: { first, _ in first })

        // Each wire leaves and enters on the side of its tables that faces where it's going.
        var ends: [Relationship.ID: (start: Waypoint, end: Waypoint)] = [:]
        for relationship in schema.relationships {
            guard let from = rows[relationship.from], let to = rows[relationship.to],
                  let fromFrame = frames[from.table], let toFrame = frames[to.table] else { continue }
            let tied = relationship.zipTies.compactMap { tiePositions[$0] }
            let startSide: Side, endSide: Side
            if let first = tied.first, let last = tied.last {
                startSide = first.x < fromFrame.midX ? .leading : .trailing
                endSide = last.x < toFrame.midX ? .leading : .trailing
            } else if fromFrame.maxX + Self.sideGap <= toFrame.minX {
                (startSide, endSide) = (.trailing, .leading)
            } else if toFrame.maxX + Self.sideGap <= fromFrame.minX {
                (startSide, endSide) = (.leading, .trailing)
            } else {
                // Stacked or the same table: loop out and back on one side.
                (startSide, endSide) = (.trailing, .trailing)
            }
            sockets[relationship.id] = (Socket(column: relationship.from, side: startSide),
                                        Socket(column: relationship.to, side: endSide))
            ends[relationship.id] = (
                Waypoint(point: Metrics.socket(row: from.row, side: startSide, in: fromFrame), tangent: startSide.outward),
                Waypoint(point: Metrics.socket(row: to.row, side: endSide, in: toFrame), tangent: -endSide.outward)
            )
        }

        // The points a wire runs between on either side of its `index`th tie. Sockets come with the way the wire
        // runs through them; neighboring ties don't have one yet.
        func neighbors(of relationship: Relationship, at index: Int) -> (previous: Waypoint, next: Waypoint)? {
            guard let (start, end) = ends[relationship.id] else { return nil }
            let ties = relationship.zipTies
            let previous = index == 0 ? start : tiePositions[ties[index - 1]].map { Waypoint(point: $0, tangent: .zero) } ?? start
            let next = index == ties.count - 1 ? end : tiePositions[ties[index + 1]].map { Waypoint(point: $0, tangent: .zero) } ?? end
            return (previous, next)
        }

        // The way a wire runs through a tie at `center`: straight from its neighbors when it's far from them, but
        // close to a socket, the way it leaves that socket, so it doesn't have to turn hard in the gap between.
        func flow(of relationship: Relationship, at index: Int, through center: CGPoint) -> CGPoint? {
            guard let (previous, next) = neighbors(of: relationship, at: index),
                  let chord = (next.point - previous.point).normalized else { return nil }
            let before = previous.point.distance(to: center), after = center.distance(to: next.point)
            let near = before < after ? previous : next
            let pull = max(0, 1 - min(before, after) / Self.socketReach) * (near.tangent == .zero ? 0 : 1)
            return (chord * (1 - pull) + near.tangent * pull).normalized ?? chord
        }

        // A tie turns to follow its wires: along the average of the way they run through it.
        let relationships = Dictionary(schema.relationships.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tie in schema.zipTies {
            guard let center = tiePositions[tie.id] else { continue }
            var sum = CGPoint.zero
            for case let relationship? in tie.relationships.map({ relationships[$0] }) {
                guard let index = relationship.zipTies.firstIndex(of: tie.id),
                      let way = flow(of: relationship, at: index, through: center) else { continue }
                sum += way.dot(tie.direction) < 0 ? -way : way
            }
            ties[tie.id] = Tie(center: center, direction: sum.normalized ?? tie.direction, relationships: tie.relationships)
        }

        for relationship in schema.relationships {
            guard let (start, end) = ends[relationship.id] else { continue }
            var waypoints = [start]
            for (index, id) in relationship.zipTies.enumerated() {
                guard let tie = ties[id], let slot = tie.relationships.firstIndex(of: relationship.id),
                      let way = flow(of: relationship, at: index, through: tie.center) else { continue }
                let tangent = way.dot(tie.direction) < 0 ? -tie.direction : tie.direction
                waypoints.append(Waypoint(point: tie.slot(slot), tangent: tangent, isTie: true))
            }
            waypoints.append(end)
            routes[relationship.id] = Self.route(through: waypoints)
        }

        if avoidingTables {
            for relationship in schema.relationships {
                // A wire isn't pushed off the tables it plugs into, only kept from running under them.
                let own = [relationship.from, relationship.to].compactMap { rows[$0].flatMap { frames[$0.table] } }
                let others = frames.values.filter { !own.contains($0) }
                routes[relationship.id]?.avoid(others, staying: own)
            }
        }
    }

    /// How far a table's push on wires reaches; wires settle around a table at roughly half this.
    static let avoidanceReach: CGFloat = 44
    /// The least a wire keeps from a table it avoids. Less than `Metrics.wireLead`, so a wire's own pinned lead out of
    /// its socket is already clear of its table.
    static let minimumClearance: CGFloat = 8
    static let avoidancePasses = 30

    /// Tables closer than this side by side are treated as stacked.
    private static let sideGap: CGFloat = 24
    /// Within this of a socket, a tie turns toward the socket's own direction; at the socket, all the way.
    private static let socketReach: CGFloat = 160

    /// A cubic Bézier between each pair of waypoints, leaving and arriving along their tangents.
    private static func route(through waypoints: [Waypoint]) -> Route {
        var points: [CGPoint] = [], stiffness: [Double] = []
        let count = samplesPerSegment
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            // At a socket the wire runs straight out for `Metrics.wireLead` before it curves, and both points of that
            // lead are pinned, so it always leaves square to the table's side however the rest of it swings.
            let start = a.isTie ? a.point : a.point + a.tangent * Metrics.wireLead
            let end = b.isTie ? b.point : b.point - b.tangent * Metrics.wireLead
            // Handles never longer than half the gap, or a short hop (a tie near a socket) overshoots and hooks.
            let gap = start.distance(to: end)
            let reach = min(max(gap * 0.45, min(36, gap / 2)), 220)
            // Reach further when the other end is behind, so the wire swings around instead of folding back.
            let control1 = start + a.tangent * (reach + max(0, (end - start).dot(-a.tangent)) / 2)
            let control2 = end - b.tangent * (reach + max(0, (start - end).dot(b.tangent)) / 2)
            // Which samples the curve spans: after the lead at a socket start, up to the lead at a socket end.
            let first = a.isTie ? 0 : 1, last = b.isTie ? count : count - 1
            for sample in 0..<count {
                if sample == 0, !a.isTie {
                    points.append(a.point)
                    stiffness.append(.infinity)
                    continue
                }
                let t = CGFloat(sample - first) / CGFloat(last - first), u = 1 - t
                let near = start * (u * u * u) + control1 * (3 * u * u * t)
                let far = control2 * (3 * u * t * t) + end * (t * t * t)
                points.append(near + far)
                // Firm near the ends, loose in the middle, so a wire swings like a cable rather than moving rigidly.
                let looseness = sin(.pi * Double(t))
                stiffness.append(sample == first && !a.isTie || sample == last
                    ? .infinity
                    : sample == 0 ? Spring.tie : Spring.ends + (Spring.middle - Spring.ends) * looseness)
            }
        }
        points.append(waypoints[waypoints.count - 1].point)
        stiffness.append(.infinity)
        return Route(points: points, stiffness: stiffness)
    }
}

extension Routing.Route {
    /// Bends the wire's free stretches around `obstacles`, like a hose pushed aside: each table pushes nearby points
    /// away, harder the closer they are, while the wire's tension smooths it, until the two balance in an easy arc.
    /// A stretch that starts out under a table is first lifted out on one side (the nearer, across its way of travel),
    /// so it goes around rather than through, and a last pass makes sure nothing ends up under a table.
    // ponytail: wires × points × tables × passes per redraw; spatial bucketing if schemas reach hundreds of tables.
    /// - Parameter own: The wire's own tables, which it's only kept out from under.
    mutating func avoid(_ obstacles: [CGRect], staying own: [CGRect] = []) {
        // Sockets, their leads and zip-tie slots stay put; the rest may move.
        let isFree = stiffness.map { $0 < Spring.tie }
        let reach = Routing.avoidanceReach
        let xs = points.map(\.x), ys = points.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let obstacles = obstacles.filter { $0.insetBy(dx: -reach, dy: -reach).intersects(bounds) }
        let own = own.filter { $0.intersects(bounds) }
        guard !obstacles.isEmpty || !own.isEmpty else { return }

        /// Moves each run of free points inside `rect` out past the side its run is nearer.
        func liftOut(of rect: CGRect, to margin: CGFloat) {
            let rect = rect.insetBy(dx: -margin, dy: -margin)
            var index = 1
            while index < points.count - 1 {
                guard isFree[index], rect.contains(points[index]) else { index += 1; continue }
                var end = index
                while end + 1 < points.count - 1, isFree[end + 1], rect.contains(points[end + 1]) { end += 1 }
                let run = index...end
                let travel = points[end + 1] - points[index - 1]
                let middle = run.map { points[$0] }.reduce(.zero, +) / CGFloat(run.count)
                for i in run {
                    if abs(travel.x) >= abs(travel.y) {
                        points[i].y = middle.y < rect.midY ? rect.minY : rect.maxY
                    } else {
                        points[i].x = middle.x < rect.midX ? rect.minX : rect.maxX
                    }
                }
                index = end + 1
            }
        }

        for rect in obstacles + own { liftOut(of: rect, to: Routing.minimumClearance) }
        for _ in 0..<Routing.avoidancePasses {
            // Push: each point away from the nearest spot on each table, by how far inside the reach it is.
            for i in points.indices where isFree[i] {
                for rect in obstacles {
                    let nearest = CGPoint(x: min(max(points[i].x, rect.minX), rect.maxX), y: min(max(points[i].y, rect.minY), rect.maxY))
                    let away = points[i] - nearest, distance = away.length
                    guard distance < reach, let direction = away.normalized else { continue }
                    points[i] += direction * ((reach - distance) * 0.5)
                }
            }
            // Tension: each point toward the middle of its neighbors.
            let before = points
            for i in points.indices.dropFirst().dropLast() where isFree[i] {
                points[i] = before[i] + ((before[i - 1] + before[i + 1]) / 2 - before[i]) * 0.5
            }
        }
        for rect in obstacles + own { liftOut(of: rect, to: Routing.minimumClearance) }
    }
}
