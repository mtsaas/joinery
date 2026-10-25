import SwiftUI

/// The Insert menu and the View menu's zoom items, acting on the frontmost document.
struct CanvasCommands: Commands {
    @FocusedValue(\.canvasController) private var canvas
    @FocusedBinding(\.schema) private var schema

    var body: some Commands {
        CommandMenu("Insert") {
            Button("Table") {
                guard let canvas, var updated = schema else { return }
                canvas.addTable(to: &updated)
                schema = updated
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(canvas == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { canvas?.zoom(by: 1.25) }
                .keyboardShortcut("+")
            Button("Zoom Out") { canvas?.zoom(by: 0.8) }
                .keyboardShortcut("-")
            Button("Actual Size") { canvas.map { $0.zoom(by: 1 / $0.zoom) } }
                .keyboardShortcut("0")
            Button("Zoom to Fit") { canvas?.zoomToFit(schema?.bounds) }
                .keyboardShortcut("1")
            Divider()
        }
    }
}
