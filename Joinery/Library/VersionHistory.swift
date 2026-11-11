import SwiftUI

/// The open model's earlier versions, in a popover, as a git-style graph: each branch a lane, newest first, from where
/// it started on another. Step through them with the arrow keys and each shows on the canvas, read-only, until one is
/// restored or checked out, or "Now" is chosen again.
struct VersionHistory: View {
    let open: OpenModel
    /// The version the canvas shows instead of the model, if any.
    @Binding var preview: Preview?

    struct Preview: Equatable {
        let version: History.Version
        var model: DataModel
        /// A review's: how it was before the change `model` is after. Shown as that change, not compared with now.
        var before: DataModel?
    }

    private enum Item: Hashable {
        case now
        /// A named version, compared with now.
        case named(String)
        case version(History.Version)
    }

    @State private var graph = Graph(branches: Branches(), versions: [:])
    /// Versions read so far, and reviews' befores; they never change.
    @State private var models: [URL: DataModel] = [:]
    @State private var befores: [URL: DataModel] = [:]
    @State private var selection: Item? = .now
    /// Naming a branch to start from the selection.
    @State private var newBranch: String?
    @FocusState private var isFocused: Bool

    private var versions: [History.Version] { graph.rows.compactMap(\.version) }

    var body: some View {
        List(selection: $selection) {
            if !open.named.versions.isEmpty {
                Section("Named") {
                    ForEach(open.named.versions.reversed(), id: \.name) { version in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(version.name).lineLimit(1)
                                Spacer()
                                Text(version.date, format: .dateTime.month().day().hour().minute())
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Text("To now: " + SchemaDiff(from: version.model, to: open.model).summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                        .tag(Item.named(version.name))
                    }
                }
            }
            Section(open.named.versions.isEmpty ? "" : "History") {
                ForEach(graph.rows.indices, id: \.self) { index in
                    row(index)
                        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                        .listRowSeparator(.hidden)
                        .tag(graph.rows[index].version.map(Item.version) ?? .now)
                }
            }
        }
        .environment(\.defaultMinListRowHeight, 1)
        .focused($isFocused)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .onAppear {
            load()
            // Still showing a version from before it closed: that one's selected.
            if let preview { selection = .version(preview.version) }
            isFocused = true
        }
        .onChange(of: open.model) { load() }
        .onChange(of: open.branches) { load() }
        .onChange(of: selection) {
            newBranch = nil
            show(selection)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .pickVersion)) { note in
            guard let index = note.object as? Int else { return }
            selection = versions.indices.contains(index) ? .version(versions[index]) : .now
        }
        #endif
    }

    private var selectedRow: Graph.Row? {
        switch selection {
        case .now: graph.rows.first
        case .version(let version): graph.rows.first { $0.version == version }
        default: nil
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let name = newBranch {
                HStack {
                    TextField("Branch name", text: Binding { name } set: { newBranch = $0 })
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(startBranch)
                    Button("Cancel") { newBranch = nil }
                    Button("Start", action: startBranch)
                        .keyboardShortcut(.defaultAction)
                        .disabled(Branches.clean(name).isEmpty)
                }
            } else if let row = selectedRow {
                if let version = row.version {
                    if row.isTip, row.branch != open.branches.head {
                        Button { checkOut(row.branch) } label: {
                            Text("Check Out “\(row.branch)”").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button { restore(version) } label: {
                            Text("Restore This Version").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                Button { newBranch = "" } label: {
                    Text(row.version == nil ? "New Branch…" : "New Branch from Here…").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private static let rowHeight: CGFloat = 40

    private func row(_ index: Int) -> some View {
        let row = graph.rows[index]
        return HStack(spacing: 8) {
            GraphCell(graph: graph, index: index)
                .frame(width: CGFloat(graph.lanes) * GraphCell.laneWidth)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.version?.reason ?? "Now")
                        .lineLimit(1)
                    if row.isTip {
                        Text(row.branch)
                            .font(.caption.weight(row.branch == open.branches.head ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .background(GraphCell.color(row.lane).opacity(0.25), in: .capsule)
                    }
                    Spacer(minLength: 0)
                    if let date = row.version?.date {
                        Text(date, format: Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Text(summary(of: row.version))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(height: Self.rowHeight)
    }

    private func summary(of version: History.Version?) -> String {
        guard let version else { return "As it is, to edit" }
        guard let model = models[version.url] else { return "Can't be read" }
        return befores[version.url].map { "Review: " + SchemaDiff(from: $0, to: model).summary } ?? Self.change(to: model, from: open.model)
    }

    /// Lists every branch's versions, reading any not read yet.
    private func load() {
        let versions = Dictionary(uniqueKeysWithValues: open.branches.names.map { ($0, open.history(of: $0).versions) })
        for version in versions.values.joined() where models[version.url] == nil {
            models[version.url] = try? DataModel(contentsOf: version.url)
            if version.isReview { befores[version.url] = try? DataModel(contentsOf: version.beforeURL) }
        }
        graph = Graph(branches: open.branches, versions: versions)
    }

    private func startBranch() {
        guard let name = newBranch, !Branches.clean(name).isEmpty, let row = selectedRow else { return }
        do {
            try open.startBranch(name, from: row.version, of: row.branch)
            newBranch = nil
            preview = nil
            selection = .now
        } catch {
            Library.shared.failure = "Couldn't start that branch: \(error.localizedDescription)"
        }
    }

    private func checkOut(_ branch: String) {
        do {
            try open.checkOut(branch)
            preview = nil
            selection = .now
        } catch {
            Library.shared.failure = "Couldn't switch to “\(branch)”: \(error.localizedDescription)"
        }
    }

    private func show(_ item: Item?) {
        if case .named(let name) = item {
            preview = nil
            return open.compare(NamedVersions.Comparison(from: name, to: NamedVersions.current))
        }
        // Read afresh: it may have been laid out since.
        guard case .version(let version) = item, let model = try? DataModel(contentsOf: version.url) else { return preview = nil }
        preview = Preview(version: version, model: model, before: version.isReview ? try? DataModel(contentsOf: version.beforeURL) : nil)
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

/// Every branch's versions as a git-style graph, newest first, with "Now" on top on the branch checked out. Each branch
/// has a lane, joined at its oldest end to the version of its parent's it was started from.
struct Graph: Equatable {
    struct Row: Equatable {
        /// Nil for now.
        var version: History.Version?
        var branch: String
        var lane: Int
        /// The branch's newest, labeled with its name: "Now" for the one checked out.
        var isTip = false
    }

    /// A branch's line down its lane, from row `top` to row `bottom`. It bends in from `from`'s lane at `bottom`, the
    /// version it was started from; `main`'s has none, and stops at its oldest.
    struct Line: Equatable {
        var lane: Int
        var top: Int
        var bottom: Int
        var from: Int?
    }

    private(set) var rows: [Row] = []
    private(set) var lines: [Line] = []
    private(set) var lanes = 1

    /// From each branch's versions, newest first.
    // ponytail: a lane per branch, never reused; reuse finished lanes if models gather many branches.
    init(branches: Branches, versions: [String: [History.Version]]) {
        let names = branches.names
        let lane = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        lanes = names.count
        rows = [Row(version: nil, branch: branches.head, lane: lane[branches.head] ?? 0)]
            + names.flatMap { name in versions[name, default: []].map { Row(version: $0, branch: name, lane: lane[name]!) } }
                .sorted { $0.version!.date > $1.version!.date }
        for name in names {
            let own = rows.indices.filter { rows[$0].branch == name }
            guard let top = own.first, let last = own.last else { continue }
            rows[top].isTip = true
            guard let branch = branches.others.first(where: { $0.name == name }) else {
                lines.append(Line(lane: lane[name]!, top: top, bottom: last))
                continue
            }
            // The version it started from, or the nearest older one left if that's been thinned out.
            let parent = rows.indices.filter { rows[$0].branch == branch.parent && rows[$0].version != nil }
            let fork = parent.first { rows[$0].version!.date <= branch.forked.addingTimeInterval(0.0005) } ?? parent.last
            if let fork, fork > last {
                lines.append(Line(lane: lane[name]!, top: top, bottom: fork, from: lane[branch.parent]))
            } else {
                lines.append(Line(lane: lane[name]!, top: top, bottom: last))
            }
        }
    }
}

/// One row's part of the graph: the lines passing through it, and its version's dot.
private struct GraphCell: View {
    let graph: Graph
    let index: Int

    static let laneWidth: CGFloat = 14
    private static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red, .indigo, .mint]
    static func color(_ lane: Int) -> Color { colors[lane % colors.count] }

    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            func x(_ lane: Int) -> CGFloat { (CGFloat(lane) + 0.5) * Self.laneWidth }
            for line in graph.lines where line.top < line.bottom && (line.top...line.bottom).contains(index) {
                var path = Path()
                if index == line.bottom, let from = line.from {
                    path.move(to: CGPoint(x: x(from), y: mid))
                    path.addCurve(to: CGPoint(x: x(line.lane), y: 0), control1: CGPoint(x: x(line.lane), y: mid),
                                  control2: CGPoint(x: x(line.lane), y: mid))
                } else {
                    path.move(to: CGPoint(x: x(line.lane), y: index == line.top ? mid : 0))
                    path.addLine(to: CGPoint(x: x(line.lane), y: index == line.bottom ? mid : size.height))
                }
                context.stroke(path, with: .color(Self.color(line.lane)), lineWidth: 2)
            }
            let row = graph.rows[index]
            let dot = Path(ellipseIn: CGRect(x: x(row.lane) - 4, y: mid - 4, width: 8, height: 8))
            if row.version == nil {
                context.fill(dot, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(dot, with: .color(Self.color(row.lane)), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(Self.color(row.lane)))
            }
        }
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
