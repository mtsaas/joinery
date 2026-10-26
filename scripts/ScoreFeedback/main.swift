import Foundation

// Replays exported routing feedback against the current routing and reports how far each case's wire lands from the
// line it should follow, so a change to the routing can be measured against every correction at once.
// Usage: scripts/score-feedback.sh routing-feedback.json

struct Export: Decodable { var cases: [Case] }
struct Case: Decodable {
    var foreignKey: String
    var note: String
    var modelName: String
    var routingVersion: String
    var avoidingTables: Bool
    var model: DataModel
    var relationship: UUID
    var routed: [CGPoint]
    var expected: [CGPoint]

    /// As saved, from when data models were called schemas.
    enum CodingKeys: String, CodingKey {
        case foreignKey, note, routingVersion, avoidingTables, relationship, routed, expected
        case modelName = "schemaName", model = "schema"
    }
}

/// `points` redistributed evenly along their length.
func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
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

/// Mean and worst distance between two lines, compared point for point along their lengths.
func gap(_ a: [CGPoint], _ b: [CGPoint]) -> (mean: Double, worst: Double) {
    let a = resample(a, count: 96), b = resample(b, count: 96)
    let distances = zip(a, b).map { Double($0.distance(to: $1)) }
    return (distances.reduce(0, +) / Double(distances.count), distances.max() ?? 0)
}

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let export = try decoder.decode(Export.self, from: Data(contentsOf: URL(filePath: CommandLine.arguments[1])))
print("routing \(Routing.version); \(export.cases.count) cases\n")
var totals = (then: 0.0, now: 0.0)
for item in export.cases {
    guard let now = Routing(model: item.model, avoidingTables: item.avoidingTables).routes[item.relationship]?.points else {
        print("  \(item.foreignKey): no longer routed"); continue
    }
    let then = gap(item.routed, item.expected), current = gap(now, item.expected)
    totals.then += then.mean
    totals.now += current.mean
    print(String(format: "  %@ (%@, %@): when given %.1f pt off (worst %.0f), now %.1f pt (worst %.0f)%@",
                 item.foreignKey, item.modelName, item.routingVersion, then.mean, then.worst, current.mean, current.worst,
                 item.note.isEmpty ? "" : " — \(item.note)"))
}
let count = Double(max(export.cases.count, 1))
print(String(format: "\nmean distance from the expected lines: %.1f pt when given, %.1f pt now", totals.then / count, totals.now / count))
