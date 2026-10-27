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
        /// How far across from its middle each cable runs through it: side by side, each as wide as it's drawn (a bus
        /// twice a wire), the same gap between each.
        private(set) var offsets: [CGFloat]
        /// From its middle to either end.
        let halfLength: CGFloat

        /// `widths` are its cables' as drawn; by default, all wires.
        init(center: CGPoint, direction: CGPoint, relationships: [Relationship.ID], widths: [CGFloat]? = nil) {
            (self.center, self.direction, self.relationships) = (center, direction, relationships)
            let widths = widths ?? relationships.map { _ in Metrics.wireWidth }
            let gap = Metrics.tieSpacing - Metrics.wireWidth
            let span = widths.reduce(0, +) + gap * CGFloat(max(widths.count - 1, 0))
            var edge = -span / 2
            offsets = widths.map { width in
                defer { edge += width + gap }
                return edge + width / 2
            }
            // As far as a tie of wires alone would reach past its outermost, from wherever that is.
            halfLength = max(span / 2 - Metrics.wireWidth / 2, 0) + Metrics.tieOverhang
        }

        func slot(_ index: Int) -> CGPoint {
            center + direction.perpendicular * (offsets.indices.contains(index) ? offsets[index] : 0)
        }
    }

    private struct Waypoint: Equatable {
        var point: CGPoint
        /// The direction the wire runs through this point.
        var tangent: CGPoint
        var isTie = false
    }

    struct Socket: Hashable {
        var column: Column.ID
        var side: Side
    }

    /// Each wire's, and each group port's bus, by the port's ID.
    private(set) var routes: [Relationship.ID: Route] = [:]
    /// Where each group's ports are, and the wires each bundles.
    private(set) var ports: [GroupPort.ID: DataModel.PortPlacement] = [:]
    private(set) var ties: [ZipTie.ID: Tie] = [:]
    /// The sockets each wire is plugged into: its foreign key's, then the referenced column's. A port's bus, by the
    /// port's ID, plugs into its column's, at both ends.
    private(set) var sockets: [Relationship.ID: (from: Socket, to: Socket)] = [:]

    /// What each wire's route was worked out from: where it runs through, its curve before avoiding anything, and the
    /// tables that pushed it. A routing made from this one reuses every route whose inputs are the same, so dragging
    /// a table only reroutes its own wires and those near it.
    private struct Inputs {
        var waypoints: [Waypoint]
        var curve: Route
        var bounds: CGRect
        var obstacles: [CGRect]
        var own: [CGRect]
    }

    private var inputs: [Relationship.ID: Inputs] = [:]
    /// Where each table was, to tell what's moved since.
    private var frames: [Table.ID: CGRect] = [:]
    private var isAvoiding = false

    #if DEBUG
    /// How many routings have been worked out, to check redraws aren't redoing it needlessly.
    nonisolated(unsafe) static var built = 0
    #endif

    /// - Parameters:
    ///   - tableOffsets: How far tables being dragged have moved, not yet saved to `model`.
    ///   - tieOffsets: The same for zip ties.
    ///   - avoidingTables: Whether wires bend around tables in their way rather than running under them.
    ///   - previous: A routing to reuse unchanged routes from.
    init(model: DataModel, tableOffsets: [Table.ID: CGPoint] = [:], tieOffsets: [ZipTie.ID: CGPoint] = [:],
         avoidingTables: Bool = false, reusing previous: Routing? = nil) {
        #if DEBUG
        Self.built += 1
        #endif
        var rows: [Column.ID: (table: Table.ID, row: Int)] = [:]
        for table in model.tables {
            frames[table.id] = Metrics.frame(of: table).offsetBy(dx: tableOffsets[table.id]?.x ?? 0, dy: tableOffsets[table.id]?.y ?? 0)
            for (row, column) in table.columns.enumerated() { rows[column.id] = (table.id, row) }
        }
        ports = model.portPlacements(offsets: tableOffsets)
        // The wires bundled through a port run to it instead of to its column.
        var bussed: [Relationship.ID: DataModel.PortPlacement] = [:]
        for port in ports.values { for wire in port.wires { bussed[wire] = port } }
        let tiePositions = Dictionary(model.zipTies.map { ($0.id, $0.position + (tieOffsets[$0.id] ?? .zero)) },
                                      uniquingKeysWith: { first, _ in first })

        // Each wire leaves and enters on the side of its tables that faces where it's going.
        var ends: [Relationship.ID: (start: Waypoint, end: Waypoint)] = [:]
        for relationship in model.relationships {
            guard let from = rows[relationship.from], let to = rows[relationship.to],
                  let fromFrame = frames[from.table], let toFrame = frames[to.table] else { continue }
            let tied = relationship.zipTies.compactMap { tiePositions[$0] }
            let startSide: Side, endSide: Side
            let port = bussed[relationship.id]
            if let port {
                // The end in the group faces the port, or its first tie; the other faces the port too, for its bus.
                let toPort = port.column == relationship.to
                let inside = toPort ? fromFrame : toFrame, outside = toPort ? toFrame : fromFrame
                let toward = (toPort ? tied.first : tied.last) ?? port.inside
                let insideSide: Side = toward.x < inside.midX ? .leading : .trailing
                let outsideSide: Side = port.outside.x < outside.midX ? .leading : .trailing
                (startSide, endSide) = toPort ? (insideSide, outsideSide) : (outsideSide, insideSide)
            } else if let first = tied.first, let last = tied.last {
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
            // Into the port's inside socket, square to the group's edge, heading out.
            if let port {
                if port.column == relationship.to {
                    ends[relationship.id]?.end = Waypoint(point: port.inside, tangent: port.normal)
                } else {
                    ends[relationship.id]?.start = Waypoint(point: port.inside, tangent: -port.normal)
                }
            }
        }
        // A port's wires plug in side by side across its inside end, in the order they come from across it, so none
        // cross on the way in.
        let referenced = Dictionary(model.relationships.map { ($0.id, $0.to) }, uniquingKeysWith: { first, _ in first })
        for port in ports.values where port.wires.count > 1 {
            let across = port.normal.perpendicular
            // Where each comes from, across the port: its far end's place along it.
            let from = Dictionary(uniqueKeysWithValues: port.wires.map { wire -> (Relationship.ID, CGFloat) in
                guard let ends = ends[wire] else { return (wire, 0) }
                return (wire, (port.column == referenced[wire] ? ends.start : ends.end).point.dot(across))
            })
            let ordered = port.wires.sorted { a, b in (from[a] ?? 0, a.uuidString) < (from[b] ?? 0, b.uuidString) }
            for (index, wire) in ordered.enumerated() {
                let slot = port.insideSlot(index, of: ordered.count)
                if ends[wire]?.end.point == port.inside { ends[wire]?.end.point = slot } else { ends[wire]?.start.point = slot }
            }
        }
        // Each port's bus, a cable like any wire, through its own ties: out of the port's outside socket, square to the
        // edge, into its column's socket on the side facing it (or its last tie). There even before any wire runs
        // through the port, as a socket for the group's tables to plug into.
        let busTies = Dictionary(model.groups.flatMap(\.ports).map { ($0.id, $0.zipTies) }, uniquingKeysWith: { first, _ in first })
        var buses: [(id: GroupPort.ID, column: Column.ID)] = []
        for (id, port) in ports.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let column = port.column, let row = rows[column], let frame = frames[row.table] else { continue }
            let toward = busTies[id]?.last.flatMap { tiePositions[$0] } ?? port.outside
            let side: Side = toward.x < frame.midX ? .leading : .trailing
            let socket = Socket(column: column, side: side)
            sockets[id] = (socket, socket)
            ends[id] = (Waypoint(point: port.outside, tangent: port.normal),
                        Waypoint(point: Metrics.socket(row: row.row, side: side, in: frame), tangent: -side.outward))
            buses.append((id, column))
        }
        // The ties on every cable, wire or bus.
        var cableTies = Dictionary(model.relationships.map { ($0.id, $0.zipTies) }, uniquingKeysWith: { first, _ in first })
        cableTies.merge(busTies) { first, _ in first }

        // The points a cable runs between on either side of its `index`th tie. Sockets come with the way the cable
        // runs through them; neighboring ties don't have one yet.
        func neighbors(of cable: UUID, at index: Int) -> (previous: Waypoint, next: Waypoint)? {
            guard let (start, end) = ends[cable], let ties = cableTies[cable] else { return nil }
            let previous = index == 0 ? start : tiePositions[ties[index - 1]].map { Waypoint(point: $0, tangent: .zero) } ?? start
            let next = index == ties.count - 1 ? end : tiePositions[ties[index + 1]].map { Waypoint(point: $0, tangent: .zero) } ?? end
            return (previous, next)
        }

        // The way a wire runs through a tie at `center`: straight from its neighbors when it's far from them, but
        // close to a socket, the way it leaves that socket, so it doesn't have to turn hard in the gap between.
        func flow(of cable: UUID, at index: Int, through center: CGPoint) -> CGPoint? {
            guard let (previous, next) = neighbors(of: cable, at: index),
                  let chord = (next.point - previous.point).normalized else { return nil }
            let before = previous.point.distance(to: center), after = center.distance(to: next.point)
            let near = before < after ? previous : next
            let pull = max(0, 1 - min(before, after) / Self.socketReach) * (near.tangent == .zero ? 0 : 1)
            return (chord * (1 - pull) + near.tangent * pull).normalized ?? chord
        }

        // A tie turns to follow its wires: along the average of the way they run through it.
        for tie in model.zipTies {
            guard let center = tiePositions[tie.id] else { continue }
            var sum = CGPoint.zero
            for cable in tie.relationships {
                guard let index = cableTies[cable]?.firstIndex(of: tie.id),
                      let way = flow(of: cable, at: index, through: center) else { continue }
                sum += way.dot(tie.direction) < 0 ? -way : way
            }
            ties[tie.id] = Tie(center: center, direction: tie.heldDirection ?? sum.normalized ?? tie.direction,
                               relationships: tie.relationships,
                               widths: tie.relationships.map { ports[$0] == nil ? Metrics.wireWidth : Metrics.busWidth })
        }

        // In the model's order, so the obstacles a wire meets are listed the same way each time.
        let tableFrames = model.tables.compactMap { frames[$0.id] }
        isAvoiding = avoidingTables
        // Where tables have moved from and to since `previous`: only wires near those can meet different tables. Nil if
        // there's nothing to compare with, or it didn't avoid tables, so every wire looks again.
        let moved = previous.flatMap { avoidingTables && $0.isAvoiding ? $0 : nil }.map { previous in
            frames.flatMap { id, frame in previous.frames[id] == frame ? [] : [frame] + [previous.frames[id]].compactMap { $0 } }
                + previous.frames.compactMap { id, frame in frames[id] == nil ? frame : nil }
        }
        let margin = Self.avoidanceReach * 2
        // Close enough to push: within reach of the wire itself, not just of the box around it, which for a long
        // diagonal wire covers half the model. Twice the reach, for where pushes and lifts carry it.
        func isNear(_ frame: CGRect, _ curve: Route, within bounds: CGRect) -> Bool {
            frame.intersects(bounds.insetBy(dx: -margin, dy: -margin)) && curve.points.contains { frame.distance(to: $0) < margin }
        }
        // Wires to bend around tables, worked out together after the rest.
        var toAvoid: [(id: Relationship.ID, curve: Route, obstacles: [CGRect], own: [CGRect])] = []
        // Works out a wire's curve (or a bus's, by its port's ID) between `waypoints`, joining `columns`' tables.
        func plan(_ id: Relationship.ID, through waypoints: [Waypoint], joining columns: [Column.ID]) {
            let before = previous?.inputs[id]
            let isSameCurve = before?.waypoints == waypoints
            let curve = isSameCurve ? before!.curve : Self.route(through: waypoints)
            let bounds = isSameCurve ? before!.bounds : curve.bounds
            var obstacles: [CGRect] = [], own: [CGRect] = []
            if avoidingTables {
                if isSameCurve, let before, let moved, !moved.contains(where: { isNear($0, curve, within: bounds) }) {
                    // Nothing near it moved, so it meets the same tables.
                    (obstacles, own) = (before.obstacles, before.own)
                } else {
                    // A wire isn't pushed off the tables it plugs into, only kept from running under them.
                    let ends = columns.compactMap { rows[$0].flatMap { frames[$0.table] } }
                    obstacles = tableFrames.filter { !ends.contains($0) && isNear($0, curve, within: bounds) }
                    own = ends.filter { $0.intersects(bounds) }
                }
            }
            inputs[id] = Inputs(waypoints: waypoints, curve: curve, bounds: bounds, obstacles: obstacles, own: own)
            if let before, before.waypoints == waypoints, before.obstacles == obstacles, before.own == own,
               let route = previous?.routes[id] {
                routes[id] = route
            } else if obstacles.isEmpty && own.isEmpty {
                routes[id] = curve
            } else {
                toAvoid.append((id, curve, obstacles, own))
            }
        }
        // A cable's waypoints: its start, each tie it runs through, its end.
        func waypoints(of cable: UUID) -> [Waypoint]? {
            guard let (start, end) = ends[cable] else { return nil }
            var waypoints = [start]
            for (index, id) in (cableTies[cable] ?? []).enumerated() {
                guard let tie = ties[id], let slot = tie.relationships.firstIndex(of: cable),
                      let way = flow(of: cable, at: index, through: tie.center) else { continue }
                let tangent = way.dot(tie.direction) < 0 ? -tie.direction : tie.direction
                waypoints.append(Waypoint(point: tie.slot(slot), tangent: tangent, isTie: true))
            }
            waypoints.append(end)
            return waypoints
        }
        for relationship in model.relationships {
            guard let waypoints = waypoints(of: relationship.id) else { continue }
            // A bundled wire joins only its own table: the port stands in for the other.
            let port = bussed[relationship.id]
            plan(relationship.id, through: waypoints,
                 joining: port.map { [$0.column == relationship.to ? relationship.from : relationship.to] } ?? [relationship.from, relationship.to])
        }
        for bus in buses {
            if let waypoints = waypoints(of: bus.id) { plan(bus.id, through: waypoints, joining: [bus.column]) }
        }

        // Each wire bends on its own, so they're shared among the cores: dragging a table through a crowd of wires,
        // turning avoidance on, or opening a big model reroutes many at once.
        var avoided = [Route?](repeating: nil, count: toAvoid.count)
        avoided.withUnsafeMutableBufferPointer { results in
            let results = results
            let work = { (index: Int) in
                var route = toAvoid[index].curve
                route.avoid(toAvoid[index].obstacles, staying: toAvoid[index].own)
                results[index] = route
            }
            // A few aren't worth the handoff.
            if toAvoid.count < 4 { (0..<toAvoid.count).forEach(work) } else { DispatchQueue.concurrentPerform(iterations: toAvoid.count, execute: work) }
        }
        for (wire, route) in zip(toAvoid, avoided) { routes[wire.id] = route }
    }

    /// How far out of a socket or tie the wire is held: completely at the anchor, easing to not at all here. It's
    /// stiffer there while things move, and avoidance can't push it, so it leaves square and bends progressively.
    static let squareReach: CGFloat = 72
    /// Names this version of the routing in saved feedback, with `parameters`. Change it when the method changes, so
    /// feedback can be told apart by what produced the line it corrects.
    static let version = "2026-10-26 fixed handles, fenced"

    /// The tuning constants, for saved feedback.
    static var parameters: [String: Double] {
        ["samplesPerSegment": Double(samplesPerSegment), "squareReach": squareReach, "avoidanceReach": avoidanceReach,
         "avoidancePasses": Double(avoidancePasses), "avoidanceSettlingPasses": Double(avoidanceSettlingPasses),
         "pushRunway": pushRunway, "socketReach": socketReach, "avoidanceClearance": avoidanceClearance,
         "fencePasses": Double(fencePasses)]
    }

    /// How far a table's push on wires reaches; it fades smoothly to nothing there.
    static let avoidanceReach: CGFloat = 64
    static let avoidancePasses = 40
    static let avoidanceSettlingPasses = 12
    /// Points of wire, out from a socket or tie, over which each point of avoidance push is faded in.
    static let pushRunway: CGFloat = 2.5
    /// How far a wire keeps from a table it goes around, at the least.
    static let avoidanceClearance: CGFloat = 12
    /// Rounds of keeping wires out from under tables and relaxing them, after the push.
    static let fencePasses = 12

    /// Tables closer than this side by side are treated as stacked.
    private static let sideGap: CGFloat = 24
    /// Within this of a socket, a tie turns toward the socket's own direction; at the socket, all the way.
    private static let socketReach: CGFloat = 160

    /// A cubic Bézier between each pair of waypoints, leaving and arriving along their tangents. The wire is rigid
    /// where it meets a socket or tie and loosens with distance from it, so it arrives square however it swings.
    private static func route(through waypoints: [Waypoint]) -> Route {
        var points: [CGPoint] = [], isTieSlot: [Bool] = []
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            // The handles set how far the wire stays square: it leaves along them and turns over about their length.
            // Never longer than half the gap, or a short hop (a tie near a socket) overshoots and hooks.
            let gap = a.point.distance(to: b.point)
            let reach = min(max(gap * 0.4, min(Routing.squareReach / 2, gap / 2)), Routing.squareReach * 1.25)
            // Reach further when the other end is behind, so the wire swings around instead of folding back.
            let control1 = a.point + a.tangent * (reach + max(0, (b.point - a.point).dot(-a.tangent)) / 2)
            let control2 = b.point - b.tangent * (reach + max(0, (a.point - b.point).dot(b.tangent)) / 2)
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
    var bounds: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Bends the wire around `obstacles` as if each table repelled it: a push that's strongest at the table and fades
    /// smoothly to nothing at `Routing.avoidanceReach`, against the wire's wish to keep its own shape. It's the wire's
    /// displacement that's smoothed, not its points, so it bulges around tables in easy curves and relaxes back to its
    /// natural route where nothing pushes. The finished displacement is then faded out toward each socket and tie by
    /// `flexibility` (squared), which starts flat, so the wire still leaves them square.
    /// - Parameters:
    ///   - obstacles: Tables near enough to push it, within `Routing.avoidanceReach` of `bounds`.
    ///   - own: The wire's own tables, where they overlap it. They don't push it, but it's lifted out from under them.
    mutating func avoid(_ obstacles: [CGRect], staying own: [CGRect] = []) {
        let reach = Routing.avoidanceReach
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
        var hold = [CGFloat](repeating: 0, count: points.count)
        for i in points.indices {
            let reach = max(Routing.squareReach, offset[i].length * Routing.pushRunway)
            let x = min(anchorDistance[i] / reach, 1), smooth = x * x * (3 - 2 * x)
            hold[i] = smooth * smooth
            points[i] = base[i] + offset[i] * hold[i]
        }

        // Last, the field gives way to a rule: no wire runs under a table. Where the fade-in near a socket (or the
        // wire's own tension) has left it under one, it's put out at the table's nearest edge, a little clear and round
        // the corners, and the wire relaxed between, a few times over: it stretches to wrap the table rather than
        // cutting under it. The relaxing is held near sockets and ties as the push was, so they're still left square.
        let clearance = Routing.avoidanceClearance
        let fences = obstacles.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        let isFree = points.indices.map { $0 > 0 && $0 < points.count - 1 && !isTieSlot[$0] }
        func fenceOut() {
            for i in points.indices where isFree[i] {
                for fence in fences { points[i] = fence.pushingOut(points[i], cornerRadius: clearance + Metrics.cornerRadius) }
                // Its own tables only so far as not to run under them, away from the socket it leaves.
                if anchorDistance[i] > clearance { for rect in own { points[i] = rect.pushingOut(points[i], cornerRadius: Metrics.cornerRadius) } }
            }
            // The stretches between, too, where points are far apart: one cutting a corner moves out, both ends.
            for i in points.indices.dropLast() where isFree[i] || isFree[i + 1] {
                let middle = (points[i] + points[i + 1]) / 2
                for fence in fences {
                    let out = fence.pushingOut(middle, cornerRadius: clearance + Metrics.cornerRadius) - middle
                    guard out != .zero else { continue }
                    if isFree[i] { points[i] += out }
                    if isFree[i + 1] { points[i + 1] += out }
                }
            }
        }
        for _ in 0..<Routing.fencePasses {
            fenceOut()
            let before = points
            for i in points.indices.dropFirst().dropLast() where !isTieSlot[i] {
                points[i] = before[i] + ((before[i - 1] + before[i + 1]) / 2 - before[i]) * (0.5 * hold[i])
            }
        }
        fenceOut()
    }
}

