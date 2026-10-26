import SwiftUI

/// The window: the library's browser, or when a model is open, its canvas, with a way back.
struct LibraryView: View {
    @Bindable var library: Library
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let open = library.open {
                ModelEditor(open: open) { library.selection = nil }
                    .id(open.url)
            } else {
                LibraryBrowser(library: library)
            }
        }
        // Undo belongs to the model it was done in.
        .onChange(of: library.selection) { undoManager?.removeAllActions() }
        .alert("Something Went Wrong", isPresented: Binding { library.failure != nil } set: { if !$0 { library.failure = nil } }) {
            Button("OK") { library.failure = nil }
        } message: {
            Text(library.failure ?? "")
        }
    }
}

/// Edits a name in place, as Finder does: Return or clicking away keeps it, Escape cancels.
struct RenameField: View {
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

/// A model's canvas and toolbar.
struct ModelEditor: View {
    let open: OpenModel
    /// Back to the library.
    let close: () -> Void
    @State private var canvas = CanvasController()
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let model = Binding { open.model } set: { open.change(to: $0) }
        CanvasView(model: model, canvas: canvas)
            // Under the toolbar, which floats over it, but not the sidebar, so fitting the model fits what's visible.
            .ignoresSafeArea(edges: .top)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("All Data Models", systemImage: "chevron.left", action: close)
                        .keyboardShortcut(.upArrow, modifiers: .command)
                        .help("Back to all data models (⌘↑)")
                }
                ToolbarItem(placement: .navigation) {
                    ZoomMenu(canvas: canvas, bounds: open.model.bounds)
                }
                ToolbarItemGroup(placement: .principal) {
                    Button("Table", systemImage: "tablecells") { canvas.addTable(to: &model.wrappedValue) }
                        .help("Add a table (T)")
                    Toggle("Zip Tie", systemImage: "arrow.triangle.merge", isOn: Bindable(canvas).isTying)
                        .help("Zip-tie tool: drag across wires to tie them (Z)")
                }
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .navigationTitle(open.name)
            .onAppear { open.undoManager = undoManager }
            .onChange(of: undoManager) { open.undoManager = undoManager }
            .focusedSceneValue(\.canvasController, canvas)
            .focusedSceneValue(\.model, model)
            #if DEBUG
            .task { await DebugHooks.script(model, canvas: canvas) }
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
