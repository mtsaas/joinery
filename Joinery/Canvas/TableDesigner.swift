import SwiftUI

/// A large panel over the canvas's right side for working on one table: its name and color, its columns (name, type,
/// key, required, unique, what each references), made-up rows to show the kind of data it holds, as in a spreadsheet,
/// and notes. Opened by double-clicking a table's header.
///
/// Made to be used from the keyboard: it opens with the first column's name ready to type over. Tab moves across, and
/// Return down to the same field a row on, past the last adding another; ⌘↩ inserts below and ⌘⌫ deletes the column or
/// row; ⇧⌘K, ⇧⌘R and ⇧⌘U set the column's key, required and unique; Escape closes. Text applies on Return, Tab or
/// clicking away, one undoable change each.
struct TableDesigner: View {
    @Binding var model: DataModel
    let id: Table.ID
    /// A shortcut pressed while it's open, caught before the field being typed in can take it.
    @Binding var command: CanvasController.DesignerCommand?
    let close: () -> Void
    @FocusState private var focus: DesignerField?

    var body: some View {
        if let table = model.table(id) {
            VStack(spacing: 0) {
                header(table)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        section("Columns") { columns(table) }
                        section("Sample Data") { samples(table) }
                        section("Notes") {
                            NotesEditor(text: table.notes) { notes in change { $0.notes = notes } }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                hints
            }
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .onAppear {
                // Ready to type: the first column's name, or with none, the table's.
                DispatchQueue.main.async { focus = table.columns.first.map { .name($0.id) } ?? .tableName }
            }
            .onChange(of: command) {
                guard let command else { return }
                self.command = nil
                perform(command, in: table)
            }
        }
    }

    private static let width: CGFloat = 680

    // MARK: Parts

    private func header(_ table: Table) -> some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(TableColor.allCases) { color in
                    Button { change { $0.color = color } } label: {
                        Label(color.rawValue.capitalized, systemImage: color == table.color ? "checkmark.circle.fill" : "circle.fill")
                    }
                    .tint(color.color)
                }
            } label: {
                Circle().fill(table.color.color).frame(width: 18, height: 18)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
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
            Spacer()
            Button("Close", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Close (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func columns(_ table: Table) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Key"); Text("Name"); Text("Type"); Text("Required"); Text("Unique"); Text("References"); Color.clear.frame(width: 1, height: 1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(table.columns) { column in
                    GridRow {
                        Button { changeColumn(column.id) { $0.isPrimaryKey.toggle() } } label: {
                            Image(systemName: column.isPrimaryKey ? "key.fill" : "key")
                                .foregroundStyle(column.isPrimaryKey ? AnyShapeStyle(table.color.color) : AnyShapeStyle(.tertiary))
                                .frame(width: 22)
                        }
                        .buttonStyle(.borderless)
                        .gridColumnAlignment(.center)
                        .help(column.isPrimaryKey ? "Primary key: click to make it not one (⇧⌘K)" : "Make it the primary key (⇧⌘K)")
                        CommitField(text: column.name, prompt: "name", field: .name(column.id), focus: $focus) { name in
                            let name = name.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty { changeColumn(column.id) { $0.name = name } }
                        } onReturn: {
                            down(from: column.id, to: DesignerField.name)
                        }
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        CommitField(text: column.type.rawValue, prompt: "type", field: .type(column.id), focus: $focus) { typed in
                            guard let parsed = DataType.parse(typed) else { return }
                            changeColumn(column.id) {
                                $0.type = parsed.type
                                if parsed.isNullable { $0.isNullable = true }
                            }
                        } onReturn: {
                            down(from: column.id, to: DesignerField.type)
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 120)
                        Toggle("Required", isOn: Binding { !column.isNullable } set: { isOn in changeColumn(column.id) { $0.isNullable = !isOn } })
                            .labelsHidden()
                            .gridColumnAlignment(.center)
                            .help("Required (⇧⌘R)")
                        Toggle("Unique", isOn: flag(column, \.isUnique))
                            .labelsHidden()
                            .gridColumnAlignment(.center)
                            .help("Unique (⇧⌘U)")
                        Text(references(column) ?? "–")
                            .foregroundStyle(references(column) == nil ? .tertiary : .secondary)
                            .lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                        Button("Delete Column", systemImage: "minus.circle") { deleteColumn(column.id, in: table) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Delete column (⌘⌫)")
                    }
                }
            }
            Button("Add Column", systemImage: "plus") { addColumn(after: table.columns.last?.id, focusing: DesignerField.name) }
                .buttonStyle(.borderless)
        }
    }

    /// The made-up rows, a column per column, as in a spreadsheet: as wide as the panel, shared out, unless there are
    /// so many columns that it has to scroll.
    private func samples(_ table: Table) -> some View {
        let available = Self.width - 40 - Self.rowButtonWidth
        let cellWidth = max(Self.minimumCellWidth, available / CGFloat(max(table.columns.count, 1)))
        return VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(table.columns) { column in
                            Text(column.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .frame(width: cellWidth, height: 28, alignment: .leading)
                                .background(table.color.headerFill)
                                .border(.separator, width: 0.5)
                        }
                        Color.clear.frame(width: Self.rowButtonWidth, height: 28)
                    }
                    ForEach(table.samples.indices, id: \.self) { row in
                        GridRow {
                            ForEach(table.columns) { column in
                                CommitField(text: table.sample(row, column.id), field: .sample(row, column.id), focus: $focus) { value in
                                    change { $0.setSample(row, column.id, to: value) }
                                } onReturn: {
                                    if row + 1 == table.samples.count { change { $0.samples.append([:]) } }
                                    DispatchQueue.main.async { focus = .sample(row + 1, column.id) }
                                }
                                .textFieldStyle(.plain)
                                .font(column.type == .text || column.type == .varchar ? .callout : .system(.callout, design: .monospaced))
                                .padding(.horizontal, 8)
                                .frame(width: cellWidth, height: 26, alignment: .leading)
                                .background(focus == .sample(row, column.id) ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.background.opacity(0.5)))
                                .border(.separator, width: 0.5)
                            }
                            Button("Delete Row", systemImage: "minus.circle") { deleteRow(row, in: table) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .frame(width: Self.rowButtonWidth)
                                .help("Delete row (⌘⌫)")
                        }
                    }
                }
            }
            if table.samples.isEmpty {
                Text("No rows yet: add some to show the kind of data this table holds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Add Row", systemImage: "plus") { insertRow(at: table.samples.count, column: table.columns.first?.id) }
                .buttonStyle(.borderless)
        }
    }

    private static let minimumCellWidth: CGFloat = 110
    private static let rowButtonWidth: CGFloat = 28

    /// The keys, as on the canvas's grid.
    private var hints: some View {
        HStack(spacing: 14) {
            ForEach([("⇥", "Next"), ("↩", "Down"), ("⌘↩", "Insert"), ("⌘⌫", "Delete"), ("⇧⌘K", "Key"),
                     ("⇧⌘R", "Required"), ("⇧⌘U", "Unique"), ("⎋", "Close")], id: \.0) { key, action in
                HStack(spacing: 4) {
                    Text(key).fontWeight(.semibold)
                    Text(action).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 20)
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
        case .delete:
            switch focus {
            case .sample(let row, _)?: deleteRow(row, in: table)
            case .name(let id)?, .type(let id)?: deleteColumn(id, in: table)
            default: break
            }
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

/// Each field in the table designer, to move between them from the keyboard.
enum DesignerField: Hashable {
    case tableName
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
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $draft)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 160)
            .background(.background.opacity(0.5), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
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
