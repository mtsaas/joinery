import AppKit
import Foundation

/// The models on disk: `.joinery` files in a folder, whose subfolders are collections. Plain files, so nothing is
/// kept in a database and Finder sees exactly what the sidebar does.
@MainActor @Observable
final class Library {
    struct Collection: Identifiable, Hashable {
        let url: URL
        var models: [URL]
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    static let shared = Library(root: defaultRoot)
    static let examplesName = "Examples"

    /// In the app's own storage. A debug build can be pointed elsewhere with `JOINERY_LIBRARY`, so test runs never
    /// touch the real library.
    private static var defaultRoot: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["JOINERY_LIBRARY"] { return URL(filePath: path, directoryHint: .isDirectory) }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Joinery/Schemas", directoryHint: .isDirectory)
    }

    let root: URL
    /// Models not in any collection.
    private(set) var models: [URL] = []
    private(set) var collections: [Collection] = []
    /// The model being edited.
    private(set) var open: OpenModel?
    var selection: URL? {
        didSet { if selection != oldValue { openSelection() } }
    }
    /// What last went wrong, to tell the person.
    var failure: String?

    /// What the browser shows about a model besides its name.
    struct Details {
        var modified: Date
        /// When it was last opened here, if it has been.
        var opened: Date?
        var isFavorite: Bool

        /// When it was last opened or changed, whichever's later.
        var lastUsed: Date { max(modified, opened ?? .distantPast) }
    }

    private(set) var details: [URL: Details] = [:]

    /// Every model, in collections or not.
    var allModels: [URL] { models + collections.flatMap(\.models) }

    private let files = FileManager.default

    init(root: URL) {
        self.root = root
        let isNew = !files.fileExists(atPath: root.path)
        do {
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            // A new library starts with the examples; deleting them later doesn't bring them back.
            if isNew { try addExamples() }
        } catch {
            failure = "Couldn't set up the library: \(error.localizedDescription)"
        }
        reload()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.open?.saveNow() }
        }
    }

    static func name(of url: URL) -> String {
        url.pathExtension == "joinery" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    /// The collection a model is in, or nil if it's at the top.
    func collection(of url: URL) -> URL? {
        let folder = url.deletingLastPathComponent()
        return folder.standardizedFileURL == root.standardizedFileURL ? nil : folder
    }

    func reload() {
        let byName = { (a: URL, b: URL) in Self.name(of: a).localizedStandardCompare(Self.name(of: b)) == .orderedAscending }
        // Rebuilt from the folder and each name, the way every other URL here is made, so they compare equal: the
        // ones the file system hands back can differ in spelling (a resolved symlink, a trailing slash).
        func contents(of folder: URL) -> [URL] {
            let items = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: .skipsHiddenFiles)) ?? []
            return items.map { item in
                folder.appending(path: item.lastPathComponent, directoryHint: item.hasDirectoryPath ? .isDirectory : .notDirectory)
            }
        }
        let top = contents(of: root)
        models = top.filter { $0.pathExtension == "joinery" }.sorted(by: byName)
        collections = top.filter { $0.hasDirectoryPath }.sorted(by: byName).map { folder in
            Collection(url: folder, models: contents(of: folder).filter { $0.pathExtension == "joinery" }.sorted(by: byName))
        }
        details = Dictionary(uniqueKeysWithValues: allModels.map { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let opened = url.extendedAttribute(Self.openedAttribute).flatMap { Double(String(decoding: $0, as: UTF8.self)) }
            return (url, Details(modified: modified, opened: opened.map(Date.init(timeIntervalSinceReferenceDate:)),
                                 isFavorite: url.extendedAttribute(Self.favoriteAttribute) != nil))
        })
    }

    // MARK: Favorites and recents
    //
    // Kept on the files themselves, as extended attributes, so they go wherever a model is moved or renamed.

    private static let favoriteAttribute = URL.attributePrefix + "favorite"
    private static let openedAttribute = URL.attributePrefix + "opened"

    func setFavorite(_ url: URL, _ isFavorite: Bool) {
        url.setExtendedAttribute(Self.favoriteAttribute, to: isFavorite ? Data([1]) : nil)
        details[url]?.isFavorite = isFavorite
    }

    /// Models opened or changed in the last month, most recent first.
    var recents: [URL] {
        let month = Date.now.addingTimeInterval(-30 * 24 * 3600)
        return allModels.filter { (details[$0]?.lastUsed ?? .distantPast) > month }
            .sorted { details[$0]!.lastUsed > details[$1]!.lastUsed }
    }

    // MARK: Changes

    /// Starts an empty model, in `collection` or at the top, and selects it.
    func newModel(in collection: URL? = nil) {
        attempt("make a data model") {
            let url = unique("Untitled Data Model", extension: "joinery", in: collection ?? root)
            try DataModel().write(to: url)
            reload()
            selection = url
        }
    }

    /// Makes an empty collection and returns it, to be named.
    @discardableResult
    func newCollection() -> URL? {
        attempt("make a collection") {
            let url = unique("New Collection", extension: nil, in: root)
            try files.createDirectory(at: url, withIntermediateDirectories: false)
            reload()
            return url
        }
    }

    /// Renames a model or collection. The name can't be empty or contain "/" or ":".
    func rename(_ url: URL, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != Self.name(of: url) else { return }
        guard !name.isEmpty, !name.contains("/"), !name.contains(":") else {
            failure = "“\(name)” can't be used as a name."
            return
        }
        let destination = url.deletingLastPathComponent()
            .appending(path: url.hasDirectoryPath ? name : name + ".joinery", directoryHint: url.hasDirectoryPath ? .isDirectory : .notDirectory)
        guard !files.fileExists(atPath: destination.path) else {
            failure = "There's already something called “\(name)” there."
            return
        }
        relocate(url, to: destination, doing: "rename it")
    }

    /// Moves a model into a collection, or to the top with nil.
    func move(_ url: URL, to collection: URL?) {
        let folder = collection ?? root
        guard url.pathExtension == "joinery", url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL else { return }
        relocate(url, to: unique(Self.name(of: url), extension: "joinery", in: folder), doing: "move it")
    }

    func duplicate(_ url: URL) {
        attempt("duplicate it") {
            open?.saveNow()
            let copy = unique(Self.name(of: url) + " copy", extension: "joinery", in: url.deletingLastPathComponent())
            try files.copyItem(at: url, to: copy)
            // A copy starts out ordinary, whatever the original was.
            copy.setExtendedAttribute(Self.favoriteAttribute, to: nil)
            reload()
            selection = copy
        }
    }

    /// Moves a model or collection to the Trash, where it can be put back from.
    func trash(_ url: URL) {
        attempt("move it to the Trash") {
            if let selection, selection.path.hasPrefix(url.path) { self.selection = nil }
            try files.trashItem(at: url, resultingItemURL: nil)
            reload()
        }
    }

    /// Opens a `.joinery` file from elsewhere by copying it in; one already in the library is just selected.
    func importModel(from url: URL) {
        if url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
            selection = url
            return
        }
        attempt("open “\(url.lastPathComponent)”") {
            _ = try DataModel(contentsOf: url)
            let copy = unique(Self.name(of: url), extension: "joinery", in: root)
            try files.copyItem(at: url, to: copy)
            reload()
            selection = copy
        }
    }

    /// Copies the bundled examples into an Examples collection, alongside any already there.
    func addExamples() throws {
        let folder = root.appending(path: Self.examplesName, directoryHint: .isDirectory)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for example in Bundle.main.urls(forResourcesWithExtension: "joinery", subdirectory: nil) ?? [] {
            let destination = folder.appending(path: example.lastPathComponent)
            if !files.fileExists(atPath: destination.path) { try files.copyItem(at: example, to: destination) }
        }
        reload()
    }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Helpers

    private func openSelection() {
        open?.saveNow()
        open = nil
        // Back in the browser: what was open has changed.
        guard let selection else { return reload() }
        do {
            open = try OpenModel(url: selection)
            selection.setExtendedAttribute(Self.openedAttribute, to: Data(String(Date.now.timeIntervalSinceReferenceDate).utf8))
            details[selection]?.opened = .now
        } catch {
            failure = "Couldn't open “\(Self.name(of: selection))”: \(error.localizedDescription)"
        }
    }

    /// Moves `url` (a model or collection), keeping the selection on whatever moved.
    private func relocate(_ url: URL, to destination: URL, doing description: String) {
        attempt(description) {
            open?.saveNow()
            let selected = selection
            if let selected, selected.path.hasPrefix(url.path) { selection = nil }
            try files.moveItem(at: url, to: destination)
            reload()
            if let selected, selected.path.hasPrefix(url.path) {
                selection = URL(filePath: destination.path + selected.path.dropFirst(url.path.count))
            }
        }
    }

    /// `name`, or `name 2`, `name 3`… whichever isn't taken in `folder`.
    private func unique(_ name: String, extension pathExtension: String?, in folder: URL) -> URL {
        var number = 1
        while true {
            let candidate = number == 1 ? name : "\(name) \(number)"
            let url = pathExtension.map { folder.appending(path: "\(candidate).\($0)", directoryHint: .notDirectory) }
                ?? folder.appending(path: candidate, directoryHint: .isDirectory)
            if !files.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }

    @discardableResult
    private func attempt<T>(_ description: String, _ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            failure = "Couldn't \(description): \(error.localizedDescription)"
            reload()
            return nil
        }
    }
}

/// A model file being edited: changes save themselves shortly after, and can be undone.
@MainActor @Observable
final class OpenModel {
    let url: URL
    private(set) var model: DataModel
    /// The window's, set by the editor, for registering changes.
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(url: URL) throws {
        self.url = url
        model = try DataModel(contentsOf: url)
    }

    var name: String { Library.name(of: url) }

    func change(to new: DataModel) {
        guard new != model else { return }
        let old = model
        model = new
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.change(to: old) }
        }
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { saveNow() }
        }
    }

    /// Writes it out now, unless the file has gone (moved or trashed), so a late save can't bring it back.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try model.write(to: url)
        } catch {
            Library.shared.failure = "Couldn't save “\(name)”: \(error.localizedDescription)"
        }
    }
}
