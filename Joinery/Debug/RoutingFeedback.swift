#if DEBUG
import AppKit
import Foundation

/// A correction being drawn on one wire: a spline through the wire's sockets and ties, which stay put, and points
/// between them that are dragged to where the wire should run.
struct FeedbackEdit {
    var relationship: Relationship.ID
    /// Along the wire, from the foreign key's socket to the referenced one.
    var points: [CGPoint]
    /// Which of `points` are sockets and ties, which stay put.
    var isAnchor: [Bool]
    /// The way the wire leaves its first socket and enters its last, to shape the spline's ends.
    var startTangent: CGPoint
    var endTangent: CGPoint
    var note = ""

    static let samplesPerSpan = 16

    /// Starts from the wire's route: its anchors, and points spread along each stretch between them, about one per
    /// 90 points.
    init(relationship: Relationship.ID, route: Routing.Route) {
        self.relationship = relationship
        let anchors = route.points.indices.filter { $0 == 0 || $0 == route.points.count - 1 || route.isTieSlot[$0] }
        var points: [CGPoint] = [], isAnchor: [Bool] = []
        for (from, to) in zip(anchors, anchors.dropFirst()) {
            points.append(route.points[from])
            isAnchor.append(true)
            let stretch = Array(route.points[from...to])
            var along: [CGFloat] = [0]
            for (a, b) in zip(stretch, stretch.dropFirst()) { along.append(along[along.count - 1] + a.distance(to: b)) }
            let length = along[along.count - 1], count = min(max(Int(length / 90), 1), 6)
            for k in 1...count {
                let target = length * CGFloat(k) / CGFloat(count + 1)
                let i = (along.firstIndex { $0 >= target } ?? along.count - 1)
                let t = i > 0 && along[i] > along[i - 1] ? (target - along[i - 1]) / (along[i] - along[i - 1]) : 0
                points.append(i > 0 ? stretch[i - 1] + (stretch[i] - stretch[i - 1]) * t : stretch[0])
                isAnchor.append(false)
            }
        }
        points.append(route.points[route.points.count - 1])
        isAnchor.append(true)
        self.points = points
        self.isAnchor = isAnchor
        startTangent = (route.points[1] - route.points[0]).normalized ?? CGPoint(x: 1, y: 0)
        endTangent = (route.points[route.points.count - 1] - route.points[route.points.count - 2]).normalized ?? CGPoint(x: 1, y: 0)
    }

    /// The expected wire: a centripetal Catmull-Rom spline through `points`, leaving and entering the sockets along
    /// the wire's own directions.
    var expected: [CGPoint] {
        guard points.count >= 2 else { return points }
        let lead = points[0] - startTangent * points[0].distance(to: points[1])
        let tail = points[points.count - 1] + endTangent * points[points.count - 1].distance(to: points[points.count - 2])
        let all = [lead] + points + [tail]
        var result = [points[0]]
        for i in 1..<(all.count - 2) {
            for step in 1...Self.samplesPerSpan {
                result.append(Self.catmullRom(all[i - 1], all[i], all[i + 1], all[i + 2], CGFloat(step) / CGFloat(Self.samplesPerSpan)))
            }
        }
        return result
    }

    /// Where a point clicked on the expected wire goes in `points`, if it's within `tolerance` of it.
    func insertionIndex(near point: CGPoint, within tolerance: CGFloat) -> Int? {
        let curve = expected
        var best: (index: Int, distance: CGFloat)?
        for (k, (a, b)) in zip(curve, curve.dropFirst()).enumerated() {
            let d = distance(from: point, toSegment: a, b)
            if d <= tolerance, d < best?.distance ?? .infinity { best = (k / Self.samplesPerSpan + 1, d) }
        }
        return best?.index
    }

    private static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        // Centripetal (Barry and Goldman), which neither overshoots nor loops at uneven spacing.
        func knot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(sqrt(a.distance(to: b)), 0.001) }
        let t1 = knot(p0, p1), t2 = t1 + knot(p1, p2), t3 = t2 + knot(p2, p3)
        let u = t1 + (t2 - t1) * t
        let a1 = p0 * ((t1 - u) / t1) + p1 * (u / t1)
        let a2 = p1 * ((t2 - u) / (t2 - t1)) + p2 * ((u - t1) / (t2 - t1))
        let a3 = p2 * ((t3 - u) / (t3 - t2)) + p3 * ((u - t2) / (t3 - t2))
        let b1 = a1 * ((t2 - u) / t2) + a2 * (u / t2)
        let b2 = a2 * ((t3 - u) / (t3 - t1)) + a3 * ((u - t1) / (t3 - t1))
        return b1 * ((t2 - u) / (t2 - t1)) + b2 * ((u - t1) / (t2 - t1))
    }
}

/// One saved correction, with everything needed to replay it: the model as it was, which wire, how routing was set
/// up, what it drew, and what it should have drawn.
struct RoutingFeedbackCase: Codable {
    var id = UUID()
    var created = Date()
    var modelName: String
    var note: String
    var routingVersion: String
    var routingParameters: [String: Double]
    var avoidingTables: Bool
    var model: DataModel
    var relationship: Relationship.ID
    /// "orders.user_id → users.id", for reading.
    var foreignKey: String
    /// The route's resting line, which the simulation springs toward.
    var routed: [CGPoint]
    /// The corrected line, sampled along the spline.
    var expected: [CGPoint]
    /// The spline's points, sockets and ties included.
    var controlPoints: [CGPoint]

    /// As saved, from when data models were called schemas.
    enum CodingKeys: String, CodingKey {
        case id, created, note, routingVersion, routingParameters, avoidingTables, relationship, foreignKey, routed, expected
        case controlPoints
        case modelName = "schemaName", model = "schema"
    }
}

@MainActor
enum RoutingFeedback {
    /// Hidden inside the library, so it isn't listed as a collection.
    static var folder: URL { Library.shared.root.appending(path: ".routing-feedback", directoryHint: .isDirectory) }

    static func save(_ feedback: RoutingFeedbackCase) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: feedback.created).replacingOccurrences(of: ":", with: "-")
        try encoder.encode(feedback).write(to: folder.appending(path: "\(stamp).json"), options: .atomic)
    }

    static var count: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).count { $0.hasSuffix(".json") }
    }

    /// Writes every saved case into one file, chosen in a save panel that starts at this source tree.
    @MainActor
    static func export() {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cases = urls.compactMap { try? decoder.decode(RoutingFeedbackCase.self, from: Data(contentsOf: $0)) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "routing-feedback.json"
        // Debug builds know where their source is: the repository, three folders up from this file.
        panel.directoryURL = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        panel.message = "\(cases.count) routing corrections"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try encoder.encode(["cases": cases]).write(to: url, options: .atomic)
        } catch {
            Library.shared.failure = "Couldn't export the routing feedback: \(error.localizedDescription)"
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
#endif
