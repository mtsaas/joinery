import SwiftUI

/// The library, as a panel that slides in from the surface's left edge over what's there: search, then Recents,
/// Favorites, the data models in no collection, and each collection's. Choosing one opens it in a tab and puts the
/// panel away. It isn't a page of its own: with nothing open, it stays out beside an empty surface.
struct LibraryPanel: View {
    @Bindable var library: Library

    @State private var search = ""
    /// The model or collection being renamed in place.
    @State private var renaming: URL?
    @State private var collectionToTrash: Library.Collection?
    /// Collections folded away.
    @State private var folded: Set<URL> = []
    @State private var previews = ModelPreviews()
    @State private var showsJoin = false

    static let width: CGFloat = 320
    /// How many recent models it lists.
    static let recentCount = 5

    var body: some View {
        VStack(spacing: 0) {
            controls
            List {
                if !query.isEmpty {
                    let found = library.allModels.filter(matches).sorted { modified($0) > modified($1) }
                    Section("Results") {
                        if found.isEmpty { Text("No data models match “\(query)”.").foregroundStyle(.secondary) }
                        ForEach(found, id: \.self, content: row)
                    }
                } else {
                    let recents = Array(library.recents.prefix(Self.recentCount))
                    if !recents.isEmpty {
                        Section("Recents") { ForEach(recents, id: \.self, content: row) }
                    }
                    let favorites = library.allModels.filter { library.details[$0]?.isFavorite == true }.sorted { modified($0) > modified($1) }
                    if !favorites.isEmpty {
                        Section("Favorites") { ForEach(favorites, id: \.self, content: row) }
                    }
                    Section {
                        ForEach(library.models.sorted { modified($0) > modified($1) }, id: \.self, content: row)
                    } header: {
                        Text("Data Models")
                            .dropDestination(for: URL.self) { urls, _ in move(urls, into: nil) }
                    }
                    ForEach(library.collections) { collection in
                        Section(isExpanded: Binding { !folded.contains(collection.url) } set: { isExpanded in
                            if isExpanded { folded.remove(collection.url) } else { folded.insert(collection.url) }
                        }) {
                            ForEach(collection.models.sorted { modified($0) > modified($1) }, id: \.self, content: row)
                        } header: {
                            collectionHeader(collection)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            HStack {
                Button("New Collection", systemImage: "folder.badge.plus") {
                    if let url = library.newCollection() { renaming = url }
                }
                .help("New collection (⇧⌘N)")
                Spacer()
                Button("Add Examples", systemImage: "books.vertical") { try? library.addExamples() }
                    .labelStyle(.iconOnly)
                    .help("Add the example data models")
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
        .frame(width: Self.width)
        .confirmationDialog("Move “\(collectionToTrash?.name ?? "")” to the Trash?", isPresented: Binding {
            collectionToTrash != nil
        } set: { if !$0 { collectionToTrash = nil } }, presenting: collectionToTrash) { collection in
            Button("Move to Trash", role: .destructive) { library.trash(collection.url) }
        } message: { collection in
            Text("Its \(collection.models.count) data models go with it. You can put them back from the Trash.")
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .showJoin)) { _ in showsJoin = true }
        #endif
    }

    /// Search, and starting or joining a model, in glass along the top, where the canvas's first controls are, so
    /// they're concentric with the surface's corner as those are.
    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: Panel.controlHeight)
            .glassEffect(.regular, in: .capsule)
            ControlGroupGlass {
                Button("Join", systemImage: "person.2.badge.plus") { showsJoin.toggle() }
                    .help("Join a data model someone is sharing, from their link")
                    .popover(isPresented: $showsJoin, arrowEdge: .bottom) { JoinPanel() }
                Button("New Data Model", systemImage: "square.and.pencil") { library.newModel() }
                    .help("New data model, in a tab (⌘N)")
            }
        }
        .padding(Panel.controlInset)
    }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    /// By name, or the name of a table in it.
    private func matches(_ url: URL) -> Bool {
        Library.name(of: url).localizedStandardContains(query)
            || previews.preview(of: url, modified: modified(url))?.model.tables.contains { $0.name.localizedStandardContains(query) } == true
    }

    private func modified(_ url: URL) -> Date { library.details[url]?.modified ?? .distantPast }

    /// A model: its miniature, name and when it changed. A click opens it.
    private func row(_ url: URL) -> some View {
        HStack(spacing: 8) {
            ModelIcon(model: previews.preview(of: url, modified: modified(url))?.model)
            VStack(alignment: .leading, spacing: 1) {
                if renaming == url {
                    RenameField(name: Library.name(of: url)) { name in
                        renaming = nil
                        if let name { library.rename(url, to: name) }
                    }
                } else {
                    HStack(spacing: 4) {
                        Text(Library.name(of: url)).lineLimit(1)
                        if library.details[url]?.isFavorite == true {
                            Image(systemName: "heart.fill").font(.system(size: 8)).foregroundStyle(.red)
                        }
                    }
                }
                Text(Self.describe(modified(url))).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Open in a tab already.
            if library.tabs.contains(where: { $0.url == url }) {
                Circle().fill(.secondary).frame(width: 5, height: 5)
            }
        }
        .contentShape(.rect)
        .onTapGesture { open(url) }
        .draggable(url)
        .contextMenu { menu(for: url) }
    }

    private func open(_ url: URL) {
        library.selection = url
        withAnimation(.smooth(duration: 0.25)) { library.showsLibrary = false }
    }

    private func collectionHeader(_ collection: Library.Collection) -> some View {
        Group {
            if renaming == collection.url {
                RenameField(name: collection.name) { name in
                    renaming = nil
                    if let name { library.rename(collection.url, to: name) }
                }
            } else {
                Label(collection.name, systemImage: collection.name == Library.examplesName ? "books.vertical" : "folder")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in move(urls, into: collection.url) }
        .contextMenu {
            Button("New Data Model", systemImage: "square.and.pencil") { library.newModel(in: collection.url) }
            Button("Rename", systemImage: "pencil") { renaming = collection.url }
            Button("Show in Finder", systemImage: "finder") { library.showInFinder(collection.url) }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                if collection.models.isEmpty { library.trash(collection.url) } else { collectionToTrash = collection }
            }
        }
    }

    @discardableResult
    private func move(_ urls: [URL], into collection: URL?) -> Bool {
        let models = urls.filter { $0.pathExtension == "joinery" }
        for url in models { library.move(url, to: collection) }
        return !models.isEmpty
    }

    @ViewBuilder
    private func menu(for url: URL) -> some View {
        let isFavorite = library.details[url]?.isFavorite == true
        Button("Open", systemImage: "arrow.up.forward.app") { open(url) }
        Divider()
        Button(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "heart.slash" : "heart") {
            library.setFavorite(url, !isFavorite)
        }
        Button("Rename", systemImage: "pencil") { renaming = url }
        Button("Duplicate", systemImage: "plus.square.on.square") { library.duplicate(url) }
        Menu("Move To", systemImage: "folder") {
            Button("No Collection") { library.move(url, to: nil) }
                .disabled(library.collection(of: url) == nil)
            Divider()
            ForEach(library.collections) { collection in
                Button(collection.name) { library.move(url, to: collection.url) }
                    .disabled(library.collection(of: url) == collection.url)
            }
        }
        Button("Show in Finder", systemImage: "finder") { library.showInFinder(url) }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { library.trash(url) }
    }

    /// "Today, 7:31 AM", "Yesterday, 4:02 PM", or the date.
    static func describe(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today, \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// A model in miniature: its tables and wires, drawn as on the canvas, fitted to the space, or as a canvas `view` shows
/// them, scaled down.
struct ModelThumbnail: View {
    let preview: ModelPreviews.Preview?
    let layouts: TextLayouts
    /// A canvas's zoom, scroll and size, to show what it does; the whole model, fitted, without.
    var view: (zoom: CGFloat, offset: CGPoint, size: CGSize)? = nil

    var body: some View {
        GeometryReader { geometry in
            if let preview, let (zoom, offset) = placement(of: preview, in: geometry.size) {
                ZStack {
                    GroupLayer(groups: preview.model.groups.compactMap { group in preview.model.frame(of: group.id).map { (group, $0) } },
                               zoom: zoom, viewOffset: offset, selected: [])
                    Canvas { context, _ in
                        context.translateBy(x: offset.x, y: offset.y)
                        context.scaleBy(x: zoom, y: zoom)
                        for wire in preview.wires {
                            context.stroke(wire.path, with: .color(wire.color), lineWidth: 1.25 / zoom)
                        }
                    }
                    TableLayer(tables: preview.model.tables, offsets: [:], zoom: zoom, viewOffset: offset, viewSize: geometry.size,
                               selected: [], cursor: nil, targetColumn: nil, foreignKeys: preview.foreignKeys, socketColors: [:],
                               hoveredSocket: nil, layouts: layouts)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func placement(of preview: ModelPreviews.Preview, in size: CGSize) -> (zoom: CGFloat, offset: CGPoint)? {
        if let view, view.size.width > 0, view.size.height > 0 {
            // Filling the space, centered, cutting off what's over at the sides or top and bottom.
            let scale = max(size.width / view.size.width, size.height / view.size.height)
            return (view.zoom * scale, CGPoint(x: view.offset.x * scale + (size.width - view.size.width * scale) / 2,
                                               y: view.offset.y * scale + (size.height - view.size.height * scale) / 2))
        }
        guard let bounds = preview.bounds else { return nil }
        let inset: CGFloat = 14
        let zoom = min((size.width - inset * 2) / bounds.width, (size.height - inset * 2) / bounds.height, 0.6)
        return (zoom, CGPoint(x: size.width / 2 - bounds.midX * zoom, y: size.height / 2 - bounds.midY * zoom))
    }
}

/// Each model read and routed once for its preview, again only when its file changes.
@MainActor
final class ModelPreviews {
    struct Preview {
        let model: DataModel
        let wires: [(path: Path, color: Color)]
        let foreignKeys: [Column.ID: Color]
        let bounds: CGRect?
    }

    private var previews: [URL: (modified: Date, preview: Preview?)] = [:]

    func preview(of url: URL, modified: Date) -> Preview? {
        if let cached = previews[url], cached.modified == modified { return cached.preview }
        let preview = (try? DataModel(contentsOf: url)).map(Self.make)
        previews[url] = (modified, preview)
        return preview
    }

    /// A model's preview, routed afresh.
    static func make(_ model: DataModel) -> Preview {
        let routing = Routing(model: model)
        let locations = model.columnLocations
        let colors = Dictionary(model.relationships.compactMap { r in locations[r.to].map { (r.id, $0.table.color.color) } },
                                uniquingKeysWith: { first, _ in first })
        return Preview(
            model: model,
            wires: model.relationships.compactMap { r in
                routing.routes[r.id].map { (Path(smoothing: $0.points), colors[r.id] ?? .gray) }
            },
            foreignKeys: Dictionary(model.relationships.compactMap { r in colors[r.id].map { (r.from, $0) } },
                                    uniquingKeysWith: { first, _ in first }),
            bounds: model.bounds)
    }
}
