import SwiftUI

@main
struct JoineryApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Joinery", id: "library") {
            LibraryView(library: .shared)
        }
        .defaultSize(width: 1440, height: 880)
        .commands {
            LibraryCommands(library: .shared)
            CanvasCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `.joinery` files opened from Finder (or passed on the command line) are copied into the library.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == "joinery" { Library.shared.importModel(from: url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if MCPServer.isEnabled { MCPServer.shared.start() }
        #if DEBUG
        DebugHooks.launched()
        #endif
    }
}

/// File menu items for the library.
struct LibraryCommands: Commands {
    let library: Library

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Data Model") { library.newModel(in: library.selection.flatMap(library.collection(of:))) }
                .keyboardShortcut("n")
            Button("New Collection") { library.newCollection() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import Data Model…") { importModel() }
                .keyboardShortcut("o")
            Button("Add Examples") { try? library.addExamples() }
            Button("Show Library in Finder") { library.showInFinder(library.root) }
        }
        CommandGroup(replacing: .saveItem) {
            // Changes save themselves; this keeps the data model as it is in its version history.
            Button("Save Version") { library.open?.saveVersionNow() }
                .keyboardShortcut("s")
                .disabled(library.open == nil)
        }
    }

    private func importModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.joineryDataModel]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { library.importModel(from: url) }
    }
}
