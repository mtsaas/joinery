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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `.joinery` files opened from Finder (or passed on the command line) are copied into the library.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == "joinery" { Library.shared.importSchema(from: url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MCPServer.shared.start()
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
            Button("New Schema") { library.newSchema(in: library.selection.flatMap(library.collection(of:))) }
                .keyboardShortcut("n")
            Button("New Collection") { library.newCollection() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import Schema…") { importSchema() }
                .keyboardShortcut("o")
            Button("Add Examples") { try? library.addExamples() }
            Button("Show Library in Finder") { library.showInFinder(library.root) }
        }
    }

    private func importSchema() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.joinerySchema]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { library.importSchema(from: url) }
    }
}
