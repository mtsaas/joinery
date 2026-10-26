import SwiftUI

/// The whole data model small, in a corner: its groups and tables, and a frame around the part in view. Clicking or
/// dragging in it moves the view there, to get about a big model quickly.
struct Minimap: View {
    let tables: [Table]
    let groups: [(group: TableGroup, frame: CGRect)]
    /// The part of the canvas in view, in canvas points.
    let visible: CGRect
    /// Centers the view on a canvas point.
    let show: (CGPoint) -> Void

    private static let width: CGFloat = 200
    private static let inset: CGFloat = 8

    /// Everything, and the view, with a little room around.
    private var world: CGRect {
        let frames = tables.map(Metrics.frame) + groups.map(\.frame) + [visible]
        let all = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        return all.insetBy(dx: -all.width * 0.03, dy: -all.height * 0.03)
    }

    var body: some View {
        let world = world
        let scale = (Self.width - Self.inset * 2) / world.width
        // As tall as the model's shape needs, within reason.
        let height = min(max(world.height * scale, 60), 160) + Self.inset * 2
        let point = { (canvas: CGPoint) in CGPoint(x: (canvas.x - world.minX) * scale + Self.inset, y: (canvas.y - world.minY) * scale + Self.inset) }
        let rect = { (canvas: CGRect) in CGRect(origin: point(canvas.origin), size: canvas.size * scale) }
        Canvas { context, _ in
            for (group, frame) in groups {
                context.fill(Path(roundedRect: rect(frame), cornerRadius: 4), with: .color(group.color.color.opacity(0.18)))
            }
            for table in tables {
                context.fill(Path(roundedRect: rect(Metrics.frame(of: table)), cornerRadius: 1.5), with: .color(table.color.color.opacity(0.5)))
            }
            let view = Path(roundedRect: rect(visible), cornerRadius: 3)
            context.fill(view, with: .color(Color.primary.opacity(0.08)))
            context.stroke(view, with: .color(Color.primary.opacity(0.6)), lineWidth: 1)
        }
        .frame(width: Self.width, height: height)
        .clipShape(.rect(cornerRadius: 12))
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            show(CGPoint(x: (value.location.x - Self.inset) / scale + world.minX, y: (value.location.y - Self.inset) / scale + world.minY))
        })
        .help("Click or drag to move the view")
        .accessibilityElement()
        .accessibilityLabel("Minimap")
    }
}
