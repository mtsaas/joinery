import SwiftUI

/// A large panel over the canvas's right side for working on one table: its name and color, its columns (name, type,
/// key, required, unique, what each references), its indexes, made-up rows to show the kind of data it holds, as in a
/// spreadsheet, and notes. Opened from a table's right-click menu or ⌘K; a click anywhere off it puts it away.
///
/// Each column has a socket. Drag from one to another to tie them in a compound unique index, drawn as a cable in a
/// color of its own; drag from a cable to another socket to add that column to it.
///
/// Made to be used from the keyboard: it opens with the first column's name ready to type over. Tab moves across and on
/// to the next row (past the last, a new one), and Return down to the same field a row on, past the last adding another; ⌘↩ inserts below and ⌘⌫ deletes the column or
/// row; ⇧⌘K, ⇧⌘R and ⇧⌘U set the column's key, required and unique; Escape closes. Text applies on Return, Tab or
/// clicking away, one undoable change each.
struct TableDesigner: View {
    @Binding var model: DataModel
    let id: Table.ID
    /// A shortcut pressed while it's open, caught before the field being typed in can take it.
    @Binding var command: CanvasController.DesignerCommand?
    /// Set while the focus is in a grid, so Tab is caught for it.
    @Binding var isInGrid: Bool
    /// Only to look at, as when comparing versions.
    var isReadOnly = false
    /// As wide as it can be, in the window as it is.
    var maxWidth: CGFloat = .infinity
    let close: () -> Void
    @FocusState private var focus: DesignerField?
    /// As wide as it was last left, dragged by its left edge.
    @AppStorage("tableDesignerWidth") private var width: Double = 680
    /// Its width when a drag on its edge began.
    @State private var widthBeforeDrag: Double?
    /// A cable being drawn from a socket.
    @State private var cableDrag: CableDrag?
    /// Where the sockets are, in the column grid.
    @State private var sockets: [Column.ID: CGPoint] = [:]

    /// The column grid's coordinates, which the cables are drawn and dragged in.
    static let columnsSpace = "designerColumns"

    // Corners step in with the padding, each the one around it less the space between: concentric.
    private static let panelRadius: CGFloat = 24
    private static let inset: CGFloat = 12
    private static let cardRadius = panelRadius - inset
    private static let cellRadius: CGFloat = 6

    var body: some View {
        if let table = model.table(id) {
            VStack(spacing: 0) {
                header(table)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        section("Columns") { columns(table) }
                        section("Indexes") { indexes(table) }
                        section("Sample Data") { samples(table) }
                        section("Notes") {
                            NotesEditor(text: table.notes, radius: Self.cardRadius) { notes in change { $0.notes = notes } }
                        }
                    }
                    .padding(.horizontal, Self.inset)
                    .padding(.bottom, Self.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(isReadOnly)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                if !isReadOnly { hints }
            }
            .frame(width: shownWidth)
            .frame(maxHeight: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: Self.panelRadius))
            .overlay(alignment: .leading) { resizeHandle }
            .onAppear {
                // Ready to type: the first column's name, or with none, the table's.
                DispatchQueue.main.async { focus = table.columns.first.map { .name($0.id) } ?? .tableName }
            }
            .onChange(of: focus) {
                // Any of its fields; not the notes, where Tab is Tab.
                if (focus != nil) != isInGrid { isInGrid = focus != nil }
            }
            .onDisappear { isInGrid = false }
            .onChange(of: command) {
                guard let command else { return }
                self.command = nil
                if !isReadOnly { perform(command, in: table) }
            }
        }
    }

    private static let widths: ClosedRange<Double> = 520...1600

    /// Its width, kept inside the window however wide it was left.
    private var shownWidth: CGFloat { max(min(width, maxWidth), min(Self.widths.lowerBound, maxWidth)) }

    /// Its left edge, dragged to make it wider or narrower.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: .leading))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = widthBeforeDrag ?? shownWidth
                    widthBeforeDrag = start
                    width = min(max(start - value.translation.width, Self.widths.lowerBound), min(Self.widths.upperBound, maxWidth))
                }
                .onEnded { _ in widthBeforeDrag = nil })
            .help("Drag to resize")
    }

    // MARK: Parts

    private func header(_ table: Table) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(TableColor.allCases) { color in
                    Button { change { $0.color = color } } label: {
                        Label(color.rawValue.capitalized, systemImage: color == table.color ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(color.color)
                }
            } label: {
                Circle().fill(table.color.color.gradient).frame(width: 16, height: 16)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Color")
            CommitField(text: table.name, prompt: "Table name", field: .tableName, focus: $focus) { name in
                let name = name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { change { $0.name = name } }
            } onReturn: {
                focus = table.columns.first.map { .name($0.id) }
            }
            .font(.title2.weight(.semibold))
            .textFieldStyle(.plain)
            .disabled(isReadOnly)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help("Close (Esc)")
        }
        .padding(.leading, Self.inset + 8)
        .padding(.trailing, Self.inset)
        .padding(.vertical, Self.inset)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            content()
        }
    }

    /// A rounded, grouped box, as in Settings.
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(.fill.quaternary, in: .rect(cornerRadius: Self.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Self.cardRadius).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }

    /// A row at the end of a card that adds another; none when read-only.
    @ViewBuilder
    private func addRow(_ title: String, action: @escaping () -> Void) -> some View {
        if !isReadOnly {
            Button(action: action) {
                Label(title, systemImage: "plus.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func columns(_ table: Table) -> some View {
        card {
            VStack(spacing: 0) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                    GridRow {
                        Color.clear.frame(width: CableLayout.socketDiameter, height: 1)
                        Text("Key").gridColumnAlignment(.center)
                        Text("Name"); Text("Type")
                        Text("Required").gridColumnAlignment(.center)
                        Text("Unique").gridColumnAlignment(.center)
                        Text("References"); Color.clear.frame(width: 1, height: 1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    ForEach(table.columns) { column in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        columnRow(column, in: table)
                    }
                }
                // Room for every index's lane, and one more for a cable being drawn.
                .padding(.leading, CableLayout.gutter(lanes: table.liveIndexes.count + 1))
                .padding(.horizontal, 6)
                .overlayPreferenceValue(SocketAnchors.self) { anchors in
                    GeometryReader { proxy in
                        let points = anchors.mapValues { proxy[$0] }
                        IndexCables(table: table, sockets: points, drag: cableDrag, target: cableDrag.flatMap { target(of: $0, in: table) },
                                    isReadOnly: isReadOnly, dragged: { cableDrag = $0 }, dropped: { finishCable(in: table) },
                                    change: { change($0) })
                            .onChange(of: points, initial: true) { sockets = points }
                    }
                }
                .coordinateSpace(.named(Self.columnsSpace))
                if !isReadOnly { Divider() }
                addRow("Add Column") { addColumn(after: table.columns.last?.id, focusing: DesignerField.name) }
            }
        }
    }

    private func columnRow(_ column: Column, in table: Table) -> some View {
        GridRow {
            socket(column, in: table)
            Button { changeColumn(column.id) { $0.isPrimaryKey.toggle() } } label: {
                Image(systemName: column.isPrimaryKey ? "key.fill" : "key")
                    .foregroundStyle(column.isPrimaryKey ? AnyShapeStyle(table.color.color) : AnyShapeStyle(.tertiary))
                    .frame(width: 24, height: 24)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(column.isPrimaryKey ? "Primary key: click to make it not one (⇧⌘K)" : "Make it the primary key (⇧⌘K)")
            CommitField(text: column.name, prompt: "name", field: .name(column.id), focus: $focus) { name in
                let name = name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { changeColumn(column.id) { $0.name = name } }
            } onReturn: {
                down(from: column.id, to: DesignerField.name)
            }
            .modifier(Cell(isFocused: focus == .name(column.id)))
            .frame(minWidth: 140, maxWidth: 220)
            CommitField(text: column.type.rawValue, prompt: "type", field: .type(column.id), focus: $focus) { typed in
                guard let parsed = DataType.parse(typed) else { return }
                changeColumn(column.id) {
                    $0.type = parsed.type
                    if parsed.isNullable { $0.isNullable = true }
                }
            } onReturn: {
                down(from: column.id, to: DesignerField.type)
            }
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .modifier(Cell(isFocused: focus == .type(column.id)))
            .frame(width: 120)
            Toggle("Required", isOn: Binding { !column.isNullable } set: { isOn in changeColumn(column.id) { $0.isNullable = !isOn } })
                .labelsHidden()
                .help("Required (⇧⌘R)")
            Toggle("Unique", isOn: flag(column, \.isUnique))
                .labelsHidden()
                .help("Unique (⇧⌘U)")
            Text(references(column) ?? "–")
                .foregroundStyle(references(column) == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Delete Column", systemImage: "minus.circle.fill") { deleteColumn(column.id, in: table) }
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.hierarchical)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete column (⌘⌫)")
        }
        .padding(.vertical, 4)
    }

    /// A column's socket, to drag a cable from to another's: a compound unique index on the two.
    private func socket(_ column: Column, in table: Table) -> some View {
        let isTarget = cableDrag.flatMap { target(of: $0, in: table) } == column.id
        return Circle()
            .fill(isTarget ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.background))
            .overlay(Circle().strokeBorder(isTarget ? Color.accentColor : Theme.socket, lineWidth: 1.5))
            .frame(width: CableLayout.socketDiameter, height: CableLayout.socketDiameter)
            .anchorPreference(key: SocketAnchors.self, value: .center) { [column.id: $0] }
            .frame(width: 20, height: 24)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.columnsSpace))
                .onChanged { cableDrag = CableDrag(from: column.id, index: nil, location: $0.location) }
                .onEnded { _ in finishCable(in: table) })
            .contextMenu {
                Button("Add Index on “\(column.name)”") { change { $0.addIndex(on: [column.id], isUnique: false) } }
                Button("Add Unique Index on “\(column.name)”") { change { $0.addIndex(on: [column.id]) } }
            }
            .disabled(isReadOnly)
            .help("Drag to another column's socket to make a compound unique index; right-click for an index on this column alone")
    }

    /// The socket a cable would plug into: the one nearest the pointer, up or down, within half a row; not its own
    /// column, or for more of an index, not one already in it.
    private func target(of drag: CableDrag, in table: Table) -> Column.ID? {
        let taken = drag.index.flatMap { id in table.indexes.first { $0.id == id }?.columns } ?? [drag.from]
        return sockets.filter { !taken.contains($0.key) && abs($0.value.y - drag.location.y) < 16 }
            .min { abs($0.value.y - drag.location.y) < abs($1.value.y - drag.location.y) }?.key
    }

    private func finishCable(in table: Table) {
        guard let drag = cableDrag else { return }
        cableDrag = nil
        guard let target = target(of: drag, in: table) else { return }
        change { table in
            if let index = drag.index { table.add(target, toIndex: index) } else { table.addIndex(on: [drag.from, target]) }
        }
    }

    /// Each compound index: its color, name, columns and whether it's unique.
    private func indexes(_ table: Table) -> some View {
        card {
            VStack(spacing: 0) {
                let indexes = table.liveIndexes
                if indexes.isEmpty {
                    Text("Drag from one column's socket to another's to make a compound unique index, or right-click a socket for an index on that column alone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                        GridRow {
                            Color.clear.frame(width: 16, height: 1)
                            Text("Name"); Text("Columns")
                            Text("Unique").gridColumnAlignment(.center)
                            Color.clear.frame(width: 1, height: 1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        ForEach(indexes) { index in
                            Divider().gridCellUnsizedAxes(.horizontal)
                            indexRow(index, in: table)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private func indexRow(_ index: TableIndex, in table: Table) -> some View {
        GridRow {
            Menu {
                ForEach(TableColor.allCases) { color in
                    Button { changeIndex(index.id) { $0.color = color } } label: {
                        Label(color.rawValue.capitalized, systemImage: color == index.color ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(color.color)
                }
            } label: {
                Circle().fill(index.color.color.gradient).frame(width: 12, height: 12)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Color")
            CommitField(text: index.name ?? "", prompt: table.name(of: index), field: .indexName(index.id), focus: $focus) { name in
                let name = name.trimmingCharacters(in: .whitespaces)
                changeIndex(index.id) { $0.name = name.isEmpty ? nil : name }
            } onReturn: {
                focus = nil
            }
            .font(.system(.body, design: .monospaced))
            .modifier(Cell(isFocused: focus == .indexName(index.id)))
            .frame(minWidth: 160, maxWidth: 260)
            Text(table.columns(of: index).map(\.name).joined(separator: ", "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Unique", isOn: Binding { index.isUnique } set: { isOn in changeIndex(index.id) { $0.isUnique = isOn } })
                .labelsHidden()
                .help("Unique: no two rows may have the same values in all of these columns")
            Button("Delete Index", systemImage: "minus.circle.fill") { change { $0.indexes.removeAll { $0.id == index.id } } }
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.hierarchical)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete index")
        }
        .padding(.vertical, 4)
    }

    private func changeIndex(_ id: TableIndex.ID, _ body: (inout TableIndex) -> Void) {
        change { table in
            if let index = table.indexes.firstIndex(where: { $0.id == id }) { body(&table.indexes[index]) }
        }
    }

    /// The made-up rows, a column per column, as in a spreadsheet: as wide as the panel, shared out, unless there are
    /// so many columns that it has to scroll.
    private func samples(_ table: Table) -> some View {
        let available = shownWidth - Self.inset * 2 - Self.rowButtonWidth
        let cellWidth = max(Self.minimumCellWidth, available / CGFloat(max(table.columns.count, 1)))
        return card {
            VStack(spacing: 0) {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(Array(table.columns.enumerated()), id: \.element.id) { index, column in
                                if index > 0 { Divider() }
                                Text(column.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .frame(width: cellWidth, height: 28, alignment: .leading)
                            }
                            Color.clear.frame(width: Self.rowButtonWidth, height: 28)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        ForEach(table.samples.indices, id: \.self) { row in
                            Divider()
                            sampleRow(row, in: table, cellWidth: cellWidth)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                if table.samples.isEmpty {
                    Divider()
                    Text("No rows yet: add some to show the kind of data this table holds.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !isReadOnly { Divider() }
                addRow("Add Row") { insertRow(at: table.samples.count, column: table.columns.first?.id) }
            }
            .clipShape(.rect(cornerRadius: Self.cardRadius))
        }
    }

    private func sampleRow(_ row: Int, in table: Table, cellWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(table.columns.enumerated()), id: \.element.id) { index, column in
                if index > 0 { Divider() }
                CommitField(text: table.sample(row, column.id), field: .sample(row, column.id), focus: $focus) { value in
                    change { $0.setSample(row, column.id, to: value) }
                } onReturn: {
                    if row + 1 == table.samples.count { change { $0.samples.append([:]) } }
                    DispatchQueue.main.async { focus = .sample(row + 1, column.id) }
                }
                .textFieldStyle(.plain)
                .font(column.type == .text || column.type == .varchar ? .callout : .system(.callout, design: .monospaced))
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .background(focus == .sample(row, column.id) ? Color.accentColor.opacity(0.15) : .clear,
                            in: .rect(cornerRadius: Self.cellRadius))
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(width: cellWidth, height: 30, alignment: .leading)
            }
            Button("Delete Row", systemImage: "minus.circle.fill") { deleteRow(row, in: table) }
                .labelStyle(.iconOnly)
                .symbolRenderingMode(.hierarchical)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: Self.rowButtonWidth)
                .help("Delete row (⌘⌫)")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let minimumCellWidth: CGFloat = 110
    private static let rowButtonWidth: CGFloat = 32

    /// The keys, as on the canvas's grid.
    private var hints: some View {
        HStack(spacing: 14) {
            ForEach([("⇥", "Next"), ("↩", "Down"), ("⌘↩", "Insert"), ("⌘⌫", "Delete"), ("⇧⌘K", "Key"),
                     ("⇧⌘R", "Required"), ("⇧⌘U", "Unique"), ("⎋", "Close")], id: \.0) { key, action in
                HStack(spacing: 4) {
                    Text(key).fontWeight(.semibold).foregroundStyle(.secondary)
                    Text(action).foregroundStyle(.tertiary)
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, Self.inset + 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Keys

    private func perform(_ command: CanvasController.DesignerCommand, in table: Table) {
        let column: Column.ID? = switch focus {
        case .name(let id)?, .type(let id)?, .sample(_, let id)?: id
        default: nil
        }
        switch command {
        case .primaryKey: if let column { changeColumn(column) { $0.isPrimaryKey.toggle() } }
        case .required: if let column { changeColumn(column) { $0.isNullable.toggle() } }
        case .unique: if let column { changeColumn(column) { $0.isUnique.toggle() } }
        case .insert:
            switch focus {
            case .sample(let row, let id)?: insertRow(at: row + 1, column: id)
            case .type(let id)?: addColumn(after: id, focusing: DesignerField.type)
            default: addColumn(after: column ?? table.columns.last?.id, focusing: DesignerField.name)
            }
        case .next, .previous:
            tab(forward: command == .next, in: table)
        case .delete:
            switch focus {
            case .sample(let row, _)?: deleteRow(row, in: table)
            case .name(let id)?, .type(let id)?: deleteColumn(id, in: table)
            default: break
            }
        }
    }

    /// Tab in a grid: across, then on to the next row's first field, past the last adding another; Shift-Tab back.
    private func tab(forward: Bool, in table: Table) {
        let columns = table.columns.map(\.id)
        guard !columns.isEmpty else { return }
        switch focus {
        case .sample(let row, let column)?:
            let cells = table.samples.indices.flatMap { row in columns.map { DesignerField.sample(row, $0) } }
            guard let index = cells.firstIndex(of: .sample(row, column)) else { return }
            if forward, index + 1 == cells.count {
                change { $0.samples.append([:]) }
                DispatchQueue.main.async { focus = .sample(row + 1, columns[0]) }
            } else {
                focus = cells[max(min(index + (forward ? 1 : -1), cells.count - 1), 0)]
            }
        case let field?:
            let fields = [DesignerField.tableName] + columns.flatMap { [DesignerField.name($0), .type($0)] }
            guard let index = fields.firstIndex(of: field) else { return }
            if forward, index + 1 == fields.count {
                addColumn(after: columns.last, focusing: DesignerField.name)
            } else {
                focus = fields[max(min(index + (forward ? 1 : -1), fields.count - 1), 0)]
            }
        case nil:
            break
        }
    }

    /// Return in a column's field: the same field a column on, or a new column, past the last.
    private func down(from column: Column.ID, to field: @escaping (Column.ID) -> DesignerField) {
        guard let table = model.table(id), let index = table.columns.firstIndex(where: { $0.id == column }) else { return }
        if index + 1 < table.columns.count {
            focus = field(table.columns[index + 1].id)
        } else {
            addColumn(after: column, focusing: field)
        }
    }

    private func addColumn(after column: Column.ID?, focusing field: @escaping (Column.ID) -> DesignerField) {
        guard let added = model.addColumn(to: id, after: column) else { return }
        DispatchQueue.main.async { focus = field(added) }
    }

    private func deleteColumn(_ column: Column.ID, in table: Table) {
        let index = table.columns.firstIndex { $0.id == column } ?? 0
        model.removeColumn(column)
        let rest = table.columns.filter { $0.id != column }
        focus = rest.isEmpty ? .tableName : .name(rest[min(index, rest.count - 1)].id)
    }

    private func insertRow(at row: Int, column: Column.ID?) {
        change { $0.samples.insert([:], at: min(row, $0.samples.count)) }
        if let column { DispatchQueue.main.async { focus = .sample(row, column) } }
    }

    private func deleteRow(_ row: Int, in table: Table) {
        change { if $0.samples.indices.contains(row) { $0.samples.remove(at: row) } }
        let left = table.samples.count - 1
        if case .sample(_, let column)? = focus {
            focus = left > 0 ? .sample(min(row, left - 1), column) : nil
        }
    }

    // MARK: Changes

    /// One change to the table: one undo.
    private func change(_ body: (inout Table) -> Void) {
        guard let index = model.tables.firstIndex(where: { $0.id == id }) else { return }
        var table = model.tables[index]
        body(&table)
        if table != model.tables[index] { model.tables[index] = table }
    }

    private func changeColumn(_ column: Column.ID, _ body: (inout Column) -> Void) {
        change { table in
            if let index = table.columns.firstIndex(where: { $0.id == column }) { body(&table.columns[index]) }
        }
    }

    private func flag(_ column: Column, _ key: WritableKeyPath<Column, Bool>) -> Binding<Bool> {
        Binding { column[keyPath: key] } set: { isOn in changeColumn(column.id) { $0[keyPath: key] = isOn } }
    }

    /// What a foreign key references, as "table.column".
    private func references(_ column: Column) -> String? {
        model.relationships.first { $0.from == column.id }.flatMap { model.qualifiedName(of: $0.to) }
    }
}

/// A plain field in a grid row, tinted while it's being typed in.
private struct Cell: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isFocused ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
    }
}

/// Each field in the table designer, to move between them from the keyboard.
enum DesignerField: Hashable {
    case tableName
    case indexName(TableIndex.ID)
    case name(Column.ID)
    case type(Column.ID)
    case sample(Int, Column.ID)
}

/// A text field that changes what it shows only when done with: Return, Tab, clicking away or closing. Typing in it
/// isn't a change a letter at a time, to undo a letter at a time.
struct CommitField: View {
    let text: String
    var prompt = ""
    let field: DesignerField
    var focus: FocusState<DesignerField?>.Binding
    let commit: (String) -> Void
    var onReturn: () -> Void = {}
    @State private var draft = ""

    var body: some View {
        TextField(prompt, text: $draft)
            .focused(focus, equals: field)
            .onAppear { draft = text }
            .onChange(of: text) { if focus.wrappedValue != field { draft = text } }
            .onSubmit {
                done()
                onReturn()
            }
            .onChange(of: focus.wrappedValue == field) { wasFocused, isFocused in if wasFocused && !isFocused { done() } }
            .onDisappear(perform: done)
    }

    private func done() {
        if draft != text { commit(draft) }
    }
}

/// The table's notes: saved when you click away, or close the designer.
private struct NotesEditor: View {
    let text: String
    var radius: CGFloat = 12
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $draft)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 140)
            .background(.fill.quaternary, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("What it's for, where its data comes from, anything to remember…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .focused($isFocused)
            .onAppear { draft = text }
            .onChange(of: text) { if !isFocused { draft = text } }
            .onChange(of: isFocused) { if !isFocused, draft != text { commit(draft) } }
            .onDisappear { if draft != text { commit(draft) } }
    }
}
