import Sparkle
import SwiftUI

@main
struct JoineryApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Joinery", id: "library") {
            LibraryView(library: .shared)
        }
        .defaultSize(width: 1440, height: 880)
        // The tabs take the title bar's place, beside the window's buttons.
        .windowStyle(.hiddenTitleBar)
        .commands {
            LibraryCommands(library: .shared)
            CanvasCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.controller?.checkForUpdates(nil) }
                    .disabled(Updates.controller == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// Updates through Sparkle, from the feed the release workflow builds in. A build without one, such as Xcode's,
/// doesn't check.
enum Updates {
    @MainActor static let controller: SPUStandardUpdaterController? = {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `.joinery` files opened from Finder (or passed on the command line) are copied into the library.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == "joinery" { Library.shared.importModel(from: url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if MCPServer.isEnabled { MCPServer.shared.start() }
        _ = Updates.controller
        #if DEBUG
        DebugHooks.launched()
        #endif
    }
}

/// File menu items for the library.
struct LibraryCommands: Commands {
    let library: Library
    @AppStorage("verticalTabs") private var isVertical = false

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
            // As Safari has them. With no tab open, Close Tab closes the window. Titles that don't change with what's
            // open: a menu's titles aren't always rebuilt when it changes.
            Button("Close Tab") {
                if let open = library.open { library.close(open) } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            // Changes save themselves; this keeps the data model as it is in its version history.
            Button("Save Version") { library.open?.saveVersionNow() }
                .keyboardShortcut("s")
                .disabled(library.open == nil)
        }
        // The model in front's own undo history; text being edited keeps the window's.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { undo(redo: false) }
                .keyboardShortcut("z")
            Button("Redo") { undo(redo: true) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(before: .windowList) {
            Button("Show or Hide Library") {
                withAnimation(.smooth(duration: 0.25)) { library.showsLibrary.toggle() }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(library.open == nil)
            Toggle("Vertical Tabs", isOn: $isVertical)
            Button("Show Next Tab") { library.showTab(offset: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(library.tabs.isEmpty)
            Button("Show Previous Tab") { library.showTab(offset: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(library.tabs.isEmpty)
            Divider()
        }
    }

    private func undo(redo: Bool) {
        if NSApp.keyWindow?.firstResponder is NSText || library.open == nil {
            NSApp.sendAction(Selector((redo ? "redo:" : "undo:")), to: nil, from: nil)
        } else if let manager = library.open?.undoManager {
            redo ? manager.redo() : manager.undo()
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
