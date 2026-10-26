import CoreGraphics
import Foundation

/// Moves some tables, a step at a time, toward where fewer wires cross: gradient descent on how tangled things are.
///
/// Crossings come in whole numbers and have no slope to follow, so each crossing instead counts by how deep it is: how
/// far the nearer end of each wire is past the other's line. That slopes the same way however far from uncrossing,
/// where a smoothed count goes flat (measured with `scripts/untangle-bench.sh`: this leaves about a fifth of the
/// crossings in scrambled models; a smoothed count, two thirds). With it go a strong push apart where tables would
/// overlap, a gentle pull on wires much longer than usual, and a weak one back toward where each table started. Each step
/// moves each table down that slope, by Adam's rule, in steps that shrink as it goes. Nothing is random: the same model
/// and selection always come out the same. Tables stay within a little more than the area they first spanned: unbounded,
/// a few were flung far off to escape their crossings, spreading the selection over three times its area for 2% fewer
/// crossings. Every so often the arrangement, its overlaps pushed apart, has its real crossings counted, and the best is
/// the answer.
///
/// Wires are taken as straight lines from row to row, through the middle of each table, which is near enough to how
/// they're drawn to count crossings by.
struct Untangler {
    /// The knobs, chosen by measuring with `scripts/untangle-bench.sh`.
    struct Tuning {
        var steps = 360
        /// The first steps' size, in points; they shrink to 1.
        var startRate = 96.0
        /// What a crossing's depth weighs against overlap and the rest.
        var depthWeight = 0.03
        /// How much further than the moving tables first spanned they may go, as a fraction of that span each way.
        var room: CGFloat = 0.1
    }

    /// A wire's ends, each a table and a height on it.
    private struct Wire {
        var from: Int, fromY: CGFloat
        var to: Int, toY: CGFloat
    }

    /// Where every table started, in model order; only `moving` ones change.
    private let start: [CGPoint]
    private let sizes: [CGSize]
    private let moving: [Int]
    /// Where moving tables' frames have to stay: the area they first spanned, and a little more.
    private let area: CGRect
    private let wires: [Wire]
    /// For each table, its wires.
    private let wiresOf: [[Int]]

    private let tuning: Tuning
    private var positions: [CGPoint]
    /// Adam's running averages of each moving table's slope, and of its square.
    private var momentum: [CGPoint], scale: [CGPoint]
    private var iteration = 0

    /// How often the real crossings are counted.
    private static let checkEvery = 12
    private static let gap: CGFloat = 48
    /// How long a wire can be before it's pulled shorter.
    private static let reach: CGFloat = 420

    private(set) var startingCrossings = 0
    private(set) var best: (positions: [CGPoint], crossings: Int)
    let ids: [Table.ID]

    init(model: DataModel, moving ids: Set<Table.ID>, tuning: Tuning = Tuning()) {
        self.tuning = tuning
        self.ids = model.tables.map(\.id)
        start = model.tables.map(\.position)
        sizes = model.tables.map(Metrics.size)
        let index = Dictionary(uniqueKeysWithValues: model.tables.enumerated().map { ($1.id, $0) })
        moving = model.tables.indices.filter { ids.contains(model.tables[$0].id) }
        let (start, sizes) = (start, sizes)
        let span = moving.map { CGRect(origin: start[$0], size: sizes[$0]) }.reduce(CGRect.null) { $0.union($1) }
        area = span.insetBy(dx: -span.width * tuning.room, dy: -span.height * tuning.room)
        let locations = model.columnLocations
        wires = model.relationships.compactMap { relationship in
            guard let from = locations[relationship.from], let to = locations[relationship.to],
                  let a = index[from.table.id], let b = index[to.table.id], a != b else { return nil }
            let height = { (row: Int) in Metrics.headerHeight + (CGFloat(row) + 0.5) * Metrics.rowHeight }
            return Wire(from: a, fromY: height(from.row), to: b, toY: height(to.row))
        }
        var wiresOf = [[Int]](repeating: [], count: start.count)
        for (number, wire) in wires.enumerated() {
            wiresOf[wire.from].append(number)
            wiresOf[wire.to].append(number)
        }
        self.wiresOf = wiresOf
        positions = start
        momentum = moving.map { _ in .zero }
        scale = moving.map { _ in .zero }
        best = (start, 0)
        startingCrossings = Self.crossings(wires.indices.map { endpoints($0, in: start) })
        best = (start, startingCrossings)
    }

    var isDone: Bool { iteration >= tuning.steps }
    var progress: Double { Double(iteration) / Double(tuning.steps) }

    /// Where each moving table is now, as offsets from where it started.
    var offsets: [Table.ID: CGPoint] {
        Dictionary(uniqueKeysWithValues: moving.map { (ids[$0], positions[$0] - start[$0]) })
    }

    /// The best arrangement's offsets.
    var bestOffsets: [Table.ID: CGPoint] {
        Dictionary(uniqueKeysWithValues: moving.map { (ids[$0], best.positions[$0] - start[$0]) })
    }

    // MARK: Stepping

    mutating func step() {
        guard !isDone else { return }
        iteration += 1
        let rate = 1 + (tuning.startRate - 1) * (1 - progress)
        let (beta1, beta2, epsilon) = (0.9, 0.999, 1e-8)
        let slopes = moving.map { slope(of: $0) }
        for (number, table) in moving.enumerated() {
            let g = slopes[number]
            momentum[number] = momentum[number] * beta1 + g * (1 - beta1)
            scale[number] = CGPoint(x: scale[number].x * beta2 + g.x * g.x * (1 - beta2), y: scale[number].y * beta2 + g.y * g.y * (1 - beta2))
            let m = momentum[number] / (1 - pow(beta1, Double(iteration)))
            let v = scale[number] / (1 - pow(beta2, Double(iteration)))
            positions[table] -= CGPoint(x: rate * m.x / (v.x.squareRoot() + epsilon), y: rate * m.y / (v.y.squareRoot() + epsilon))
            positions[table] = kept(positions[table], size: sizes[table])
        }
        if iteration % Self.checkEvery == 0 || isDone { remember() }
    }

    /// Keeps this arrangement, its tables pushed apart where they overlap, if it crosses less than the best so far.
    private mutating func remember() {
        let candidate = separated(positions)
        guard !overlaps(candidate) else { return }
        let crossings = Self.crossings(wires.indices.map { endpoints($0, in: candidate) })
        if crossings < best.crossings { best = (candidate, crossings) }
    }

    /// A table's position, moved as little as it takes to keep it in `area`: the descent is projected onto it, so
    /// tables can't escape crossings by being flung far away.
    private func kept(_ position: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(position.x, area.minX), max(area.minX, area.maxX - size.width)),
                y: min(max(position.y, area.minY), max(area.minY, area.maxY - size.height)))
    }

    /// `positions` with moving tables pushed out of each other and of the rest, a gap apart: each pair that's too close
    /// is parted along the way that's shortest, the moving tables taking all of it (or half each, both moving).
    private func separated(_ positions: [CGPoint]) -> [CGPoint] {
        var positions = positions
        let isMoving = Set(moving)
        for _ in 0..<60 {
            var moved = false
            for table in moving {
                for other in positions.indices where other != table {
                    let a = CGRect(origin: positions[table], size: sizes[table]).insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2)
                    let b = CGRect(origin: positions[other], size: sizes[other]).insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2)
                    let overlap = a.intersection(b)
                    guard !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 else { continue }
                    let push = overlap.width < overlap.height
                        ? CGPoint(x: a.midX < b.midX ? -overlap.width : overlap.width, y: 0)
                        : CGPoint(x: 0, y: a.midY < b.midY ? -overlap.height : overlap.height)
                    if isMoving.contains(other) {
                        positions[table] += push * 0.5
                        positions[other] -= push * 0.5
                    } else {
                        positions[table] += push
                    }
                    moved = true
                }
            }
            if !moved { break }
        }
        return positions
    }

    /// Which way, and how steeply, the tangle grows as a table moves: from the change either side, its wires and its
    /// neighbors being all that changes.
    private func slope(of table: Int) -> CGPoint {
        let h: CGFloat = 2
        func energy(at point: CGPoint) -> Double {
            var moved = positions
            moved[table] = point
            return localEnergy(of: table, in: moved)
        }
        let p = positions[table]
        return CGPoint(x: (energy(at: p + CGPoint(x: h, y: 0)) - energy(at: p - CGPoint(x: h, y: 0))) / (2 * h),
                       y: (energy(at: p + CGPoint(x: 0, y: h)) - energy(at: p - CGPoint(x: 0, y: h))) / (2 * h))
    }

    /// The part of the tangle a table's position affects.
    private func localEnergy(of table: Int, in positions: [CGPoint]) -> Double {
        var energy = 0.0
        let own = wiresOf[table]
        let segments = wires.indices.map { endpoints($0, in: positions) }
        // Crossings of its wires with every other.
        for a in own {
            for b in wires.indices where b != a && !(own.contains(b) && b < a) && !sharesTable(a, b) {
                energy += tuning.depthWeight * Self.crossingDepth(segments[a], segments[b])
            }
            // Wires much longer than usual pull their tables in.
            let length = segments[a].0.distance(to: segments[a].1)
            if length > Self.reach { energy += 0.002 * Double((length - Self.reach) * (length - Self.reach)) / Double(Self.reach) }
        }
        // Overlapping other tables, or coming within the gap of them, pushes it away, hard.
        let frame = CGRect(origin: positions[table], size: sizes[table]).insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2)
        for other in positions.indices where other != table {
            let near = CGRect(origin: positions[other], size: sizes[other]).insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2)
            let overlap = frame.intersection(near)
            if !overlap.isNull { energy += 0.05 * Double(min(overlap.width, overlap.height) * min(overlap.width, overlap.height)) }
        }
        // A little toward where it started.
        energy += 0.00002 * Double(positions[table].distance(to: start[table]) * positions[table].distance(to: start[table]))
        return energy
    }

    // MARK: Geometry

    private func endpoints(_ wire: Int, in positions: [CGPoint]) -> (CGPoint, CGPoint) {
        let w = wires[wire]
        let center = { (table: Int, y: CGFloat) in CGPoint(x: positions[table].x + self.sizes[table].width / 2, y: positions[table].y + y) }
        return (center(w.from, w.fromY), center(w.to, w.toY))
    }

    private func sharesTable(_ a: Int, _ b: Int) -> Bool {
        let (x, y) = (wires[a], wires[b])
        return x.from == y.from || x.from == y.to || x.to == y.from || x.to == y.to
    }

    private func overlaps(_ positions: [CGPoint]) -> Bool {
        moving.contains { table in
            let frame = CGRect(origin: positions[table], size: sizes[table])
            return positions.indices.contains { $0 != table && frame.intersects(CGRect(origin: positions[$0], size: sizes[$0])) }
        }
    }

    /// For crossing segments, how far the nearer end of each is past the other's line, multiplied; 0 if they don't cross.
    private static func crossingDepth(_ s: (CGPoint, CGPoint), _ t: (CGPoint, CGPoint)) -> Double {
        // Signed distance from the line through a → b.
        func distance(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            let ab = b - a, ac = c - a
            return (ab.x * ac.y - ab.y * ac.x) / max(ab.length, 1e-6)
        }
        let c = distance(s.0, s.1, t.0), d = distance(s.0, s.1, t.1)
        let a = distance(t.0, t.1, s.0), b = distance(t.0, t.1, s.1)
        guard c * d < 0, a * b < 0 else { return 0 }
        return Double(min(abs(c), abs(d)) * min(abs(a), abs(b)))
    }

    /// How many pairs of segments cross, ones sharing an end aside.
    static func crossings(_ segments: [(CGPoint, CGPoint)]) -> Int {
        var count = 0
        for i in segments.indices {
            for j in segments.indices where j > i {
                let (a, b) = segments[i], (c, d) = segments[j]
                guard a != c, a != d, b != c, b != d else { continue }
                if crossing(a, b, c, d) != nil { count += 1 }
            }
        }
        return count
    }
}

private extension CGPoint {
    static func -= (a: inout CGPoint, b: CGPoint) { a = a - b }
}
