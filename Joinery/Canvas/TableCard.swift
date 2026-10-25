import SwiftUI

/// A table on the canvas as a grid: a name header, then a row per column with its key, name and type. Drawn at `zoom`
/// rather than scaled, so text stays sharp. While editing, the cells are text fields.
struct TableCard: View {
    @Binding var table: Table
    let zoom: CGFloat
    let isSelected: Bool
    let isEditing: Bool
    /// The row a wire being dragged would connect to.
    let targetColumn: Column.ID?
    /// Foreign key columns, in the color of the table each references.
    let foreignKeys: [Column.ID: Color]
    var focus: FocusState<CanvasController.Field?>.Binding
    /// Return in a field.
    let submit: (CanvasController.Field) -> Void

    @Environment(\.displayScale) private var displayScale

    private var hairline: CGFloat { 1 / displayScale }

    var body: some View {
        let size = Metrics.size(of: table)
        VStack(spacing: 0) {
            header
            ForEach($table.columns) { $column in
                row($column)
                    .background(column.id == targetColumn ? Color.accentColor.opacity(0.14) : .clear)
                    .overlay(alignment: .top) { Theme.cardBorder.frame(height: hairline) }
            }
        }
        .frame(width: size.width * zoom, height: size.height * zoom, alignment: .top)
        .background(Theme.card)
        .clipShape(.rect(cornerRadius: Metrics.cornerRadius * zoom))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius * zoom).strokeBorder(Theme.cardBorder, lineWidth: hairline)
        }
        .shadow(color: .black.opacity(0.07), radius: 1.5 * zoom, y: 0.5 * zoom)
        .shadow(color: .black.opacity(0.09), radius: 14 * zoom, y: 6 * zoom)
        .overlay {
            if isSelected || isEditing {
                // strokeBorder draws inside its shape, so the ring's inner edge sits `selectionGap` out from the card,
                // at the concentric radius.
                let outset = Metrics.selectionGap + Metrics.selectionWidth
                RoundedRectangle(cornerRadius: (Metrics.cornerRadius + outset) * zoom)
                    .strokeBorder(Color.accentColor, lineWidth: Metrics.selectionWidth * zoom)
                    .padding(-outset * zoom)
            }
        }
        .contentShape(.rect(cornerRadius: Metrics.cornerRadius * zoom))
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityLabel("Table \(table.name), \(table.columns.count) columns")
    }

    private var header: some View {
        // The name lines up with the column names below, past the key column.
        cell(width: nil, inset: Metrics.keyColumnWidth + Metrics.cellInset) {
            if isEditing {
                TextField("table_name", text: $table.name)
                    .focused(focus, equals: .tableName(table.id))
                    .onSubmit { submit(.tableName(table.id)) }
            } else {
                Text(table.name)
            }
        }
        .font(.system(size: 12 * zoom, weight: .semibold))
        .frame(height: Metrics.headerHeight * zoom)
        .background(table.color.color.opacity(0.13))
    }

    private func row(_ column: Binding<Column>) -> some View {
        let id = column.wrappedValue.id
        return HStack(spacing: 0) {
            keyCell(column)
                .frame(width: Metrics.keyColumnWidth * zoom)
            Theme.cardBorder.frame(width: hairline)
            cell(width: nil) {
                if isEditing {
                    TextField("column_name", text: column.name)
                        .focused(focus, equals: .columnName(id))
                        .onSubmit { submit(.columnName(id)) }
                } else {
                    Text(column.wrappedValue.name)
                }
            }
            .font(.system(size: 11 * zoom, weight: column.wrappedValue.isPrimaryKey ? .medium : .regular))
            Theme.cardBorder.frame(width: hairline)
            cell(width: Metrics.typeColumnWidth * zoom) {
                if isEditing {
                    TypeField(column: column, focus: focus) { submit(.columnType(id)) }
                } else {
                    Text(column.wrappedValue.typeLabel)
                }
            }
            .font(.system(size: 10 * zoom, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .frame(height: Metrics.rowHeight * zoom)
    }

    /// PK, or FK in the color of the table it references.
    @ViewBuilder
    private func keyCell(_ column: Binding<Column>) -> some View {
        let label = Group {
            if column.wrappedValue.isPrimaryKey {
                Text("PK").foregroundStyle(.secondary)
            } else if let color = foreignKeys[column.wrappedValue.id] {
                Text("FK").foregroundStyle(color)
            } else {
                Text("·").foregroundStyle(.quaternary)
            }
        }
        .font(.system(size: 9 * zoom, weight: .bold, design: .rounded))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        if isEditing {
            Button { column.wrappedValue.isPrimaryKey.toggle() } label: { label.contentShape(.rect) }
                .buttonStyle(.plain)
                .help("Primary key (⌘K)")
        } else {
            label
        }
    }

    private func cell(width: CGFloat?, inset: CGFloat = Metrics.cellInset,
                      @ViewBuilder content: () -> some View) -> some View {
        content()
            .textFieldStyle(.plain)
            .lineLimit(1)
            .padding(.leading, inset * zoom)
            .padding(.trailing, Metrics.cellInset * zoom)
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
            .frame(width: width)
    }
}

/// Where a type is typed: "int", "ts", "text?" and so on, read when it's committed (Return, Tab, or leaving the
/// field), with the matching types suggested along the way.
private struct TypeField: View {
    @Binding var column: Column
    var focus: FocusState<CanvasController.Field?>.Binding
    let onSubmit: () -> Void
    @State private var text = ""

    var body: some View {
        TextField("type", text: $text)
            .focused(focus, equals: .columnType(column.id))
            .onAppear { text = column.typeLabel }
            // Escape ends editing by removing the field, before any focus change reaches it.
            .onDisappear { commit() }
            .onChange(of: focus.wrappedValue) { old, new in
                if old == .columnType(column.id), new != old { commit() }
            }
            .onSubmit {
                commit()
                onSubmit()
            }
            .textInputSuggestions {
                let word = text.trimmingCharacters(in: CharacterSet(charactersIn: "? ")).lowercased()
                ForEach(DataType.allCases.filter { word.isEmpty || $0.rawValue.hasPrefix(word) }) { type in
                    Text(type.rawValue).textInputCompletion(type.rawValue + (text.hasSuffix("?") ? "?" : ""))
                }
            }
            .help("A type, or the start of one; end with ? for nullable")
    }

    private func commit() {
        if let parsed = DataType.parse(text), parsed.type != column.type || parsed.isNullable != column.isNullable {
            column.type = parsed.type
            column.isNullable = parsed.isNullable
        }
        text = column.typeLabel
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
