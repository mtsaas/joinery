import SwiftUI

/// A table on the canvas as a grid, like a small spreadsheet: a name header, then a row per column with its key, name
/// and type. Drawn at `zoom` rather than scaled, so text stays sharp.
///
/// Every cell is plain text, except the one being edited: it alone becomes a text field, set in exactly the same
/// place and type, so editing doesn't look like filling in a form. The grid cursor is a border around its cell.
struct TableCard: View {
    let table: Table
    let zoom: CGFloat
    let isSelected: Bool
    /// The grid cursor, if it's in this table.
    let cursor: CanvasController.Cell?
    let isEditing: Bool
    @Binding var draft: String
    let selectsAllDraft: Bool
    /// The row a wire being dragged would connect to.
    let targetColumn: Column.ID?
    /// Foreign key columns, in the color of the table each references.
    let foreignKeys: [Column.ID: Color]
    /// Called if the cell being edited loses focus some other way than the grid's keys, say a click elsewhere.
    let editorLostFocus: () -> Void

    @Environment(\.displayScale) private var displayScale

    private var hairline: CGFloat { 1 / displayScale }

    var body: some View {
        let size = Metrics.size(of: table)
        let compoundKeys = table.compoundPrimaryKeyRuns
        VStack(spacing: 0) {
            header
            ForEach(Array(table.columns.enumerated()), id: \.element.id) { index, column in
                let inCompoundKey = compoundKeys.contains { $0.contains(index) }
                row(column, showsKey: !inCompoundKey)
                    .background(column.id == targetColumn ? Color.accentColor.opacity(0.14) : .clear)
                    // Between rows; the header's own edge is the line above the first. Within a compound key the
                    // key cells are one, so the line stops short of them.
                    .overlay(alignment: .top) {
                        if index > 0 {
                            HStack(spacing: 0) {
                                if compoundKeys.contains(where: { $0.contains(index) && $0.lowerBound < index }) {
                                    Color.clear.frame(width: Metrics.keyColumnWidth * zoom + hairline)
                                }
                                Theme.cardBorder
                            }
                            .frame(height: hairline)
                        }
                    }
            }
        }
        .frame(width: size.width * zoom, height: size.height * zoom, alignment: .top)
        // One PK for each compound key, in the middle of its merged cell.
        .overlay(alignment: .topLeading) {
            ForEach(compoundKeys, id: \.lowerBound) { run in
                keyLabel(Text("PK").foregroundStyle(.secondary))
                    .frame(width: Metrics.keyColumnWidth * zoom, height: CGFloat(run.count) * Metrics.rowHeight * zoom)
                    .offset(y: (Metrics.headerHeight + CGFloat(run.lowerBound) * Metrics.rowHeight) * zoom)
                    .allowsHitTesting(false)
            }
        }
        .background(Theme.card)
        .clipShape(.rect(cornerRadius: Metrics.cornerRadius * zoom, style: .circular))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius * zoom, style: .circular)
                .strokeBorder(Theme.cardBorder, lineWidth: hairline)
        }
        .overlay(alignment: .top) {
            let width = max(Metrics.headerBorderWidth * zoom, hairline)
            HeaderEdge(cornerRadius: Metrics.cornerRadius * zoom, inset: width / 2)
                .stroke(table.color.headerBorder, lineWidth: width)
                .frame(height: Metrics.headerHeight * zoom)
        }
        .shadow(color: .black.opacity(0.07), radius: 1.5 * zoom, y: 0.5 * zoom)
        .shadow(color: .black.opacity(0.09), radius: 14 * zoom, y: 6 * zoom)
        .overlay {
            if isSelected {
                // strokeBorder draws inside its shape, so the ring's inner edge sits `selectionGap` out from the card,
                // at the concentric radius.
                let outset = Metrics.selectionGap + Metrics.selectionWidth
                RoundedRectangle(cornerRadius: (Metrics.cornerRadius + outset) * zoom, style: .circular)
                    .strokeBorder(Color.accentColor, lineWidth: Metrics.selectionWidth * zoom)
                    .padding(-outset * zoom)
            }
        }
        .contentShape(.rect(cornerRadius: Metrics.cornerRadius * zoom, style: .circular))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Table \(table.name), \(table.columns.count) columns")
    }

    private var header: some View {
        let cell = CanvasController.Cell.name(of: table.id)
        return text(table.name, in: cell, width: nil)
            .font(.system(size: 11.5 * zoom, weight: .semibold))
            .frame(height: Metrics.headerHeight * zoom)
            .background(table.color.headerFill)
            .overlay { cursorBorder(cell) }
    }

    private func row(_ column: Column, showsKey: Bool) -> some View {
        let cell = { (part: Metrics.GridColumn) in CanvasController.Cell(table: table.id, row: .column(column.id), part: part) }
        return HStack(spacing: 0) {
            keyCell(column, showsLabel: showsKey)
                .frame(width: Metrics.keyColumnWidth * zoom)
                .overlay { cursorBorder(cell(.key)) }
            Theme.cardBorder.frame(width: hairline)
            text(column.name, in: cell(.name), width: nil)
                .font(.system(size: 11 * zoom, weight: column.isPrimaryKey ? .medium : .regular))
                .overlay { cursorBorder(cell(.name)) }
            Theme.cardBorder.frame(width: hairline)
            text(column.typeLabel, in: cell(.type), width: Metrics.typeColumnWidth * zoom, completesTypes: true)
                .font(.system(size: 10 * zoom, design: .monospaced))
                .foregroundStyle(.secondary)
                .overlay { cursorBorder(cell(.type)) }
        }
        .frame(height: Metrics.rowHeight * zoom)
    }

    /// PK, or FK in the color of the table it references.
    private func keyCell(_ column: Column, showsLabel: Bool) -> some View {
        keyLabel(Group {
            if column.isPrimaryKey {
                Text("PK").foregroundStyle(.secondary)
            } else if let color = foreignKeys[column.id] {
                Text("FK").foregroundStyle(color)
            } else {
                Text("·").foregroundStyle(.quaternary)
            }
        })
        .opacity(showsLabel ? 1 : 0)
    }

    private func keyLabel(_ text: some View) -> some View {
        text
            .font(.system(size: 9 * zoom, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A cell's text, or if it's the one being edited, the editor in its place.
    private func text(_ value: String, in cell: CanvasController.Cell, width: CGFloat?, completesTypes: Bool = false) -> some View {
        Group {
            if isEditing && cursor == cell {
                CellEditor(text: $draft, selectsAll: selectsAllDraft, completesTypes: completesTypes, lostFocus: editorLostFocus)
            } else {
                Text(value)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, Metrics.cellInset * zoom)
        .frame(maxWidth: width ?? .infinity, maxHeight: .infinity, alignment: .leading)
        .frame(width: width)
    }

    /// The grid cursor: a border just inside the cell, as in a spreadsheet.
    @ViewBuilder
    private func cursorBorder(_ cell: CanvasController.Cell) -> some View {
        if cursor == cell {
            RoundedRectangle(cornerRadius: 2 * zoom)
                .strokeBorder(Color.accentColor, lineWidth: max(2 * zoom, 1.5))
                .padding(1)
                .allowsHitTesting(false)
        }
    }
}

/// The one live text field: it takes focus as it appears, with the caret at the end or everything selected. For a
/// type, the rest of the type the text so far would become shows faded after it ("ti" → "mestamp").
private struct CellEditor: View {
    @Binding var text: String
    let selectsAll: Bool
    let completesTypes: Bool
    let lostFocus: () -> Void
    @FocusState private var isFocused: Bool
    @State private var selection: TextSelection?

    var body: some View {
        TextField("", text: $text, selection: $selection)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .overlay(alignment: .leading) {
                if completesTypes {
                    // Monospaced, so a hidden copy of the text lines the rest up exactly.
                    HStack(spacing: 0) {
                        Text(text).hidden()
                        Text(completion).foregroundStyle(.tertiary)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                placeCaret()
                isFocused = true
            }
            // Keys typed before it had focus were added to the text for it; the caret goes after them.
            .onChange(of: text) { if !isFocused { selection = TextSelection(insertionPoint: text.endIndex) } }
            .onChange(of: isFocused) {
                guard isFocused else { return lostFocus() }
                // A text field selects all its text as it takes focus, after anything set before; set it again once
                // focus has arrived, and once more after AppKit finishes, or the next key would replace the first.
                placeCaret()
                DispatchQueue.main.async { placeCaret() }
            }
    }

    /// Typing over a cell wants the caret after what was typed; a double-click, everything selected.
    private func placeCaret() {
        selection = selectsAll ? TextSelection(range: text.startIndex..<text.endIndex) : TextSelection(insertionPoint: text.endIndex)
    }

    private var completion: String {
        let word = text.lowercased()
        guard !word.isEmpty, !word.hasSuffix("?"), let parsed = DataType.parse(word), parsed.type.rawValue.hasPrefix(word) else {
            return ""
        }
        return String(parsed.type.rawValue.dropFirst(word.count))
    }
}

/// The header's left, top and right edges, open at the bottom: stroked `inset` inside the card, along a radius that much
/// smaller, so it's concentric with the card's corners.
private struct HeaderEdge: Shape {
    let cornerRadius: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + inset, right = rect.maxX - inset, top = rect.minY + inset
        let radius = cornerRadius - inset
        var path = Path()
        path.move(to: CGPoint(x: left, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: right, y: top), radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: right, y: rect.maxY))
        return path
    }
}

extension Column {
    /// The type as shown and typed: "uuid", or "text?" when nullable.
    var typeLabel: String { type.rawValue + (isNullable ? "?" : "") }
}

/// Where wires plug in: filled with their color once connected, an empty ring until then.
struct Socket: View {
    let color: Color?
    let zoom: CGFloat
    @State private var isHovered = false

    var body: some View {
        let diameter = Metrics.socketDiameter * zoom
        // At least a comfortable target, but no taller than its row, so neighbors don't overlap.
        let target = max(Metrics.socketHitRadius * 2 * zoom, min(Metrics.minimumTarget, Metrics.rowHeight * zoom))
        Circle()
            .fill(color ?? Theme.card)
            .strokeBorder(color ?? Theme.socket, lineWidth: 1.5 * zoom)
            .frame(width: diameter, height: diameter)
            .scaleEffect(isHovered ? 1.45 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: isHovered)
            .frame(width: target, height: target)
            .contentShape(.circle)
            .onHover { isHovered = $0 }
            .pointerStyle(.link)
    }
}
