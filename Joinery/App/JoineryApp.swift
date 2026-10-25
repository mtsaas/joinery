import SwiftUI

@main
struct JoineryApp: App {
    #if DEBUG
    @NSApplicationDelegateAdaptor private var debugHooks: DebugHooks
    #endif

    var body: some Scene {
        DocumentGroup(newDocument: SchemaDocument()) { file in
            SchemaWindow(document: file.$document)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { CanvasCommands() }
    }
}

/// A document's window: the canvas, its toolbar, and the inspector.
struct SchemaWindow: View {
    @Binding var document: SchemaDocument
    @State private var canvas = CanvasController()

    var body: some View {
        CanvasView(schema: $document.schema, canvas: canvas)
            .ignoresSafeArea()
            .inspector(isPresented: $canvas.showsInspector) {
                InspectorView(schema: $document.schema, canvas: canvas)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ZoomMenu(canvas: canvas, bounds: document.schema.bounds)
                }
                ToolbarItemGroup(placement: .principal) {
                    Button("Table", systemImage: "tablecells") { canvas.addTable(to: &document.schema) }
                        .help("Add a table (⌥⌘T)")
                    Toggle("Zip Tie", systemImage: "arrow.triangle.merge", isOn: Binding {
                        canvas.tool == .zipTie
                    } set: {
                        canvas.tool = $0 ? .zipTie : .select
                    })
                    .help("Draw a line across wires to tie them together. Hold Option to do this without the tool.")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Inspector", systemImage: "sidebar.trailing") { canvas.showsInspector.toggle() }
                        .help("Show or hide the inspector")
                }
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .focusedSceneValue(\.canvasController, canvas)
            .focusedSceneValue(\.schema, $document.schema)
            #if DEBUG
            .task { await DebugHooks.script($document.schema, canvas: canvas) }
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
