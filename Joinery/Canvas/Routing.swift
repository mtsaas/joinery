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
        /// How free each point is to be pushed aside, from 0 at sockets and ties to nearly 1 well away from them.
        var flexibility: [Double]
        /// How far along the wire each point is from the nearest socket or tie.
        var anchorDistance: [CGFloat]
        /// Where the wire passes through a zip tie (or bend point). The wire on either side is its own cable, held
        /// there as at a socket; nothing on one side reaches the other.
        var isTieSlot: [Bool]
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

    #if DEBUG
    /// How many routings have been worked out, to check redraws aren't redoing it needlessly.
    nonisolated(unsafe) static var built = 0
    #endif

    /// - Parameters:
    ///   - tableOffsets: How far tables being dragged have moved, not yet saved to `schema`.
    ///   - tieOffsets: The same for zip ties.
    ///   - avoidingTables: Whether wires bend around tables in their way rather than running under them.
    init(schema: Schema, tableOffsets: [Table.ID: CGPoint] = [:], tieOffsets: [ZipTie.ID: CGPoint] = [:],
         avoidingTables: Bool = false) {
        #if DEBUG
        Self.built += 1
        #endif
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

        // The points a wire runs between on either side of its `index`th tie, with the way it runs at each: out of or
        // into a socket, or for a neighboring tie, straight from it.
        func neighbors(of relationship: Relationship, at index: Int, through center: CGPoint) -> (previous: Waypoint, next: Waypoint)? {
            guard var (previous, next) = ends[relationship.id] else { return nil }
            let ties = relationship.zipTies
            if index > 0, let point = tiePositions[ties[index - 1]] {
                previous = Waypoint(point: point, tangent: (center - point).normalized ?? .zero)
            }
            if index < ties.count - 1, let point = tiePositions[ties[index + 1]] {
                next = Waypoint(point: point, tangent: (point - center).normalized ?? .zero)
            }
            return (previous, next)
        }

        // A tie turns to where its wires bend least, as one free to swivel would: each angle is scored by the least
        // bending every wire through it could manage there, each wire passing whichever way through suits it.
        // ponytail: about 0.6 ms a tie per redraw (19 angles × its wires × 9 curve shapes); cache by neighbor
        // positions if schemas with dozens of ties stutter while dragging.
        let relationships = Dictionary(schema.relationships.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ways: [ZipTie.ID: [Relationship.ID: CGFloat]] = [:]
        for tie in schema.zipTies {
            guard let center = tiePositions[tie.id] else { continue }
            let passes = tie.relationships.compactMap { id -> (Relationship.ID, Waypoint, Waypoint)? in
                guard let relationship = relationships[id], let index = relationship.zipTies.firstIndex(of: tie.id),
                      let (previous, next) = neighbors(of: relationship, at: index, through: center) else { return nil }
                return (id, previous, next)
            }
            func score(_ angle: CGFloat) -> (bending: CGFloat, direction: CGPoint, ways: [Relationship.ID: CGFloat]) {
                let direction = CGPoint(x: cos(angle), y: sin(angle))
                var bending: CGFloat = 0, choice: [Relationship.ID: CGFloat] = [:]
                for (id, previous, next) in passes {
                    let (sign, least) = [CGFloat(1), -1].map { sign in
                        let slot = Waypoint(point: center, tangent: direction * sign)
                        return (sign, Self.easiestCurve(from: previous, to: slot, trying: Self.quickHandleChoices).bending
                                    + Self.easiestCurve(from: slot, to: next, trying: Self.quickHandleChoices).bending)
                    }.min { $0.1 < $1.1 }!
                    bending += least
                    choice[id] = sign
                }
                return (bending, direction, choice)
            }
            // Every 15°, then every 2.5° either side of the best.
            let coarse = (0..<12).map { CGFloat($0) * .pi / 12 }.map(score).min { $0.bending < $1.bending }!
            let around = atan2(coarse.direction.y, coarse.direction.x)
            let fine = (-3...3).map { around + CGFloat($0) * .pi / 72 }.map(score).min { $0.bending < $1.bending }!
            var (direction, choice) = (fine.direction, fine.ways)
            // Keep the way it was tied, so its wires' order across it doesn't flip.
            if direction.dot(tie.direction) < 0 {
                direction = -direction
                choice = choice.mapValues { -$0 }
            }
            ties[tie.id] = Tie(center: center, direction: direction, relationships: tie.relationships)
            ways[tie.id] = choice
        }

        for relationship in schema.relationships {
            guard let (start, end) = ends[relationship.id] else { continue }
            var waypoints = [start]
            for id in relationship.zipTies {
                guard let tie = ties[id], let slot = tie.relationships.firstIndex(of: relationship.id) else { continue }
                let way = ways[id]?[relationship.id] ?? 1
                waypoints.append(Waypoint(point: tie.slot(slot), tangent: tie.direction * way, isTie: true))
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

    /// How far out of a socket or tie the wire is held: completely at the anchor, easing to not at all here. It's
    /// stiffer there while things move, and avoidance can't push it, so it leaves square and bends progressively.
    static let squareReach: CGFloat = 72
    /// Names this version of the routing in saved feedback, with `parameters`. Change it when the method changes, so
    /// feedback can be told apart by what produced the line it corrects.
    static let version = "2026-10-25 elastic"

    /// The tuning constants, for saved feedback.
    static var parameters: [String: Double] {
        ["samplesPerSegment": Double(samplesPerSegment), "squareReach": squareReach, "avoidanceReach": avoidanceReach,
         "avoidancePasses": Double(avoidancePasses), "avoidanceSettlingPasses": Double(avoidanceSettlingPasses),
         "pushRunway": pushRunway, "endStiffening": endStiffening, "tension": tension]
    }

    /// How far a table's push on wires reaches; it fades smoothly to nothing there.
    static let avoidanceReach: CGFloat = 64
    static let avoidancePasses = 40
    static let avoidanceSettlingPasses = 12
    /// Points of wire, out from a socket or tie, over which each point of avoidance push is faded in.
    static let pushRunway: CGFloat = 2.5

    /// Tables closer than this side by side are treated as stacked.
    private static let sideGap: CGFloat = 24
    /// The cubic from `a` to `b`, leaving and arriving along their tangents, as a cable under tension would settle:
    /// the handle lengths (as fractions of the gap) from `handleChoices` whose curve has the least ∫κ² ds + tension ×
    /// length, summed over a sampling of it. Tight bends cost a lot and length a little, so a cable swings round
    /// rather than hooking, without ballooning.
    private static func easiestCurve(from a: Waypoint, to b: Waypoint,
                                     trying choices: [CGFloat] = handleChoices) -> (bending: CGFloat, start: CGFloat, end: CGFloat) {
        let length = max(a.point.distance(to: b.point), 1)
        var best = (bending: CGFloat.infinity, start: length / 3, end: length / 3)
        for start in choices {
            for end in choices {
                let bending = bending(of: [a.point, a.point + a.tangent * (start * length),
                                           b.point - b.tangent * (end * length), b.point])
                if bending < best.bending { best = (bending, start * length, end * length) }
            }
        }
        return best
    }

    /// How much stiffer, at a socket or tie itself, a cable is than along its length.
    private static let endStiffening: CGFloat = 8

    /// How much a point of length costs against bending: 1/r² where r is the radius at which a bend's cost and the
    /// length it adds balance. Larger radii mean lazier, wider curves.
    private static let tension: CGFloat = 1 / (40 * 40)

    /// Bézier handle lengths tried, as fractions of the gap between the two ends.
    private static let handleChoices: [CGFloat] = [0.2, 0.3, 0.45, 0.65, 0.9, 1.2]
    /// Fewer, for scoring a tie's many candidate angles; the chosen one's curves use all of `handleChoices`.
    private static let quickHandleChoices: [CGFloat] = [0.25, 0.5, 0.9]

    /// About ∫κ² ds along a cubic Bézier: each sample's turn squared over the length around it.
    private static func bending(of control: [CGPoint]) -> CGFloat {
        let count = 16
        let points = (0...count).map { step -> CGPoint in
            let t = CGFloat(step) / CGFloat(count), u = 1 - t
            return control[0] * (u * u * u) + control[1] * (3 * u * u * t) + control[2] * (3 * u * t * t) + control[3] * (t * t * t)
        }
        // The ends' own directions count too, so leaving or arriving askew is a bend like any other.
        let directions = [(control[1] - control[0]).normalized] + zip(points, points.dropFirst()).map { ($1 - $0).normalized }
            + [(control[3] - control[2]).normalized]
        // Tension: every point of length costs too, or the least bending would be a wide, lazy loop.
        let steps = zip(points, points.dropFirst()).map { $0.distance(to: $1) }
        var total = steps.reduce(0, +) * tension
        // How far along the curve each sample is, to stiffen it near either end.
        var along: [CGFloat] = [0]
        for step in steps { along.append(along[along.count - 1] + step) }
        let length = along[along.count - 1]
        for index in 1..<directions.count {
            guard let before = directions[index - 1], let after = directions[index] else { continue }
            let turn = acos(min(1, max(-1, before.dot(after))))
            let at = min(max(index - 1, 0), points.count - 1)
            let around = index - 1 < points.count - 1 ? steps[min(at, steps.count - 1)] : 1
            // A cable is stiffest where it meets a socket or tie, easing to its ordinary stiffness `squareReach` out,
            // so it arrives square and bends progressively.
            let x = min(min(along[at], length - along[at]) / squareReach, 1)
            let stiffness = 1 + endStiffening * (1 - x * x * (3 - 2 * x))
            total += stiffness * turn * turn / max(around, 0.5)
        }
        return total
    }

    /// A cubic Bézier between each pair of waypoints, leaving and arriving along their tangents. The wire is rigid
    /// where it meets a socket or tie and loosens with distance from it, so it arrives square however it swings.
    private static func route(through waypoints: [Waypoint]) -> Route {
        var points: [CGPoint] = [], isTieSlot: [Bool] = []
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            let handles = easiestCurve(from: a, to: b)
            let control1 = a.point + a.tangent * handles.start
            let control2 = b.point - b.tangent * handles.end
            for sample in 0..<samplesPerSegment {
                // Closer together near the ends, where the wire is held square and bends most; farther apart mid-span.
                let even = CGFloat(sample) / CGFloat(samplesPerSegment)
                let t = (1 - cos(.pi * even)) / 2, u = 1 - t
                let near = a.point * (u * u * u) + control1 * (3 * u * u * t)
                let far = control2 * (3 * u * t * t) + b.point * (t * t * t)
                points.append(near + far)
                isTieSlot.append(sample == 0 && a.isTie)
            }
        }
        points.append(waypoints[waypoints.count - 1].point)
        isTieSlot.append(false)

        // How far along the wire each point is from the nearest socket or tie.
        let isAnchor = points.indices.map { $0 == 0 || $0 == points.count - 1 || isTieSlot[$0] }
        var distance = points.indices.map { isAnchor[$0] ? 0 : CGFloat.infinity }
        for i in points.indices.dropFirst() where !isAnchor[i] {
            distance[i] = distance[i - 1] + points[i].distance(to: points[i - 1])
        }
        for i in points.indices.dropLast().reversed() where !isAnchor[i] {
            distance[i] = min(distance[i], distance[i + 1] + points[i].distance(to: points[i + 1]))
        }
        // Held completely at the anchor, easing (smoothstep) to free at `squareReach`.
        let flexibility = distance.map { d -> Double in
            let x = Double(min(d / squareReach, 1))
            return x * x * (3 - 2 * x)
        }
        let stiffness = points.indices.map { i -> Double in
            if i == 0 || i == points.count - 1 { return .infinity }
            return isTieSlot[i] ? Spring.tie : Spring.loose + Spring.rigid * (1 - flexibility[i])
        }
        return Route(points: points, stiffness: stiffness, flexibility: flexibility, anchorDistance: distance, isTieSlot: isTieSlot)
    }
}

extension Routing.Route {
    /// Bends the wire around `obstacles` as if each table repelled it: a push that's strongest at the table and fades
    /// smoothly to nothing at `Routing.avoidanceReach`, against the wire's wish to keep its own shape. It's the wire's
    /// displacement that's smoothed, not its points, so it bulges around tables in easy curves and relaxes back to its
    /// natural route where nothing pushes. The finished displacement is then faded out toward each socket and tie by
    /// `flexibility` (squared), which starts flat, so the wire still leaves them square.
    // ponytail: wires × points × tables × passes per redraw; spatial bucketing if schemas reach hundreds of tables.
    /// - Parameter own: The wire's own tables. They don't push it, but it's lifted out from under them.
    mutating func avoid(_ obstacles: [CGRect], staying own: [CGRect] = []) {
        let reach = Routing.avoidanceReach
        let xs = points.map(\.x), ys = points.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let obstacles = obstacles.filter { $0.insetBy(dx: -reach, dy: -reach).intersects(bounds) }
        let own = own.filter { $0.intersects(bounds) }
        guard !obstacles.isEmpty || !own.isEmpty else { return }

        let base = points
        var offset = [CGPoint](repeating: .zero, count: points.count)

        // A stretch under a table goes around it on one side (the nearer, across its way of travel), not through.
        for rect in obstacles + own {
            var index = 1
            while index < points.count - 1 {
                guard flexibility[index] > 0, rect.contains(base[index]) else { index += 1; continue }
                // A run stops at a tie: the stretch on each side picks its own way around.
                var end = index
                while end + 1 < points.count - 1, flexibility[end + 1] > 0, rect.contains(base[end + 1]) { end += 1 }
                let travel = base[end + 1] - base[index - 1]
                let middle = (index...end).map { base[$0] }.reduce(.zero, +) / CGFloat(end - index + 1)
                for i in index...end {
                    let target = abs(travel.x) >= abs(travel.y)
                        ? CGPoint(x: base[i].x, y: middle.y < rect.midY ? rect.minY - reach / 2 : rect.maxY + reach / 2)
                        : CGPoint(x: middle.x < rect.midX ? rect.minX - reach / 2 : rect.maxX + reach / 2, y: base[i].y)
                    offset[i] = target - base[i]
                }
                index = end + 1
            }
        }

        for _ in 0..<Routing.avoidancePasses {
            // Push: away from the nearest spot on each table, fading as (1 - d/reach)², which eases to nothing.
            for i in points.indices where flexibility[i] > 0 {
                let point = base[i] + offset[i]
                for rect in obstacles {
                    let nearest = CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
                    let away = point - nearest, distance = away.length
                    guard distance < reach else { continue }
                    // Inside, push out the nearer way across the wire.
                    let direction = away.normalized ?? (point.y < rect.midY ? CGPoint(x: 0, y: -1) : CGPoint(x: 0, y: 1))
                    let falloff = 1 - distance / reach
                    offset[i] += direction * (reach * falloff * falloff * 0.25)
                }
            }
            // Tension: smooth the displacement along the wire; sockets and ties stay put.
            let before = offset
            for i in points.indices.dropFirst().dropLast() where flexibility[i] > 0 {
                offset[i] = before[i] + ((before[i - 1] + before[i + 1]) / 2 - before[i]) * 0.5
            }
        }
        // A few more rounds of tension alone, to round off any corner left where two tables' pushes meet.
        for _ in 0..<Routing.avoidanceSettlingPasses {
            let before = offset
            for i in points.indices.dropFirst().dropLast() where flexibility[i] > 0 {
                offset[i] = before[i] + ((before[i - 1] + before[i + 1]) / 2 - before[i]) * 0.5
            }
        }
        // Faded in from each socket and tie (smoothstep, squared, so the wire leaves square), over at least
        // `squareReach` and longer for a bigger push: fading a big push in quickly would itself bend the wire hard.
        for i in points.indices {
            let reach = max(Routing.squareReach, offset[i].length * Routing.pushRunway)
            let x = min(anchorDistance[i] / reach, 1), hold = x * x * (3 - 2 * x)
            points[i] = base[i] + offset[i] * (hold * hold)
        }
    }
}

