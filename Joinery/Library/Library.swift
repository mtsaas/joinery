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
    private var joining: SessionClient?

    /// Joins the session a link points to: once let in, its model is kept in the Shared collection, opened, and
    /// changes to it are shared.
    /// - Returns: Whether the link is a session's.
    @discardableResult
    func join(_ link: String) -> Bool {
        joining?.close()
        joining = SessionClient(link: link) { [weak self] title, replica in
            guard let self, let client = self.joining else { return }
            self.joining = nil
            self.attempt("join the session") {
                let folder = self.root.appending(path: "Shared", directoryHint: .isDirectory)
                try self.files.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = self.unique(title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " –"),
                                      extension: "joinery", in: folder)
                try replica.model.write(to: url)
                self.reload()
                self.selection = url
                guard let open = self.open, open.url == url else { return client.close() }
                client.attach(to: open)
            }
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
            open?.saveNow()
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
        // Already open, renamed.
        if let selection, selection == open?.url { return }
        open?.session?.close()
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
            // The open model, renamed, stays open as it is; anything else selected is let go of while it moves.
            let isOpen = open?.url == url
            if !isOpen, let selected, selected.path.hasPrefix(url.path) { selection = nil }
            try files.moveItem(at: url, to: destination)
            if isOpen { open?.moved(to: destination) }
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
    /// Where it is; it can be renamed while open.
    private(set) var url: URL
    private(set) var model: DataModel
    /// The model as entities, which changes are made to, as ops, so each can be undone on its own.
    @ObservationIgnored private(set) var replica: Replica
    /// Shared with others, the session it's shared in.
    var session: (any Session)?
    /// Called with each change's ops, made here (edited, undone or redone), for a session to send.
    @ObservationIgnored var onChange: (([Replica.Op]) -> Void)?
    /// The window's, set by the editor, for registering changes.
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    private(set) var history: History
    /// When an AI assistant last changed it, to save a version before the first of each spell of changes.
    @ObservationIgnored private var lastAssistantChange: Date?

    init(url: URL) throws {
        self.url = url
        history = History(of: url)
        let model = try DataModel(contentsOf: url)
        self.model = model
        replica = Replica(model)
        // A file from before packages becomes one, to keep versions in.
        if !url.isPackage { try model.write(to: url) }
        baseline = try? DataModel(contentsOf: baselineURL)
        saveVersion("Opened")
    }

    // MARK: Reviews

    /// Reviewing a change, such as a pull request's: the model as it was before it, to compare with as it is. Kept in
    /// the package, so the review survives quitting.
    private(set) var baseline: DataModel?
    private var baselineURL: URL { url.appending(path: "baseline.json") }

    /// Takes the model as it is now as the baseline: what's changed from here is shown as changes.
    func markBaseline() throws {
        saveNow()
        try model.fileData.write(to: baselineURL, options: .atomic)
        baseline = model
    }

    /// Ends the review: the model stays as it is, and the baseline is forgotten.
    func endReview() {
        try? FileManager.default.removeItem(at: baselineURL)
        baseline = nil
    }

    var name: String { Library.name(of: url) }

    /// It's been renamed or moved, to `url`, and stays open.
    func moved(to url: URL) {
        self.url = url
        history = History(of: url)
    }

    /// Saves the model as it is now as a version, to go back to. Failing to is no reason to stop the change coming.
    func saveVersion(_ reason: String) {
        try? history.save(model, reason: reason)
    }

    /// Briefly shown over the canvas: what ⌘S did.
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// ⌘S: writes it out and keeps it as a version, one never thinned out, saying which.
    func saveVersionNow() {
        saveNow()
        let saved: Bool
        do {
            saved = try history.save(model, reason: History.savedReason)
        } catch {
            Library.shared.failure = "Couldn't save a version: \(error.localizedDescription)"
            return
        }
        notice = saved ? "Version saved" : "No changes since the last version"
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { notice = nil }
        }
    }

    /// Changes it to `new`, undoably, first saving a version if it's an assistant's first change in a while or one
    /// likely to be regretted: deleting tables, or rearranging many (a layout, untangling, aligning lots: moved by
    /// different amounts, unlike dragging a few together). And hourly while editing, so a long session has some.
    func change(to new: DataModel, byAssistant: Bool = false) {
        guard new != model else { return }
        if byAssistant {
            if lastAssistantChange.map({ Date.now.timeIntervalSince($0) > 10 * 60 }) ?? true { saveVersion("Before AI assistant changes") }
            lastAssistantChange = .now
        }
        let kept = Set(new.tables.map(\.id))
        let deleted = model.tables.filter { !kept.contains($0.id) }.map(\.name)
        let positions = Dictionary(uniqueKeysWithValues: new.tables.map { ($0.id, $0.position) })
        // Moved by how much, each way: dragging tables together moves them all alike.
        let moves = Set(model.tables.compactMap { table in
            positions[table.id].flatMap { $0 == table.position ? nil : [$0.x - table.position.x, $0.y - table.position.y] }
        })
        if !deleted.isEmpty {
            saveVersion("Before deleting " + (deleted.count == 1 ? deleted[0] : "\(deleted.count) tables"))
        } else if moves.count >= 4 {
            saveVersion("Before rearranging tables")
        } else if history.versions.first.map({ Date.now.timeIntervalSince($0.date) > 3600 }) ?? true {
            saveVersion("While editing")
        }
        let next = Replica(new, keeping: replica, was: model)
        let ops = replica.ops(to: next)
        registerUndo(replica.apply(ops))
        model = new
        onChange?(ops)
        scheduleSave()
    }

    /// Applies `ops`, as undoing or redoing does: only those fields and entities change, so changes since that aren't
    /// part of it stay. What's left dangling (a key to a column gone, say) is tidied up, and that's undone with them.
    private func apply(_ ops: [Replica.Op]) {
        let undo = replica.apply(ops)
        let (tidying, tidied) = tidyingUp()
        model = tidied
        registerUndo(replica.apply(tidying) + undo)
        onChange?(ops + tidying)
        scheduleSave()
    }

    /// Ops that tidy the replica up after ops made elsewhere, or undone after others' changes: what's left dangling (a
    /// key to a column gone, say) repaired, and what can't be read, or whose table or group has gone, removed.
    /// - Returns: The ops, and the model they leave.
    private func tidyingUp() -> (ops: [Replica.Op], model: DataModel) {
        let applied = replica.model
        var repaired = applied
        repaired.repair()
        return (replica.ops(to: Replica(repaired, keeping: replica, was: applied)), repaired)
    }

    /// Another person's change, from a session this hosts: all its ops or, if any can't be made (on something since
    /// deleted, say), none. Undo here is left alone: it undoes only changes made here.
    /// - Returns: The ops that tidied up after it, to send on too.
    func receive(_ ops: [Replica.Op]) throws -> [Replica.Op] {
        var next = replica
        for op in ops {
            guard next.apply(op) != nil else { throw ModelTools.Failure("That's been deleted or changed since.") }
        }
        for id in Set(ops.map(\.id)) {
            if let entity = next.entities[id], let problem = next.problem(with: entity) { throw ModelTools.Failure(problem) }
        }
        replica = next
        let (tidying, tidied) = tidyingUp()
        replica.apply(tidying)
        model = tidied
        scheduleSave()
        return tidying
    }

    /// Takes on `replica` as it is, as a session joined replaces it with the host's.
    func adopt(_ replica: Replica) {
        self.replica = replica
        model = replica.model
        scheduleSave()
    }

    /// Registers `undo` to be applied: as the undo while changing or redoing, as the redo while undoing.
    private func registerUndo(_ undo: [Replica.Op]) {
        guard !undo.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.apply(undo) }
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if !Task.isCancelled { saveNow() }
        }
    }

    /// Goes back to `version`, undoably, saving how it is now as a version first.
    func restore(_ version: History.Version) throws {
        let earlier = try DataModel(contentsOf: version.url)
        saveVersion("Before restoring an earlier version")
        change(to: earlier)
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
