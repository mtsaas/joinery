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
        let tidying = replica.tidying()
        registerUndo(replica.apply(tidying) + undo)
        model = replica.model
        onChange?(ops + tidying)
        scheduleSave()
    }

    /// Another person's change, taken by a session this hosts (`HostCore`), and the tidying after it. Undo here is left
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
