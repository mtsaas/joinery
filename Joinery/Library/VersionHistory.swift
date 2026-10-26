import SwiftUI

/// The open model's earlier versions, in a sidebar, by day: step through them with the arrow keys and each shows on the
/// canvas, read-only, until one is restored or "Now" is chosen again.
struct VersionHistory: View {
    let open: OpenModel
    /// The version the canvas shows instead of the model, if any.
    @Binding var preview: Preview?

    struct Preview: Equatable {
        let version: History.Version
        let model: DataModel
    }

    private enum Item: Hashable {
        case now
        case version(History.Version)
    }

    @State private var versions: [History.Version] = []
    /// Versions read so far; they never change.
    @State private var models: [URL: DataModel] = [:]
    @State private var selection: Item? = .now
    @FocusState private var isFocused: Bool

    var body: some View {
        List(selection: $selection) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Now")
                Text("As it is, to edit").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .tag(Item.now)
            ForEach(days, id: \.day) { day in
                Section(Self.title(of: day.day)) {
                    ForEach(day.versions) { row($0) }
                }
            }
        }
        .focused($isFocused)
        .overlay {
            if versions.isEmpty {
                ContentUnavailableView("No Versions Yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("One is kept the next time this data model is opened, or changed in a big way."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onAppear {
            load()
            isFocused = true
        }
        .onChange(of: open.model) { load() }
        .onChange(of: selection) { show(selection) }
        .onDisappear { preview = nil }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .pickVersion)) { note in
            guard let index = note.object as? Int else { return }
            selection = versions.indices.contains(index) ? .version(versions[index]) : .now
        }
        #endif
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .version(let version) = selection {
                Button { restore(version) } label: {
                    Text("Restore This Version").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            Text("Kept when you open it, before AI assistants' changes, before deleting or rearranging tables, and hourly while editing. Older ones thin out to one a day, then one a week. Restoring can be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.bar)
    }

    private var days: [(day: Date, versions: [History.Version])] {
        Dictionary(grouping: versions) { Calendar.current.startOfDay(for: $0.date) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value) }
    }

    private func row(_ version: History.Version) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(version.reason)
                    .lineLimit(1)
                Spacer()
                Text(version.date, format: .dateTime.hour().minute())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(models[version.url].map { Self.change(to: $0, from: open.model) } ?? "Can't be read")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .tag(Item.version(version))
    }

    /// Lists the versions, reading any not read yet.
    private func load() {
        versions = open.history.versions
        for version in versions where models[version.url] == nil {
            models[version.url] = try? DataModel(contentsOf: version.url)
        }
    }

    private func show(_ item: Item?) {
        guard case .version(let version) = item, let model = models[version.url] else { return preview = nil }
        preview = Preview(version: version, model: model)
    }

    private func restore(_ version: History.Version) {
        do {
            try open.restore(version)
            selection = .now
        } catch {
            Library.shared.failure = "Couldn't restore that version: \(error.localizedDescription)"
        }
    }

    /// What restoring `earlier` would do to `now`.
    static func change(to earlier: DataModel, from now: DataModel) -> String {
        guard earlier != now else { return "The same as now" }
        let current = Set(now.tables.map(\.id)), then = Set(earlier.tables.map(\.id))
        let back = earlier.tables.filter { !current.contains($0.id) }.map(\.name)
        let gone = now.tables.filter { !then.contains($0.id) }.map(\.name)
        let list = { (names: [String]) in names.count <= 2 ? names.formatted(.list(type: .and)) : "\(names.count) tables" }
        var parts: [String] = []
        if !back.isEmpty { parts.append("brings back " + list(back)) }
        if !gone.isEmpty { parts.append("removes " + list(gone)) }
        if parts.isEmpty { return earlier.arrangementless == now.arrangementless ? "Tables in other places" : "Different columns or keys" }
        return "Restoring " + parts.joined(separator: " and ")
    }

    static func title(of day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }
}

private extension DataModel {
    /// Without where things are: tables all at the origin, no zip ties.
    var arrangementless: DataModel {
        var model = self
        for index in model.tables.indices { model.tables[index].position = .zero }
        model.zipTies = []
        for index in model.relationships.indices { model.relationships[index].zipTies = [] }
        return model
    }
}

#if DEBUG
extension Notification.Name {
    /// Opens version history; `object` is the index of the version to select, or nil for "Now".
    static let pickVersion = Notification.Name("JoineryPickVersion")
}
#endif
