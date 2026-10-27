import SwiftUI

/// After copying tables, a popover offering the tables they're joined to, nearest first: check some, search by name,
/// and copy again with them.
struct CopyMore: View {
    let model: DataModel
    /// What was copied.
    let copied: Set<Table.ID>
    /// Copies these, the copied tables and those chosen.
    let copy: (Set<Table.ID>) -> Void

    @State private var chosen: Set<Table.ID> = []
    @State private var search = ""

    var body: some View {
        let distances = model.joinedTables(to: copied)
        let shown = model.tables
            .filter { distances[$0.id] != nil && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
            .sorted { (distances[$0.id]!, $0.name) < (distances[$1.id]!, $1.name) }
        let sections = Dictionary(grouping: shown) { distances[$0.id]! }.sorted { $0.key < $1.key }
        VStack(alignment: .leading, spacing: 10) {
            Text(copied.count == 1 ? "Copied 1 table" : "Copied \(copied.count) tables")
                .font(.headline)
            Text("Copy tables they're joined to as well:")
                .foregroundStyle(.secondary)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(sections, id: \.key) { distance, tables in
                    Section {
                        ForEach(tables) { table in
                            Toggle(isOn: Binding { chosen.contains(table.id) } set: { isOn in
                                if isOn { chosen.insert(table.id) } else { chosen.remove(table.id) }
                            }) {
                                HStack(spacing: 6) {
                                    Circle().fill(table.color.color).frame(width: 8, height: 8)
                                    Text(table.name)
                                    if let group = table.group.flatMap({ id in model.groups.first { $0.id == id } }) {
                                        Text(group.name).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(distance == 1 ? "Joined directly" : "\(distance) keys away")
                            Spacer()
                            let ids = Set(tables.map(\.id))
                            Button(ids.isSubset(of: chosen) ? "None" : "All") {
                                if ids.isSubset(of: chosen) { chosen.subtract(ids) } else { chosen.formUnion(ids) }
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .frame(height: min(CGFloat(shown.count + sections.count) * 26 + 8, 300))
            .overlay { if shown.isEmpty { Text("No tables match").foregroundStyle(.secondary) } }
            HStack {
                Spacer()
                Button(chosen.isEmpty ? "Copy" : "Copy \(copied.count + chosen.count) Tables") { copy(copied.union(chosen)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
