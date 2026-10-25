import CoreGraphics
import Foundation

/// Spring constants for wires, per second squared. Tuned by eye against the zip-tie reference: wires should overshoot
/// once or twice and settle in about a second.
enum Spring {
    static let ends = 520.0
    static let middle = 120.0
    static let tie = 900.0
    /// How much each point follows its neighbors' displacement, which sends a wobble travelling along the wire.
    static let tension = 700.0
    /// Fraction of critical damping.
    static let damping = 0.32
    static let timeStep = 1.0 / 240
}

/// The wires as drawn: chains of points, each sprung toward its place on the wire's route. When a table moves, the
/// sockets move with it and the rest of the wire catches up.
final class WireSimulation {
    struct Wire {
        var points: [CGPoint]
        var velocities: [CGPoint]

        init(points: [CGPoint]) {
            self.points = points
            velocities = Array(repeating: .zero, count: points.count)
        }
    }

    private(set) var wires: [Relationship.ID: Wire] = [:]
    private var lastTime: TimeInterval?
    private var unsimulatedTime = 0.0

    /// Moves every wire toward its route as of `time`, in seconds. New wires start at rest on their routes.
    /// - Returns: Whether any wire is still moving.
    func advance(toward routes: [Relationship.ID: Routing.Route], to time: TimeInterval) -> Bool {
        // A long gap means the canvas was idle; don't try to catch up on it.
        unsimulatedTime += min(max(time - (lastTime ?? time), 0), 1.0 / 30)
        lastTime = time
        let steps = Int(unsimulatedTime / Spring.timeStep)
        unsimulatedTime -= Double(steps) * Spring.timeStep

        wires = wires.filter { routes[$0.key] != nil }
        var isMoving = false
        for (id, route) in routes {
            guard var wire = wires[id] else {
                wires[id] = Wire(points: route.points)
                continue
            }
            if wire.points.count != route.points.count {
                // Tied or untied: same shape, new number of points; it then springs onto its new route.
                wire = Wire(points: Self.resample(wire.points, count: route.points.count))
            }
            for _ in 0..<steps { wire.step(toward: route) }
            isMoving = !wire.settle(on: route) || isMoving
            wires[id] = wire
        }
        return isMoving
    }

    /// The wire within `tolerance` of `point`, nearest first.
    func wire(near point: CGPoint, within tolerance: CGFloat) -> Relationship.ID? {
        var best: (id: Relationship.ID, distance: CGFloat)?
        for (id, wire) in wires {
            for (a, b) in zip(wire.points, wire.points.dropFirst()) {
                let d = distance(from: point, toSegment: a, b)
                if d <= tolerance, d < best?.distance ?? .infinity { best = (id, d) }
            }
        }
        return best?.id
    }

    struct Crossing {
        var relationship: Relationship.ID
        var point: CGPoint
        /// The way the wire runs there, a unit vector.
        var tangent: CGPoint
        /// Which of the wire's segments between sockets and ties it's on, counting from the foreign key's end.
        var segment: Int
    }

    /// Where the line from `start` to `end` first crosses each wire.
    func crossings(from start: CGPoint, to end: CGPoint) -> [Crossing] {
        wires.compactMap { id, wire in
            for (index, (a, b)) in zip(wire.points, wire.points.dropFirst()).enumerated() {
                guard let t = crossing(a, b, start, end), let tangent = (b - a).normalized else { continue }
                return Crossing(relationship: id, point: a + (b - a) * t, tangent: tangent,
                                segment: index / Routing.samplesPerSegment)
            }
            return nil
        }
    }

    /// `points` redistributed evenly along their length.
    static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count > 1, count > 1 else { return Array(repeating: points.first ?? .zero, count: count) }
        var lengths = [0.0]
        for (a, b) in zip(points, points.dropFirst()) { lengths.append(lengths[lengths.count - 1] + a.distance(to: b)) }
        let total = lengths[lengths.count - 1]
        var result: [CGPoint] = [], segment = 0
        for index in 0..<count {
            let target = total * CGFloat(index) / CGFloat(count - 1)
            while segment < points.count - 2, lengths[segment + 1] < target { segment += 1 }
            let span = lengths[segment + 1] - lengths[segment]
            let t = span > 0 ? (target - lengths[segment]) / span : 0
            result.append(points[segment] + (points[segment + 1] - points[segment]) * t)
        }
        return result
    }
}

private extension WireSimulation.Wire {
    mutating func step(toward route: Routing.Route) {
        let dt = Spring.timeStep
        for index in points.indices where route.stiffness[index].isInfinite {
            points[index] = route.points[index]
            velocities[index] = .zero
        }
        for index in points.indices.dropFirst().dropLast() where route.stiffness[index].isFinite {
            let k = route.stiffness[index]
            let offset = points[index] - route.points[index]
            let neighbors = (points[index - 1] - route.points[index - 1] + points[index + 1] - route.points[index + 1]) / 2
            let acceleration = offset * -k - velocities[index] * (2 * Spring.damping * k.squareRoot())
                + (neighbors - offset) * Spring.tension
            velocities[index] += acceleration * dt
        }
        for index in points.indices { points[index] += velocities[index] * dt }
    }

    /// Snaps to the route once close enough that the rest of the motion wouldn't show.
    /// - Returns: Whether it's at rest.
    mutating func settle(on route: Routing.Route) -> Bool {
        for index in points.indices
        where points[index].distance(to: route.points[index]) > 0.05 || velocities[index].length > 0.5 {
            return false
        }
        self = Self(points: route.points)
        return true
    }
}
