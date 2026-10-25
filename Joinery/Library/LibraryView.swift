import SwiftUI

/// The window: the library's schemas and collections in a sidebar, the selected schema's canvas beside it.
struct LibraryView: View {
    @Bindable var library: Library
    @State private var columns = NavigationSplitViewVisibility.all
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(library: library)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            if let open = library.open {
                SchemaEditor(open: open)
                    .id(open.url)
            } else {
                ContentUnavailableView {
                    Label("No Schema Selected", systemImage: "tablecells")
                } description: {
                    Text("Choose one in the sidebar, or start a new one.")
                } actions: {
                    Button("New Schema") { library.newSchema() }
                }
            }
        }
        // Undo belongs to the schema it was done in.
        .onChange(of: library.selection) { undoManager?.removeAllActions() }
        .alert("Something Went Wrong", isPresented: Binding { library.failure != nil } set: { if !$0 { library.failure = nil } }) {
            Button("OK") { library.failure = nil }
        } message: {
            Text(library.failure ?? "")
        }
        #if DEBUG
        .onAppear { if ProcessInfo.processInfo.environment["JOINERY_NO_SIDEBAR"] != nil { columns = .detailOnly } }
        #endif
    }
}

private struct Sidebar: View {
    @Bindable var library: Library
    /// The schema or collection being renamed in place.
    @State private var renaming: URL?
    @State private var collapsed: Set<URL> = []
    @State private var collectionToTrash: Library.Collection?

    var body: some View {
        List(selection: $library.selection) {
            Section {
                ForEach(library.schemas, id: \.self, content: row)
            } header: {
                Text("Schemas")
                    .dropDestination(for: URL.self) { urls, _ in drop(urls, into: nil) }
            }
            ForEach(library.collections) { collection in
                Section(isExpanded: Binding { !collapsed.contains(collection.url) } set: { isExpanded in
                    if isExpanded { collapsed.remove(collection.url) } else { collapsed.insert(collection.url) }
                }) {
                    ForEach(collection.schemas, id: \.self, content: row)
                    if collection.schemas.isEmpty {
                        Text("No Schemas").foregroundStyle(.tertiary).selectionDisabled()
                    }
                } header: {
                    header(collection)
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { if let selection = library.selection { library.trash(selection) } }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Schema", systemImage: "tablecells") { library.newSchema(in: selectedCollection) }
                    Button("New Collection", systemImage: "folder.badge.plus") { renaming = library.newCollection() }
                } label: {
                    Label("New", systemImage: "plus")
                } primaryAction: {
                    library.newSchema(in: selectedCollection)
                }
                .help("New schema; hold for a new collection")
            }
        }
        .confirmationDialog("Move “\(collectionToTrash?.name ?? "")” to the Trash?", isPresented: Binding {
            collectionToTrash != nil
        } set: { if !$0 { collectionToTrash = nil } }, presenting: collectionToTrash) { collection in
            Button("Move to Trash", role: .destructive) { library.trash(collection.url) }
        } message: { collection in
            Text("Its \(collection.schemas.count) schemas go with it. You can put them back from the Trash.")
        }
    }

    /// Where a new schema goes: the selected schema's collection.
    private var selectedCollection: URL? {
        library.selection.flatMap(library.collection(of:))
    }

    private func row(_ url: URL) -> some View {
        Group {
            if renaming == url {
                RenameField(name: Library.name(of: url)) { name in
                    renaming = nil
                    if let name { library.rename(url, to: name) }
                }
            } else {
                Label(Library.name(of: url), systemImage: "tablecells")
            }
        }
        .tag(url)
        .draggable(url)
        .contextMenu {
            Button("Rename", systemImage: "pencil") { renaming = url }
            Button("Duplicate", systemImage: "plus.square.on.square") { library.duplicate(url) }
            Menu("Move To", systemImage: "folder") {
                Button("Schemas") { library.move(url, to: nil) }
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

    private func header(_ collection: Library.Collection) -> some View {
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
        .dropDestination(for: URL.self) { urls, _ in drop(urls, into: collection.url) }
        .contextMenu {
            Button("New Schema", systemImage: "tablecells") { library.newSchema(in: collection.url) }
            Button("Rename", systemImage: "pencil") { renaming = collection.url }
            Button("Show in Finder", systemImage: "finder") { library.showInFinder(collection.url) }
            Divider()
            Button("Move to Trash", systemImage: "trash", role: .destructive) {
                if collection.schemas.isEmpty { library.trash(collection.url) } else { collectionToTrash = collection }
            }
        }
    }

    @discardableResult
    private func drop(_ urls: [URL], into collection: URL?) -> Bool {
        let schemas = urls.filter { $0.pathExtension == "joinery" }
        for url in schemas { library.move(url, to: collection) }
        return !schemas.isEmpty
    }
}

/// Edits a name in place, as Finder does: Return or clicking away keeps it, Escape cancels.
private struct RenameField: View {
    @State var name: String
    /// Called once, with the new name or nil if cancelled.
    let done: (String?) -> Void
    @FocusState private var isFocused: Bool
    @State private var isFinished = false

    var body: some View {
        TextField("Name", text: $name)
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onSubmit { finish(name) }
            .onExitCommand { finish(nil) }
            .onChange(of: isFocused) { if !isFocused { finish(name) } }
    }

    /// Escape is followed by losing focus; only the first counts.
    private func finish(_ result: String?) {
        guard !isFinished else { return }
        isFinished = true
        done(result)
    }
}

/// A schema's canvas and toolbar.
struct SchemaEditor: View {
    let open: OpenSchema
    @State private var canvas = CanvasController()
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let schema = Binding { open.schema } set: { open.change(to: $0) }
        CanvasView(schema: schema, canvas: canvas)
            // Under the toolbar, which floats over it, but not the sidebar, so fitting the schema fits what's visible.
            .ignoresSafeArea(edges: .top)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ZoomMenu(canvas: canvas, bounds: open.schema.bounds)
                }
                ToolbarItem(placement: .principal) {
                    Button("Table", systemImage: "tablecells") { canvas.addTable(to: &schema.wrappedValue) }
                        .help("Add a table (T)")
                }
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle(open.name)
            .onAppear { open.undoManager = undoManager }
            .onChange(of: undoManager) { open.undoManager = undoManager }
            .focusedSceneValue(\.canvasController, canvas)
            .focusedSceneValue(\.schema, schema)
            #if DEBUG
            .task { await DebugHooks.script(schema, canvas: canvas) }
            #endif
    }
}

private struct ZoomMenu: View {
    let canvas: CanvasController
    let bounds: CGRect?

    var body: some View {
        Menu(Self.percent(canvas.zoom)) {
            Button("Zoom In") { canvas.zoom(by: 1.25) }
            Button("Zoom Out") { canvas.zoom(by: 0.8) }
            Button("Zoom to Fit") { canvas.zoomToFit(bounds) }
            Divider()
            ForEach([0.5, 1, 2] as [CGFloat], id: \.self) { level in
                Button(Self.percent(level)) { canvas.zoom(by: level / canvas.zoom) }
            }
        }
        .monospacedDigit()
        .fixedSize()
        .help("Zoom")
    }

    private static func percent(_ zoom: CGFloat) -> String {
        Double(zoom).formatted(.percent.precision(.fractionLength(0)))
    }
}
