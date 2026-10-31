import SwiftUI

/// Home: the library, as Freeform shows its boards. All Models, Recents, Favorites and the collections in a sidebar on
/// the back panel, under the tabs; on a surface beside it the models in whichever is chosen, as a grid of previews or a
/// list, searchable by model or table name. Opening one opens a tab for it. The home button left of the tabs comes
/// back here.
struct LibraryBrowser: View {
    @Bindable var library: Library

    enum Scope: Hashable {
        case all, recents, favorites
        case collection(URL)
    }

    enum Layout: String {
        case grid, list
    }

    @State private var scope = Scope.all
    /// Dragged wider or narrower by the gap between it and the surface.
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 220
    @State private var widthAtDragStart: Double?
    static let sidebarWidths = 180.0...320.0
    @AppStorage("libraryLayout") private var layout = Layout.grid
    @State private var search = ""
    /// The model picked out with a click, to open with Return.
    @State private var highlighted: URL?
    /// The model or collection being renamed in place.
    @State private var renaming: URL?
    @State private var collectionToTrash: Library.Collection?
    @State private var previews = ModelPreviews()
    @State private var layouts = TextLayouts()
    @State private var showsJoin = false

    var body: some View {
        // The sidebar on the back panel itself, not a floating one over it, as the tabs are; the surface beside it.
        HStack(spacing: 0) {
            sidebar
                .padding(.leading, Panel.inset)
                .padding(.bottom, Panel.inset)
                .frame(width: sidebarWidth)
                .overlay(alignment: .trailing) { resizeHandle }
            VStack(spacing: 0) {
                controls
                content
            }
            .background(.background)
            .surface()
        }
        .confirmationDialog("Move “\(collectionToTrash?.name ?? "")” to the Trash?", isPresented: Binding {
            collectionToTrash != nil
        } set: { if !$0 { collectionToTrash = nil } }, presenting: collectionToTrash) { collection in
            Button("Move to Trash", role: .destructive) {
                if scope == .collection(collection.url) { scope = .all }
                library.trash(collection.url)
            }
        } message: { collection in
            Text("Its \(collection.models.count) data models go with it. You can put them back from the Trash.")
        }
        // A collection that's gone, renamed or trashed, can't stay chosen.
        .onChange(of: library.collections.map(\.url)) {
            if case .collection(let url) = scope, !library.collections.contains(where: { $0.url == url }) { scope = .all }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding { scope } set: { if let new = $0 { scope = new } }) {
            Section("Data Models") {
                smartRow(.all, "All Data Models", symbol: "square.grid.2x2.fill", color: .blue, count: library.allModels.count)
                smartRow(.recents, "Recents", symbol: "clock.fill", color: .orange, count: library.recents.count)
                smartRow(.favorites, "Favorites", symbol: "heart.fill", color: .red,
                         count: library.allModels.count { library.details[$0]?.isFavorite == true })
            }
            if !library.collections.isEmpty {
                Section("Collections") {
                    ForEach(library.collections) { collectionRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            Button("New Collection", systemImage: "folder.badge.plus") {
                if let url = library.newCollection() {
                    scope = .collection(url)
                    renaming = url
                }
            }
            .buttonStyle(.borderless)
            .help("New collection (⇧⌘N)")
            .padding(12)
        }
    }

    /// Along the surface's top, at the trailing end, as Freeform's toolbar has them.
    /// In glass, as the canvas's controls are, and as far in from the surface's corner, so its corners are
    /// concentric with theirs.
    private var controls: some View {
        HStack(spacing: 8) {
            Spacer()
            ControlGroupGlass {
                Button("Join", systemImage: "person.2.badge.plus") { showsJoin.toggle() }
                    .help("Join a data model someone is sharing, from their link")
                    .popover(isPresented: $showsJoin, arrowEdge: .bottom) { JoinPanel() }
                Button("New Data Model", systemImage: "square.and.pencil") { library.newModel(in: selectedCollection) }
                    .help("New data model (⌘N)")
            }
            ControlGroupGlass {
                layoutToggle(.grid, "Grid", systemImage: "square.grid.2x2")
                layoutToggle(.list, "List", systemImage: "list.bullet")
            }
            .help("Show as a grid or a list")
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
            .frame(width: 240, height: Panel.controlHeight)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(Panel.controlInset)
    }

    /// One of the grid and list buttons: on while it's the layout shown.
    private func layoutToggle(_ shown: Layout, _ title: String, systemImage: String) -> some View {
        Toggle(title, systemImage: systemImage, isOn: Binding { layout == shown } set: { if $0 { layout = shown } })
    }

    /// The gap between the sidebar and the surface: drag it to make the sidebar wider or narrower.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: Panel.inset)
            .contentShape(.rect)
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(coordinateSpace: .global).onChanged { drag in
                let start = widthAtDragStart ?? sidebarWidth
                widthAtDragStart = start
                sidebarWidth = min(max(start + drag.translation.width, Self.sidebarWidths.lowerBound), Self.sidebarWidths.upperBound)
            }.onEnded { _ in widthAtDragStart = nil })
            .offset(x: Panel.inset)
    }

    private func smartRow(_ scope: Scope, _ title: String, symbol: String, color: Color, count: Int) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(color.gradient, in: .circle)
        }
        .badge(count)
        .tag(scope)
    }

    private func collectionRow(_ collection: Library.Collection) -> some View {
        Group {
            if renaming == collection.url {
                RenameField(name: collection.name) { name in
                    renaming = nil
                    if let name {
                        let renamed = collection.url.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
                        library.rename(collection.url, to: name)
                        if scope == .collection(collection.url) { scope = .collection(renamed) }
                    }
                }
            } else {
                Label(collection.name, systemImage: collection.name == Library.examplesName ? "books.vertical" : "folder")
                    .badge(collection.models.count)
            }
        }
        .tag(Scope.collection(collection.url))
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

    // MARK: Models

    private var title: String {
        switch scope {
        case .all: "All Data Models"
        case .recents: "Recents"
        case .favorites: "Favorites"
        case .collection(let url): url.lastPathComponent
        }
    }

    /// What's in the chosen group, and matches the search: most recently changed first, or for Recents, used.
    private var shown: [URL] {
        let models: [URL] = switch scope {
        case .all: library.allModels.sorted { modified($0) > modified($1) }
        case .recents: library.recents
        case .favorites: library.allModels.filter { library.details[$0]?.isFavorite == true }.sorted { modified($0) > modified($1) }
        case .collection(let url): (library.collections.first { $0.url == url }?.models ?? []).sorted { modified($0) > modified($1) }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return models }
        // By name, or the name of a table in it.
        return models.filter { url in
            Library.name(of: url).localizedStandardContains(query)
                || preview(of: url)?.model.tables.contains { $0.name.localizedStandardContains(query) } == true
        }
    }

    private func modified(_ url: URL) -> Date { library.details[url]?.modified ?? .distantPast }

    private func preview(of url: URL) -> ModelPreviews.Preview? {
        previews.preview(of: url, modified: modified(url))
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.tint)
            Text(count == 1 ? "1 Data Model" : "\(count) Data Models")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var content: some View {
        let shown = shown
        return Group {
            if shown.isEmpty {
                VStack(spacing: 0) {
                    header(count: 0)
                    emptyState
                        .frame(maxHeight: .infinity)
                }
            } else if layout == .grid {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(count: shown.count)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 196, maximum: 240), spacing: 20, alignment: .top)],
                                  alignment: .leading, spacing: 20) {
                            ForEach(shown, id: \.self) { card($0) }
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 20)
                    }
                }
                // A click on the background lets go of the highlighted model.
                .background { Color.clear.contentShape(.rect).onTapGesture { highlighted = nil } }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    header(count: shown.count)
                    list(shown)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard let highlighted else { return .ignored }
            library.selection = highlighted
            return .handled
        }
        .onDeleteCommand { if let highlighted { library.trash(highlighted) } }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .showJoin)) { _ in showsJoin = true }
        #endif
    }

    /// Where a new model goes: the collection being shown.
    private var selectedCollection: URL? {
        if case .collection(let url) = scope { url } else { nil }
    }

    @ViewBuilder
    private var emptyState: some View {
        Group {
            if !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                switch scope {
                case .favorites:
                    ContentUnavailableView("No Favorites", systemImage: "heart",
                                           description: Text("Right-click a data model and choose Add to Favorites."))
                case .recents:
                    ContentUnavailableView("No Recent Data Models", systemImage: "clock",
                                           description: Text("Data models you open or change show up here for a month."))
                default:
                    ContentUnavailableView {
                        Label("No Data Models", systemImage: "tablecells")
                    } description: {
                        Text("Start one, or drag data models here from another collection.")
                    } actions: {
                        Button("New Data Model") { library.newModel(in: selectedCollection) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func card(_ url: URL) -> some View {
        ModelCard(name: Library.name(of: url), date: modified(url), isFavorite: library.details[url]?.isFavorite == true,
                   isHighlighted: highlighted == url, preview: preview(of: url), layouts: layouts,
                   isRenaming: renaming == url) { name in
            renaming = nil
            if let name { library.rename(url, to: name) }
        }
        .gesture(TapGesture(count: 2).onEnded { library.selection = url })
        .simultaneousGesture(TapGesture().onEnded { highlighted = url })
        .draggable(url)
        .contextMenu { menu(for: url) }
    }

    private func list(_ shown: [URL]) -> some View {
        SwiftUI.Table(shown.map(Row.init), selection: $highlighted) {
            TableColumn("Name") { row in
                if renaming == row.url {
                    RenameField(name: Library.name(of: row.url)) { name in
                        renaming = nil
                        if let name { library.rename(row.url, to: name) }
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "tablecells").foregroundStyle(.secondary)
                        Text(Library.name(of: row.url))
                        if library.details[row.url]?.isFavorite == true {
                            Image(systemName: "heart.fill").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            TableColumn("Tables") { row in
                Text(preview(of: row.url).map { "\($0.model.tables.count)" } ?? "—").monospacedDigit()
            }
            .width(min: 50, ideal: 60, max: 80)
            TableColumn("Collection") { row in
                Text(library.collection(of: row.url)?.lastPathComponent ?? "—").foregroundStyle(.secondary)
            }
            TableColumn("Date Modified") { row in
                Text(ModelCard.describe(modified(row.url))).foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first { menu(for: url) }
        } primaryAction: { urls in
            if let url = urls.first { library.selection = url }
        }
    }

    private struct Row: Identifiable {
        let url: URL
        var id: URL { url }
    }

    @ViewBuilder
    private func menu(for url: URL) -> some View {
        let isFavorite = library.details[url]?.isFavorite == true
        Button("Open", systemImage: "arrow.up.forward.app") { library.selection = url }
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
}

/// A model in the grid: a picture of it, its name and when it last changed.
private struct ModelCard: View {
    let name: String
    let date: Date
    let isFavorite: Bool
    let isHighlighted: Bool
    let preview: ModelPreviews.Preview?
    let layouts: TextLayouts
    let isRenaming: Bool
    let rename: (String?) -> Void

    @State private var isHovered = false

    private static let cornerRadius: CGFloat = 12
    /// Between the card and its highlight ring; the ring's radius is the card's plus this and its width, so they're
    /// concentric.
    private static let ringGap: CGFloat = 3
    private static let ringWidth: CGFloat = 3

    var body: some View {
        VStack(spacing: 0) {
            ModelThumbnail(preview: preview, layouts: layouts)
                .frame(height: 128)
                .background(Theme.canvas)
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    RenameField(name: name, done: rename)
                } else {
                    HStack(spacing: 4) {
                        Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if isFavorite { Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(.red) }
                    }
                }
                Text(Self.describe(date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
            .background(Color.primary.opacity(isHovered ? 0.11 : 0.08))
        }
        .clipShape(.rect(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(Theme.cardBorder, lineWidth: 1)
        }
        .overlay {
            if isHighlighted {
                let outset = Self.ringGap + Self.ringWidth
                RoundedRectangle(cornerRadius: Self.cornerRadius + outset)
                    .strokeBorder(Color.accentColor, lineWidth: Self.ringWidth)
                    .padding(-outset)
            }
        }
        .contentShape(.rect(cornerRadius: Self.cornerRadius))
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
