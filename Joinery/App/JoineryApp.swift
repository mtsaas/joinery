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

/// A document's window: the canvas and its toolbar.
struct SchemaWindow: View {
    @Binding var document: SchemaDocument
    @State private var canvas = CanvasController()

    var body: some View {
        CanvasView(schema: $document.schema, canvas: canvas)
            .ignoresSafeArea()
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ZoomMenu(canvas: canvas, bounds: document.schema.bounds)
                }
                ToolbarItem(placement: .principal) {
                    Button("Table", systemImage: "tablecells") { canvas.addTable(to: &document.schema) }
                        .help("Add a table (T)")
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
