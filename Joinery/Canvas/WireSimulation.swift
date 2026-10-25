import CoreGraphics
import Foundation

/// Spring constants for wires, per second squared. Wires should feel like a pressurized air hose: a short lag behind
/// a moving table, a few percent of overshoot, settled in about a third of a second (measured: 4%, 0.35 s for a
/// 60-point jump). Raise `damping` toward 1 for less overshoot, lower the stiffnesses for more lag.
enum Spring {
    /// Away from sockets and ties.
    static let loose = 1100.0
    /// Added at a socket or tie, fading over `rigidLength` points along the wire: what makes it arrive square.
    static let rigid = 9000.0
    static let rigidLength = 22.0
    static let tie = 3000.0
    /// How much each point follows its neighbors' displacement, which sends a wobble travelling along the wire.
    static let tension = 1500.0
    /// Fraction of critical damping.
    static let damping = 0.7
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
                // Tied or untied: keep the shape, with each new point starting where the wire is nearest to where that
                // point is headed. It then slides into place rather than whipping across the canvas.
                wire = Wire(points: route.points.map { Self.nearest(to: $0, on: wire.points) })
            }
            for _ in 0..<steps { wire.step(toward: route) }
            isMoving = !wire.settle(on: route) || isMoving
            wires[id] = wire
        }
        return isMoving
    }

    struct Hit {
        var relationship: Relationship.ID
        /// The nearest point on the wire.
        var point: CGPoint
        /// The way the wire runs there, a unit vector.
        var tangent: CGPoint
        /// Which of the wire's segments between sockets and ties it's on, counting from the foreign key's end.
        var segment: Int
    }

    /// The nearest wire within `tolerance` of `point`, and where on it.
    func hit(near point: CGPoint, within tolerance: CGFloat) -> Hit? {
        var best: (hit: Hit, distance: CGFloat)?
        for (id, wire) in wires {
            for (index, (a, b)) in zip(wire.points, wire.points.dropFirst()).enumerated() {
                let nearest = closest(to: point, onSegment: a, b), distance = nearest.distance(to: point)
                guard distance <= tolerance, distance < best?.distance ?? .infinity, let tangent = (b - a).normalized else { continue }
                best = (Hit(relationship: id, point: nearest, tangent: tangent, segment: index / Routing.samplesPerSegment), distance)
            }
        }
        return best?.hit
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

    /// The point on the polyline through `points` closest to `target`.
    static func nearest(to target: CGPoint, on points: [CGPoint]) -> CGPoint {
        guard var best = points.first else { return target }
        for (a, b) in zip(points, points.dropFirst()) {
            let candidate = closest(to: target, onSegment: a, b)
            if candidate.distance(to: target) < best.distance(to: target) { best = candidate }
        }
        return best
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
            var acceleration = offset * -k - velocities[index] * (2 * Spring.damping * k.squareRoot())
            // A tie slot moves only toward where the tie is, like a socket that can drift: the wires on either side
            // follow it, but nothing pulls it, so no force passes through the tie from one side to the other.
            if !route.isTieSlot[index] {
                let neighbors = (points[index - 1] - route.points[index - 1] + points[index + 1] - route.points[index + 1]) / 2
                acceleration += (neighbors - offset) * Spring.tension
            }
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
