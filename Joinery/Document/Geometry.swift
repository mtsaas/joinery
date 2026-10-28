import CoreGraphics

// Points double as vectors: the canvas only ever needs positions and directions in the same plane.
extension CGPoint {
    init(_ size: CGSize) { self.init(x: size.width, y: size.height) }

    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, scale: CGFloat) -> CGPoint { CGPoint(x: a.x * scale, y: a.y * scale) }
    static func / (a: CGPoint, scale: CGFloat) -> CGPoint { CGPoint(x: a.x / scale, y: a.y / scale) }
    static prefix func - (a: CGPoint) -> CGPoint { CGPoint(x: -a.x, y: -a.y) }
    static func += (a: inout CGPoint, b: CGPoint) { a = a + b }

    func dot(_ other: CGPoint) -> CGFloat { x * other.x + y * other.y }
    var length: CGFloat { hypot(x, y) }
    var normalized: CGPoint? { length > 0 ? self / length : nil }
    /// Turned a quarter turn clockwise on screen (y points down).
    var perpendicular: CGPoint { CGPoint(x: -y, y: x) }
    func distance(to other: CGPoint) -> CGFloat { (self - other).length }
}

/// How far along `a`→`b` it crosses `c`→`d`, from 0 to 1, or nil if the segments don't cross.
extension CGRect {
    /// `point`, or if it's inside this rectangle with its corners rounded to `cornerRadius`, the nearest point on that
    /// rounded edge.
    func pushingOut(_ point: CGPoint, cornerRadius radius: CGFloat) -> CGPoint {
        guard contains(point) else { return point }
        let radius = min(radius, width / 2, height / 2)
        // The corners' centers bound an inner rectangle; outside it, a point is in a corner's reach.
        let inner = insetBy(dx: radius, dy: radius)
        let center = CGPoint(x: min(max(point.x, inner.minX), inner.maxX), y: min(max(point.y, inner.minY), inner.maxY))
        let away = point - center
        if away.x != 0 && away.y != 0 {
            // In a corner: out along the radius, if it's inside the rounding.
            return away.length < radius ? center + (away.normalized ?? .zero) * radius : point
        }
        // Along a side: straight out through the nearest one.
        let distances = [point.x - minX, maxX - point.x, point.y - minY, maxY - point.y]
        switch distances.indices.min(by: { distances[$0] < distances[$1] })! {
        case 0: return CGPoint(x: minX, y: point.y)
        case 1: return CGPoint(x: maxX, y: point.y)
        case 2: return CGPoint(x: point.x, y: minY)
        default: return CGPoint(x: point.x, y: maxY)
        }
    }

    /// How far `point` is from the rectangle; 0 inside it.
    func distance(to point: CGPoint) -> CGFloat {
        CGPoint(x: max(minX - point.x, 0, point.x - maxX), y: max(minY - point.y, 0, point.y - maxY)).length
    }
}

extension CGSize {
    static func * (size: CGSize, scale: CGFloat) -> CGSize { CGSize(width: size.width * scale, height: size.height * scale) }
}

func crossing(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat? {
    let r = b - a, s = d - c
    let denominator = r.x * s.y - r.y * s.x
    guard denominator != 0 else { return nil }
    let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator
    let u = ((c.x - a.x) * r.y - (c.y - a.y) * r.x) / denominator
    return (0...1).contains(t) && (0...1).contains(u) ? t : nil
}

func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    point.distance(to: closest(to: point, onSegment: a, b))
}

func closest(to point: CGPoint, onSegment a: CGPoint, _ b: CGPoint) -> CGPoint {
    let ab = b - a
    let lengthSquared = ab.dot(ab)
    guard lengthSquared > 0 else { return a }
    return a + ab * min(max((point - a).dot(ab) / lengthSquared, 0), 1)
}
