import Foundation

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
    /// Where it's scrolled and zoomed to, and what's selected: kept with it, so they're as they were when its tab
    /// comes back to the front.
    @ObservationIgnored let canvas = CanvasController()
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
        named = Self.readNamed(in: url)
        saveVersion("Opened")
    }

    // MARK: Named versions

    /// Its named versions, such as "main" and "draft 1", and which two are compared. Kept in the package, so a
    /// comparison survives quitting.
    private(set) var named = NamedVersions()
    private static func namedURL(in url: URL) -> URL { url.appending(path: NamedVersions.fileName) }
    /// Where a review's baseline was kept before named versions.
    private static func baselineURL(in url: URL) -> URL { url.appending(path: "baseline.json") }

    /// The package's named versions; a review's baseline from before them becomes one, compared with now.
    private static func readNamed(in url: URL) -> NamedVersions {
        if let data = try? Data(contentsOf: namedURL(in: url)), let named = try? NamedVersions(fileData: data) { return named }
        let baseline = baselineURL(in: url)
        guard let before = try? DataModel(contentsOf: baseline) else { return NamedVersions() }
        let date = (try? baseline.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        let named = NamedVersions.migrating(baseline: before, at: date)
        if (try? named.fileData.write(to: namedURL(in: url), options: .atomic)) != nil { try? FileManager.default.removeItem(at: baseline) }
        return named
    }

    /// Changes the named versions or what's compared, and writes them into the package.
    func setNamed(_ new: NamedVersions) throws {
        guard new != named else { return }
        saveNow()
        let file = Self.namedURL(in: url)
        if new.isEmpty {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } else {
            try new.fileData.write(to: file, options: .atomic)
        }
        named = new
    }

    /// Compares two versions in the window, or stops comparing with nil.
    func compare(_ comparison: NamedVersions.Comparison?) {
        var new = named
        new.comparison = comparison
        do {
            try setNamed(new)
        } catch {
            Library.shared.failure = "Couldn't change what's compared: \(error.localizedDescription)"
        }
    }

    // MARK: Layout while comparing

    /// A version that can be laid out while it's shown: the model as it is, a named version, or one kept in the
    /// version history (its file).
    enum Laid: Equatable {
        case current
        case named(String)
        case history(URL)
    }

    /// Lays `target` out as `shown` is, keeping it as it is but for that: where tables are, and the zip ties; with
    /// `only`, just those tables. The model as it is changes undoably; a version's file is written over.
    /// - Returns: The version as laid out now.
    @discardableResult
    func layOut(_ target: Laid, as shown: DataModel, only: Set<Table.ID>? = nil) -> DataModel? {
        switch target {
        case .current:
            change(to: model.takingLayout(from: shown, only: only))
            return model
        case .named(let name):
            if NamedVersions.isCurrent(name) { return layOut(.current, as: shown, only: only) }
            guard let saved = named.version(named: name)?.model else { return nil }
            let laid = saved.takingLayout(from: shown, only: only)
            var new = named
            new.update(name, to: laid)
            do { try setNamed(new) } catch {
                Library.shared.failure = "Couldn't keep the layout: \(error.localizedDescription)"
                return nil
            }
            return laid
        case .history(let url):
            guard let saved = try? DataModel(contentsOf: url) else { return nil }
            let laid = saved.takingLayout(from: shown, only: only)
            do { try laid.fileData.write(to: url, options: .atomic) } catch {
                Library.shared.failure = "Couldn't keep the layout: \(error.localizedDescription)"
                return nil
            }
            return laid
        }
    }

    /// Why a review's version was kept.
    static let reviewReason = "Reviewed change"

    /// Stops comparing. The named versions stay, and the change compared is kept in the version history too, so it can
    /// be seen there as it was reviewed.
    func endComparison() {
        if let (before, after) = named.compared(current: model), before != after {
            try? history.save(after, reason: Self.reviewReason, before: before)
        }
        compare(nil)
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
    /// A column's type changed here goes to the columns its foreign keys join it to; an assistant's changes are taken as
    /// they are, as drawing a migration to review has to show any mismatch in it.
    func change(to new: DataModel, byAssistant: Bool = false) {
        guard new != model else { return }
        var new = new
        if !byAssistant { new.carryTypes(from: model) }
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
        let tidying = replica.tidying()
        registerUndo(replica.apply(tidying) + undo)
        model = replica.model
        onChange?(ops + tidying)
        scheduleSave()
    }

    /// Another person's change, taken by a session this hosts (`RelayHostCore`), and the tidying after it. Undo here is left
    /// alone: it undoes only changes made here.
    func applyFromSession(_ ops: [Replica.Op]) {
        _ = replica.apply(ops)
        model = replica.model
        onSessionChange?()
        scheduleSave()
    }

    /// Takes on `replica` as it is, as a session joined replaces it with the host's.
    func adopt(_ replica: Replica) {
        self.replica = replica
        model = replica.model
        onSessionChange?()
        scheduleSave()
    }

    /// Called as a change from someone else in a session lands, in the same update.
    @ObservationIgnored var onSessionChange: (() -> Void)?

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
