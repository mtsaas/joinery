import SwiftUI

/// The Insert menu and the View menu's zoom items, acting on the frontmost document.
struct CanvasCommands: Commands {
    @FocusedValue(\.canvasController) private var canvas
    @FocusedBinding(\.model) private var model
    @AppStorage("wiresAvoidTables") private var wiresAvoidTables = false

    var body: some Commands {
        CommandMenu("Insert") {
            Button("Table") {
                guard let canvas, var updated = model else { return }
                canvas.addTable(to: &updated)
                model = updated
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(canvas == nil)
        }
        #if DEBUG
        CommandMenu("Debug") {
            Toggle("Routing Feedback Mode", isOn: Binding { canvas?.isFeedbackMode ?? false } set: { isOn in
                canvas?.isFeedbackMode = isOn
                if !isOn { canvas?.feedback = nil }
            })
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(canvas == nil)
            Button("Export Routing Feedback…") { RoutingFeedback.export() }
            Button("Show Routing Feedback in Finder") { NSWorkspace.shared.activateFileViewerSelecting([RoutingFeedback.folder]) }
        }
        #endif
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") { canvas?.togglePalette() }
                .keyboardShortcut("k")
                .disabled(canvas == nil)
            Toggle("Wires Avoid Tables", isOn: $wiresAvoidTables)
            Divider()
            Button("Zoom In") { canvas?.zoom(by: 1.25) }
                .keyboardShortcut("+")
            Button("Zoom Out") { canvas?.zoom(by: 0.8) }
                .keyboardShortcut("-")
            Button("Actual Size") { canvas.map { $0.zoom(by: 1 / $0.zoom) } }
                .keyboardShortcut("0")
            Button("Zoom to Fit") { canvas?.zoomToFit(model?.bounds) }
                .keyboardShortcut("1")
            Divider()
        }
    }
}
