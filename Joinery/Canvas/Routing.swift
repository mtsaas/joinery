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
    init(schema: Schema, tableOffsets: [Table.ID: CGPoint] = [:], tieOffsets: [ZipTie.ID: CGPoint] = [:]) {
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

        // The points a wire runs between on either side of its `index`th tie.
        func neighbors(of relationship: Relationship, at index: Int) -> (CGPoint, CGPoint)? {
            guard let (start, end) = ends[relationship.id] else { return nil }
            let ties = relationship.zipTies
            let previous = index == 0 ? start.point : tiePositions[ties[index - 1]] ?? start.point
            let next = index == ties.count - 1 ? end.point : tiePositions[ties[index + 1]] ?? end.point
            return (previous, next)
        }

        // A tie turns to follow its wires: along the average of the way they run through it.
        let relationships = Dictionary(schema.relationships.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tie in schema.zipTies {
            guard let center = tiePositions[tie.id] else { continue }
            var sum = CGPoint.zero
            for case let relationship? in tie.relationships.map({ relationships[$0] }) {
                guard let index = relationship.zipTies.firstIndex(of: tie.id),
                      let (previous, next) = neighbors(of: relationship, at: index),
                      let way = (next - previous).normalized else { continue }
                sum += way.dot(tie.direction) < 0 ? -way : way
            }
            ties[tie.id] = Tie(center: center, direction: sum.normalized ?? tie.direction, relationships: tie.relationships)
        }

        for relationship in schema.relationships {
            guard let (start, end) = ends[relationship.id] else { continue }
            var waypoints = [start]
            for (index, id) in relationship.zipTies.enumerated() {
                guard let tie = ties[id], let slot = tie.relationships.firstIndex(of: relationship.id),
                      let (previous, next) = neighbors(of: relationship, at: index) else { continue }
                let tangent = (next - previous).dot(tie.direction) < 0 ? -tie.direction : tie.direction
                waypoints.append(Waypoint(point: tie.slot(slot), tangent: tangent, isTie: true))
            }
            waypoints.append(end)
            routes[relationship.id] = Self.route(through: waypoints)
        }
    }

    /// Tables closer than this side by side are treated as stacked.
    private static let sideGap: CGFloat = 24

    /// A cubic Bézier between each pair of waypoints, leaving and arriving along their tangents.
    private static func route(through waypoints: [Waypoint]) -> Route {
        var points: [CGPoint] = [], stiffness: [Double] = []
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            let reach = min(max(a.point.distance(to: b.point) * 0.45, 36), 220)
            // Reach further when the other end is behind, so the wire swings around instead of folding back.
            let control1 = a.point + a.tangent * (reach + max(0, (b.point - a.point).dot(-a.tangent)) / 2)
            let control2 = b.point - b.tangent * (reach + max(0, (a.point - b.point).dot(b.tangent)) / 2)
            for sample in 0..<samplesPerSegment {
                let t = CGFloat(sample) / CGFloat(samplesPerSegment), u = 1 - t
                let p1 = a.point * (u * u * u) + control1 * (3 * u * u * t)
                let p2 = control2 * (3 * u * t * t) + b.point * (t * t * t)
                points.append(p1 + p2)
                // Firm near the ends, loose in the middle, so a wire swings like a cable rather than moving rigidly.
                let looseness = sin(.pi * Double(t))
                stiffness.append(sample == 0 && !a.isTie
                    ? .infinity
                    : (sample == 0 ? Spring.tie : Spring.ends + (Spring.middle - Spring.ends) * looseness))
            }
        }
        points.append(waypoints[waypoints.count - 1].point)
        stiffness.append(.infinity)
        return Route(points: points, stiffness: stiffness)
    }
}
