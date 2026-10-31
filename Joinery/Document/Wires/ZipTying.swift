#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

extension DataModel {
    /// Ties together every wire the line from `start` to `end` crosses, where it crosses them, if there are at least
    /// two.
    @discardableResult
    mutating func zipTie(_ wires: WireSimulation, from start: CGPoint, to end: CGPoint) -> ZipTie.ID? {
        let crossings = wires.crossings(from: start, to: end)
        guard crossings.count >= 2 else { return nil }

        var sum = CGPoint.zero
        for crossing in crossings { sum += crossing.tangent.dot(crossings[0].tangent) < 0 ? -crossing.tangent : crossing.tangent }
        let direction = sum.normalized ?? crossings[0].tangent
        // Slot order follows where the wires already are, so none have to cross over to get into place.
        let ordered = crossings.sorted { $0.point.dot(direction.perpendicular) < $1.point.dot(direction.perpendicular) }
        let center = crossings.map(\.point).reduce(.zero, +) / CGFloat(crossings.count)

        let tie = ZipTie(position: center, direction: direction, relationships: ordered.map(\.relationship))
        zipTies.append(tie)
        for crossing in crossings {
            guard var ties = zipTies(onCable: crossing.relationship) else { continue }
            ties.insert(tie.id, at: min(crossing.segment, ties.count))
            setZipTies(onCable: crossing.relationship, ties)
        }
        return tie.id
    }
}
