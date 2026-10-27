import SwiftUI

/// A large panel over the canvas's right side for working on one table: its name and color, its columns (name, type,
/// key, required, unique, what each references), made-up rows to show the kind of data it holds, as in a spreadsheet,
/// and notes. Opened by double-clicking a table's header.
struct TableDesigner: View {
    @Binding var model: DataModel
    let id: Table.ID
    let close: () -> Void

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
            }
            .frame(width: 660)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        }
    }

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
            CommitField(text: table.name, prompt: "Table name") { name in
                let name = name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { change { $0.name = name } }
            }
            .font(.title2.weight(.semibold))
            .textFieldStyle(.plain)
            Spacer()
            Button("Close", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
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
                        .help(column.isPrimaryKey ? "Primary key: click to make it not one" : "Click to make it the primary key")
                        CommitField(text: column.name, prompt: "name") { name in
                            let name = name.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty { changeColumn(column.id) { $0.name = name } }
                        }
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        CommitField(text: column.type.rawValue, prompt: "type") { typed in
                            guard let parsed = DataType.parse(typed) else { return }
                            changeColumn(column.id) {
                                $0.type = parsed.type
                                if parsed.isNullable { $0.isNullable = true }
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 120)
                        Toggle("Required", isOn: Binding { !column.isNullable } set: { isOn in changeColumn(column.id) { $0.isNullable = !isOn } })
                            .labelsHidden()
                            .gridColumnAlignment(.center)
                        Toggle("Unique", isOn: flag(column, \.isUnique))
                            .labelsHidden()
                            .gridColumnAlignment(.center)
                        Text(references(column) ?? "–")
                            .foregroundStyle(references(column) == nil ? .tertiary : .secondary)
                            .lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                        Button("Delete Column", systemImage: "minus.circle") { model.removeColumn(column.id) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Delete column")
                    }
                }
            }
            Button("Add Column", systemImage: "plus") { model.addColumn(to: id, after: table.columns.last?.id) }
                .buttonStyle(.borderless)
        }
    }

    /// The made-up rows, a column per column, as in a spreadsheet.
    private func samples(_ table: Table) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(table.columns) { column in
                            Text(column.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .frame(width: Self.cellWidth, height: 28, alignment: .leading)
                                .background(table.color.headerFill)
                                .border(.separator, width: 0.5)
                        }
                        Color.clear.frame(width: 28, height: 28)
                    }
                    ForEach(table.samples.indices, id: \.self) { row in
                        GridRow {
                            ForEach(table.columns) { column in
                                CommitField(text: table.sample(row, column.id), prompt: "") { value in
                                    change { $0.setSample(row, column.id, to: value) }
                                }
                                .textFieldStyle(.plain)
                                .font(column.type == .text || column.type == .varchar ? .callout : .system(.callout, design: .monospaced))
                                .padding(.horizontal, 8)
                                .frame(width: Self.cellWidth, height: 26, alignment: .leading)
                                .background(Theme.card)
                                .border(.separator, width: 0.5)
                            }
                            Button("Delete Row", systemImage: "minus.circle") { change { $0.samples.remove(at: row) } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                                .help("Delete row")
                        }
                    }
                }
            }
            if table.samples.isEmpty {
                Text("No rows yet: add some to show the kind of data this table holds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Add Row", systemImage: "plus") { change { $0.samples.append([:]) } }
                .buttonStyle(.borderless)
        }
    }

    private static let cellWidth: CGFloat = 150

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

/// A text field that changes what it shows only when done with: Return, or clicking away. Typing in it isn't a
/// change a letter at a time, to undo a letter at a time.
struct CommitField: View {
    let text: String
    var prompt = ""
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(prompt, text: $draft)
            .focused($isFocused)
            .onAppear { draft = text }
            .onChange(of: text) { if !isFocused { draft = text } }
            .onSubmit(done)
            .onChange(of: isFocused) { if !isFocused { done() } }
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
            .background(Theme.card, in: .rect(cornerRadius: 8))
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
