import SwiftUI

/// A table on the canvas, drawn at `zoom` rather than scaled, so its text stays sharp at any zoom.
struct TableCard: View {
    let table: Table
    let zoom: CGFloat
    let isSelected: Bool
    /// The row a wire being dragged would connect to.
    let targetColumn: Column.ID?

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let size = Metrics.size(of: table)
        VStack(spacing: 0) {
            Text(table.name)
                .font(.system(size: 12 * zoom, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.contentInset * zoom)
                .frame(height: Metrics.headerHeight * zoom)
                .background(table.color.color.opacity(0.13))
                .overlay(alignment: .bottom) { Theme.cardBorder.frame(height: 1 / displayScale) }
            ForEach(table.columns) { column in
                row(column)
                    .background(column.id == targetColumn ? Color.accentColor.opacity(0.14) : .clear)
            }
        }
        .frame(width: size.width * zoom, height: size.height * zoom, alignment: .top)
        .background(Theme.card)
        .clipShape(.rect(cornerRadius: Metrics.cornerRadius * zoom))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius * zoom).strokeBorder(Theme.cardBorder, lineWidth: 1 / displayScale)
        }
        .shadow(color: .black.opacity(0.07), radius: 1.5 * zoom, y: 0.5 * zoom)
        .shadow(color: .black.opacity(0.09), radius: 14 * zoom, y: 6 * zoom)
        .overlay {
            if isSelected {
                // strokeBorder draws inside its shape, so the ring's inner edge sits `selectionGap` out from the card,
                // at the concentric radius.
                let outset = Metrics.selectionGap + Metrics.selectionWidth
                RoundedRectangle(cornerRadius: (Metrics.cornerRadius + outset) * zoom)
                    .strokeBorder(Color.accentColor, lineWidth: Metrics.selectionWidth * zoom)
                    .padding(-outset * zoom)
            }
        }
        .contentShape(.rect(cornerRadius: Metrics.cornerRadius * zoom))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Table \(table.name), \(table.columns.count) columns")
    }

    private func row(_ column: Column) -> some View {
        HStack(spacing: 5 * zoom) {
            Image(systemName: "key.fill")
                .font(.system(size: 8 * zoom))
                .foregroundStyle(.secondary)
                .frame(width: 10 * zoom)
                .opacity(column.isPrimaryKey ? 1 : 0)
            Text(column.name)
                .font(.system(size: 11 * zoom, weight: column.isPrimaryKey ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 8 * zoom)
            Text(column.type.rawValue + (column.isNullable ? "?" : ""))
                .font(.system(size: 10 * zoom, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Metrics.contentInset * zoom)
        .frame(height: Metrics.rowHeight * zoom)
    }
}

/// Where wires plug in: filled with their color once connected, an empty ring until then.
struct Socket: View {
    let color: Color?
    let zoom: CGFloat
    @State private var isHovered = false

    var body: some View {
        let diameter = Metrics.socketDiameter * zoom
        Circle()
            .fill(color ?? Theme.card)
            .strokeBorder(color ?? Theme.socket, lineWidth: 1.5 * zoom)
            .frame(width: diameter, height: diameter)
            .scaleEffect(isHovered ? 1.45 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: isHovered)
            .frame(width: Metrics.socketHitRadius * 2 * zoom, height: Metrics.socketHitRadius * 2 * zoom)
            .contentShape(.circle)
            .onHover { isHovered = $0 }
            .pointerStyle(.link)
    }
}
