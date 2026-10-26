import SwiftUI

/// Every group's boundary, behind the wires and tables: a tinted, rounded area around its tables with its name at the
/// top left, ringed when selected. The name is where a group is grabbed, to select or move it.
struct GroupLayer: View {
    let groups: [(group: TableGroup, frame: CGRect)]
    let zoom: CGFloat
    let viewOffset: CGPoint
    let selected: Set<TableGroup.ID>
    /// Its name is being edited over it, so isn't drawn.
    var renaming: TableGroup.ID?

    var body: some View {
        Canvas { context, _ in
            for (group, frame) in groups {
                let rect = CGRect(origin: frame.origin * zoom + viewOffset, size: frame.size * zoom)
                let shape = Path(roundedRect: rect, cornerRadius: Metrics.groupCornerRadius * zoom, style: .continuous)
                let color = group.color.color
                context.fill(shape, with: .color(color.opacity(0.07)))
                let isSelected = selected.contains(group.id)
                context.stroke(shape, with: .color(isSelected ? .accentColor : color.opacity(0.4)),
                               style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: isSelected ? [] : [5, 4]))
                guard group.id != renaming, zoom >= 0.2 else { continue }
                let label = context.resolve(Text(group.name).font(Self.labelFont(zoom: zoom)).foregroundStyle(color))
                context.draw(label, at: Self.labelOrigin(of: frame) * zoom + viewOffset, anchor: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    static func labelFont(zoom: CGFloat) -> Font { .system(size: 13 * zoom, weight: .semibold) }

    /// Where a group's name starts, on the middle of its line, in canvas points.
    static func labelOrigin(of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + Metrics.groupPadding, y: frame.minY + Metrics.groupPadding / 2 + Metrics.groupLabelHeight / 2)
    }

    /// The band along a group's top, above its tables, where its name is and it can be grabbed.
    static func labelBand(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: Metrics.groupPadding + Metrics.groupLabelHeight)
    }
}
