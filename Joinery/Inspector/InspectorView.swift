import SwiftUI

/// Edits whatever's selected on the canvas.
struct InspectorView: View {
    @Binding var schema: Schema
    @Bindable var canvas: CanvasController

    var body: some View {
        switch canvas.selection {
        case .table(let id):
            if schema.table(id) != nil { TableInspector(table: binding(for: id), schema: $schema) }
        case .relationship(let id):
            if let relationship = schema.relationships.first(where: { $0.id == id }) {
                Form {
                    Section("Foreign Key") {
                        LabeledContent("Column", value: schema.qualifiedName(of: relationship.from) ?? "")
                        LabeledContent("References", value: schema.qualifiedName(of: relationship.to) ?? "")
                        LabeledContent("Zip Ties", value: relationship.zipTies.count.formatted())
                    }
                    Button("Delete Foreign Key", role: .destructive) { canvas.deleteSelection(in: &schema) }
                }
                .formStyle(.grouped)
            }
        case .zipTie(let id):
            if let tie = schema.zipTies.first(where: { $0.id == id }) {
                Form {
                    Section("Zip Tie") {
                        ForEach(tie.relationships, id: \.self) { relationshipID in
                            if let relationship = schema.relationships.first(where: { $0.id == relationshipID }) {
                                ForeignKeyLabel(schema: schema, relationship: relationship)
                            }
                        }
                    }
                    Button("Cut Zip Tie", systemImage: "scissors", role: .destructive) { canvas.deleteSelection(in: &schema) }
                }
                .formStyle(.grouped)
            }
        case nil:
            ContentUnavailableView("No Selection", systemImage: "tablecells",
                                   description: Text("Select a table to edit its columns."))
        }
    }

    /// Looks the table up on every access, so a binding held by a field outliving the table can't index past the end.
    private func binding(for id: Table.ID) -> Binding<Table> {
        Binding {
            schema.table(id) ?? Table(name: "", position: .zero, color: .blue)
        } set: { table in
            if let index = schema.tables.firstIndex(where: { $0.id == id }) { schema.tables[index] = table }
        }
    }
}

private struct TableInspector: View {
    @Binding var table: Table
    @Binding var schema: Schema

    var body: some View {
        Form {
            Section("Table") {
                TextField("Name", text: $table.name)
                LabeledContent("Color") { ColorSwatches(selection: $table.color) }
            }
            Section("Columns") {
                ForEach($table.columns) { $column in
                    ColumnRow(column: $column) { schema.removeColumn(column.id) }
                }
                .onMove { table.columns.move(fromOffsets: $0, toOffset: $1) }
                Button("Add Column", systemImage: "plus") {
                    var number = table.columns.count + 1
                    while table.columns.contains(where: { $0.name == "column_\(number)" }) { number += 1 }
                    table.columns.append(Column(name: "column_\(number)", type: .text))
                }
                .buttonStyle(.borderless)
            }
            let columns = Set(table.columns.map(\.id))
            let keys = schema.relationships.filter { columns.contains($0.from) || columns.contains($0.to) }
            if !keys.isEmpty {
                Section("Foreign Keys") {
                    ForEach(keys) { relationship in
                        ForeignKeyLabel(schema: schema, relationship: relationship)
                            .contextMenu {
                                Button("Delete Foreign Key", role: .destructive) {
                                    schema.removeRelationships { $0.id == relationship.id }
                                }
                            }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ColumnRow: View {
    @Binding var column: Column
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $column.name)
                .labelsHidden()
                .textFieldStyle(.plain)
                .fontWeight(column.isPrimaryKey ? .medium : .regular)
            if column.isPrimaryKey {
                Image(systemName: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Primary key")
            }
            Picker("Type", selection: $column.type) {
                ForEach(DataType.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Menu {
                Toggle("Primary Key", isOn: $column.isPrimaryKey)
                Toggle("Nullable", isOn: $column.isNullable)
                Divider()
                Button("Delete Column", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Column Options")
        }
    }
}

private struct ForeignKeyLabel: View {
    let schema: Schema
    let relationship: Relationship

    var body: some View {
        HStack {
            Text(schema.qualifiedName(of: relationship.from) ?? "")
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityLabel("references")
            Text(schema.qualifiedName(of: relationship.to) ?? "")
        }
        .font(.callout.monospaced())
        .lineLimit(1)
    }
}

/// Freeform-style color choice: two rows of dots, the chosen one ringed.
private struct ColorSwatches: View {
    @Binding var selection: TableColor

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(18), spacing: 6), count: 6), spacing: 6) {
            ForEach(TableColor.allCases) { color in
                Button {
                    selection = color
                } label: {
                    Circle()
                        .fill(color.color)
                        .padding(2)
                        .overlay { if color == selection { Circle().strokeBorder(.secondary, lineWidth: 1.5) } }
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.rawValue.capitalized)
                .accessibilityAddTraits(color == selection ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}
