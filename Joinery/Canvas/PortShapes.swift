import CoreGraphics

/// Each port's shape as drawn, easing toward its routing's, so it widens and narrows smoothly as wires come and go.
final class PortShapes {
    private var shapes: [GroupPort.ID: PortShape] = [:]
    private var time: Double?
    /// Whether any shape is still on its way.
    private(set) var isEasing = false

    subscript(id: GroupPort.ID) -> PortShape? { shapes[id] }

    /// Moves each shape toward its target, by how long it's been (a frame's worth, after a rest): most of the way in
    /// about a fifth of a second. A new port starts at its target, as it has its own way in.
    func advance(toward targets: [GroupPort.ID: PortShape], to now: Double) {
        let step = 1 - exp(-min(time.map { now - $0 } ?? 1.0 / 60, 0.1) * 18)
        time = now
        var isEasing = false
        shapes = targets.mapValues { $0 }.merging(shapes.filter { targets[$0.key] != nil }) { target, current in
            let next = current.mixed(with: target, by: step)
            let isClose = abs(next.length - target.length) < 0.25 && abs(next.inner - target.inner) < 0.25 && abs(next.outer - target.outer) < 0.25
            if !isClose { isEasing = true }
            return isClose ? target : next
        }
        self.isEasing = isEasing
        if !isEasing { time = nil }
    }
}
