import SwiftUI

/// Every group's boundary, behind the wires and tables: a tinted, rounded area around its tables with its name at the
/// top left, ringed when selected, or when tables dragged over it would join it. A group moves by the grip left of its
/// name or by its border, so a selection rectangle can start anywhere inside it.
struct GroupLayer: View {
    let groups: [(group: TableGroup, frame: CGRect)]
    let zoom: CGFloat
    let viewOffset: CGPoint
    let selected: Set<TableGroup.ID>
    /// Groups that tables being dragged would join if dropped.
    var joining: Set<TableGroup.ID> = []
    /// Its name is being edited over it, so isn't drawn.
    var renaming: TableGroup.ID?
    /// In focus mode, the groups with a table in focus; the rest fade.
    var focused: Set<TableGroup.ID>?

    var body: some View {
        Canvas { context, _ in
            for (group, frame) in groups {
                var context = context
                if let focused, !focused.contains(group.id) { context.opacity = TableLayer.fadedOpacity }
                let rect = CGRect(origin: frame.origin * zoom + viewOffset, size: frame.size * zoom)
                let shape = Path(roundedRect: rect, cornerRadius: Metrics.groupCornerRadius * zoom, style: .continuous)
                let color = group.color.color
                let isJoining = joining.contains(group.id)
                context.fill(shape, with: .color(color.opacity(isJoining ? 0.16 : 0.07)))
                let isSelected = selected.contains(group.id)
                let ring: Color = isSelected ? .accentColor : isJoining ? color : color.opacity(0.4)
                context.stroke(shape, with: .color(ring),
                               style: StrokeStyle(lineWidth: isSelected || isJoining ? 2 : 1, dash: isSelected || isJoining ? [] : [5, 4]))
                guard group.id != renaming, zoom >= 0.2 else { continue }
                let label = context.resolve(Text(group.name).font(Self.labelFont(zoom: zoom)).foregroundStyle(color))
                context.draw(label, at: Self.labelOrigin(of: frame) * zoom + viewOffset, anchor: .leading)
                // The grip: two columns of three dots, as on a table's header.
                let grip = Self.grip(of: frame)
                let dot: CGFloat = 3, gap: CGFloat = 4.5
                var dots = Path()
                for column in 0..<2 { for row in 0..<3 {
                    let center = CGPoint(x: grip.minX + dot / 2 + CGFloat(column) * gap, y: grip.midY + CGFloat(row - 1) * gap) * zoom + viewOffset
                    dots.addEllipse(in: CGRect(x: center.x - dot * zoom / 2, y: center.y - dot * zoom / 2, width: dot * zoom, height: dot * zoom))
                } }
                context.fill(dots, with: .color(color.opacity(0.75)))
            }
        }
        .allowsHitTesting(false)
    }

    static func labelFont(zoom: CGFloat) -> Font { .system(size: 13 * zoom, weight: .semibold) }

    /// How far a group's name is from its grip's leading edge: as far as on a table's header.
    static let nameOffset = Metrics.gripWidth - Metrics.cellInset

    /// Where a group's name starts, after its grip, on the middle of its line, in canvas points.
    static func labelOrigin(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + Metrics.groupPadding + nameOffset, y: frame.minY + Metrics.groupPadding / 2 + Metrics.groupLabelHeight / 2)
    }

    /// Where a group is grabbed to move it: in line with its tables' left edges, the name after it.
    static func grip(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + Metrics.groupPadding, y: labelOrigin(of: frame).y - Metrics.groupLabelHeight / 2,
               width: nameOffset, height: Metrics.groupLabelHeight)
    }

    /// The band along a group's top, above its tables, where its name is and it can be grabbed.
    static func labelBand(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Metrics.groupPadding + Metrics.groupLabelHeight)
    }
}
