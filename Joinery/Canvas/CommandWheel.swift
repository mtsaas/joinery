import SwiftUI

/// Right-click: commands in a ring around the pointer, as in Fusion 360's marking menu. Move toward one and click; the
/// pointer needn't reach the label, only head its way. Escape, or a click in the middle, closes it. Commands that have
/// no direction, and a table's colors, sit in a panel below.
struct CommandWheel: View {
    enum Direction: Int, CaseIterable {
        // Clockwise from east, as y runs down.
        case east, southEast, south, southWest, west, northWest, north, northEast

        var unit: CGPoint {
            let angle = Double(rawValue) * .pi / 4
            return CGPoint(x: cos(angle), y: sin(angle))
        }

        /// Where its label's anchor sits from the middle. North and south are further out than the diagonals, so a
        /// wide label there clears its neighbors.
        var anchor: CGPoint {
            switch self {
            case .east, .west: unit * 54
            case .north, .south: unit * 74
            default: CGPoint(x: unit.x.sign == .minus ? -44 : 44, y: unit.y.sign == .minus ? -40 : 40)
            }
        }

        /// Labels grow away from the middle: rightward on the right, leftward on the left, centered top and bottom.
        var alignment: Alignment {
            switch self {
            case .north, .south: .center
            case .east, .northEast, .southEast: .leading
            default: .trailing
            }
        }
    }

    let center: CGPoint
    let slots: [Direction: PaletteCommand]
    let extras: [PaletteCommand]
    /// For a table: its color, and how to change it.
    var color: (current: TableColor, set: (TableColor) -> Void)?
    let dismiss: () -> Void

    @State private var pointer: CGPoint?
    @State private var isShown = false

    /// Within this of the middle, nothing's picked.
    private static let deadZone: CGFloat = 16
    private static let hubRadius: CGFloat = 13

    private var highlighted: Direction? {
        pointer.flatMap { Self.direction(of: $0 - center) }.flatMap { slots[$0] == nil ? nil : $0 }
    }

    /// The direction the pointer is heading from the middle, nearest of the eight; nil within the dead zone.
    static func direction(of offset: CGPoint) -> Direction? {
        guard offset.length > deadZone else { return nil }
        return Direction(rawValue: (Int((atan2(offset.y, offset.x) / (.pi / 4)).rounded()) + 8) % 8)
    }

    var body: some View {
        let highlighted = highlighted
        ZStack(alignment: .topLeading) {
            // Catches the pointer everywhere, so picking needs only a direction; dims the canvas a little, so the labels
            // read over busy tables.
            Color.black.opacity(isShown ? 0.22 : 0.001)
                .onContinuousHover { phase in
                    if case .active(let location) = phase { pointer = location }
                }
                .onTapGesture { location in
                    pointer = location
                    choose()
                }
            hub(highlighted)
                .position(center)
            ForEach(Direction.allCases, id: \.self) { direction in
                if let command = slots[direction] {
                    label(command, isHighlighted: direction == highlighted)
                        .frame(width: 0, height: 0, alignment: direction.alignment)
                        .position(center + direction.anchor * (isShown ? 1 : 0.5))
                        .allowsHitTesting(false)
                }
            }
            if !extras.isEmpty || color != nil {
                panel
                    .frame(width: 0, height: 0, alignment: .top)
                    .position(center + CGPoint(x: 0, y: (Direction.south.anchor.y + 26) * (isShown ? 1 : 0.5)))
            }
        }
        .opacity(isShown ? 1 : 0)
        .onAppear { withAnimation(.spring(duration: 0.22, bounce: 0.25)) { isShown = true } }
    }

    private func choose() {
        let command = highlighted.flatMap { slots[$0] }
        dismiss()
        command?.action()
    }

    /// A ring with the picked direction lit.
    private func hub(_ highlighted: Direction?) -> some View {
        ZStack {
            Circle().fill(.clear).glassEffect(.regular, in: .circle)
            if let highlighted {
                let angle = Double(highlighted.rawValue) * 45
                Circle()
                    .trim(from: 0, to: 0.125)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(angle - 22.5))
                    .padding(1.5)
                    .animation(.snappy(duration: 0.12), value: highlighted)
            }
        }
        .frame(width: Self.hubRadius * 2, height: Self.hubRadius * 2)
    }

    private func label(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: command.symbol)
                .frame(width: 16)
            Text(command.title)
            if let subtitle = command.subtitle {
                Text(subtitle).foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : command.isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background {
            if isHighlighted { Capsule().fill(command.isDestructive ? Color.red : Color.accentColor) }
        }
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy(duration: 0.12), value: isHighlighted)
    }

    /// The commands with no direction, and a table's colors.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let color {
                HStack(spacing: 6) {
                    ForEach(TableColor.allCases) { option in
                        Button {
                            dismiss()
                            color.set(option)
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 16, height: 16)
                                .padding(3)
                                .overlay { if option == color.current { Circle().strokeBorder(.primary, lineWidth: 1.5) } }
                        }
                        .buttonStyle(.plain)
                        .help(option.rawValue.capitalized)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            ForEach(extras) { command in
                Button {
                    dismiss()
                    command.action()
                } label: {
                    Label(command.title, systemImage: command.symbol)
                        .foregroundStyle(command.isDestructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .fixedSize()
        .padding(5)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
