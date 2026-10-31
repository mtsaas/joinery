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
    /// Models open in tabs, in the tab bar's order.
    private(set) var tabs: [OpenModel] = []
    /// Whether the tabs are grown to show each model as it is now, the pointer having rested on one.
    var isPeeking = false
    /// The tab in front, or nil with the library browser shown.
    private(set) var open: OpenModel?
    /// The model in front: setting it brings its tab forward, opening one if need be; nil goes home, to the library,
    /// leaving the tabs open.
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
            MainActor.assumeIsolated { self?.tabs.forEach { $0.saveNow() } }
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
            // A model is spelled as a file, package or not, so it's the same URL either way.
            return items.map { item in
                let isCollection = item.hasDirectoryPath && item.pathExtension != "joinery"
                return folder.appending(path: item.lastPathComponent, directoryHint: isCollection ? .isDirectory : .notDirectory)
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

    /// Starts an empty model, in `collection` or at the top, and selects it. Named `name`, numbered if that's taken.
    func newModel(in collection: URL? = nil, named name: String = "Untitled Data Model") {
        attempt("make a data model") {
            let url = unique(name, extension: "joinery", in: collection ?? root)
            try DataModel().write(to: url)
            reload()
            selection = url
        }
    }

    // MARK: Sessions

    /// A session being joined, until it's let in and its model is open.
    private(set) var joining: SessionClient?

    /// Joins the session a link points to: once let in, its model opens, and changes to it are shared. Like remote
    /// access, it's open only while the session is: kept in a temporary folder, not the library, and closed and
    /// deleted when the session ends.
    /// - Returns: Whether the link is a session's.
    @discardableResult
    func join(_ link: String) -> Bool {
        joining?.close()
        joining = SessionClient(link: link) { [weak self] title, replica in
            guard let self, let client = self.joining else { return }
            self.joining = nil
            self.attempt("join the session") {
                let folder = self.files.temporaryDirectory.appending(path: "Sessions/\(UUID())", directoryHint: .isDirectory)
                try self.files.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = self.unique(title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " –"),
                                      extension: "joinery", in: folder)
                try replica.model.write(to: url)
                self.selection = url
                guard let open = self.open, open.url == url else {
                    client.close()
                    return try? self.files.removeItem(at: folder)
                }
                client.attach(to: open)
                client.onEnd = { [weak self] reason in
                    guard let self else { return }
                    if let tab = self.tabs.first(where: { $0.url == url }) { self.close(tab) }
                    try? self.files.removeItem(at: folder)
                    // Leaving needs no telling.
                    if reason != SessionClient.leftReason { self.failure = reason }
                }
            }
        }
        joining?.onRefusal = { [weak self] reason in
            self?.failure = "A change couldn't be made, so it's been taken back: \(reason)"
        }
        return joining != nil
    }

    /// The collection reviews are made in, made if need be.
    func reviewsCollection() throws -> URL {
        let url = root.appending(path: "Reviews", directoryHint: .isDirectory)
        if !files.fileExists(atPath: url.path) {
            try files.createDirectory(at: url, withIntermediateDirectories: false)
            reload()
        }
        return url
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
            tabs.first { $0.url == url }?.saveNow()
            let copy = unique(Self.name(of: url) + " copy", extension: "joinery", in: url.deletingLastPathComponent())
            try files.copyItem(at: url, to: copy)
            // A copy starts out ordinary, whatever the original was, though with its history.
            copy.setExtendedAttribute(Self.favoriteAttribute, to: nil)
            reload()
            selection = copy
        }
    }

    /// Moves a model or collection to the Trash, where it can be put back from.
    func trash(_ url: URL) {
        attempt("move it to the Trash") {
            for tab in tabs where tab.url.path.hasPrefix(url.path) { close(tab) }
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

    /// Closes a tab, saving it first; the one beside it comes forward if it was in front.
    func close(_ tab: OpenModel) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: index)
        // Out of the tabs first, so a session's end, which closes its tab, finds nothing more to do.
        tab.session?.close()
        tab.saveNow()
        // The last gone, home, with nothing left to peek at.
        if tabs.isEmpty { isPeeking = false }
        guard tab === open else { return }
        selection = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].url
    }

    /// Moves the tab showing `url` to `index` in the tab bar.
    /// - Returns: Whether it's a tab's.
    @discardableResult
    func moveTab(_ url: URL, to index: Int) -> Bool {
        guard let from = tabs.firstIndex(where: { $0.url == url }) else { return false }
        tabs.insert(tabs.remove(at: from), at: min(index, tabs.count))
        return true
    }

    /// Brings forward the tab `offset` along from the one in front, wrapping round.
    func showTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = open.flatMap { open in tabs.firstIndex { $0 === open } } ?? (offset > 0 ? -1 : 0)
        selection = tabs[(current + offset + tabs.count) % tabs.count].url
    }

    private func openSelection() {
        // Leaving it, for now: saved, but left open.
        open?.saveNow()
        guard let selection else {
            open = nil
            // Back in the browser: what was open has changed.
            return reload()
        }
        // Already open, perhaps renamed.
        if let tab = tabs.first(where: { $0.url == selection }) {
            open = tab
            return
        }
        do {
            let tab = try OpenModel(url: selection)
            // Next to the tab it was opened from, as a browser does.
            let index = open.flatMap { open in tabs.firstIndex { $0 === open } }.map { $0 + 1 } ?? tabs.endIndex
            tabs.insert(tab, at: index)
            open = tab
            selection.setExtendedAttribute(Self.openedAttribute, to: Data(String(Date.now.timeIntervalSinceReferenceDate).utf8))
            details[selection]?.opened = .now
        } catch {
            open = nil
            failure = "Couldn't open “\(Self.name(of: selection))”: \(error.localizedDescription)"
        }
    }

    /// Moves `url` (a model or collection). Models open in it stay open, where they've gone.
    private func relocate(_ url: URL, to destination: URL, doing description: String) {
        attempt(description) {
            let moving = tabs.filter { $0.url.path.hasPrefix(url.path) }
            moving.forEach { $0.saveNow() }
            try files.moveItem(at: url, to: destination)
            // Collections hold only models, so a model moving with one is just inside it.
            for tab in moving {
                tab.moved(to: tab.url == url ? destination : destination.appending(path: tab.url.lastPathComponent, directoryHint: .notDirectory))
            }
            reload()
            if let open, moving.contains(where: { $0 === open }) { selection = open.url }
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
