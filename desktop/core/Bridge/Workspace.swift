import Foundation

/// The data model open in the window, as the Mac's `OpenModel` keeps it, less the files: changes go through the replica
/// as ops, so each can be undone on its own and shared in a session. The shell saves; this says when, through events.
final class Workspace {
    private(set) var model = DataModel()
    private(set) var replica = Replica()
    /// Reviewing a change: the model as it was before it.
    private(set) var baseline: DataModel?
    private var undoStack: [[Replica.Op]] = []
    private var redoStack: [[Replica.Op]] = []
    /// Called with each change's ops, made here, for a session to send.
    var onChange: (([Replica.Op]) -> Void)?
    /// When an AI assistant last changed it, to save a version before the first of each spell of changes.
    private var lastAssistantChange: Date?
    /// When a version was last saved, for one an hour while editing.
    private var lastVersion = Date.distantPast

    func open(_ model: DataModel, baseline: DataModel?) {
        var model = model
        model.repair()
        self.model = model
        replica = Replica(model)
        self.baseline = baseline
        undoStack = []
        redoStack = []
        lastVersion = .now
        Events.post(["type": "changed"])
    }

    func markBaseline() {
        baseline = model
        Events.post(["type": "baseline", "model": (try? model.fileData).map { String(decoding: $0, as: UTF8.self) } ?? ""])
    }

    /// Ends the review: the shell keeps a version with the baseline, as the Mac's does.
    func endReview() {
        guard let baseline else { return }
        if baseline != model { saveVersion(Self.reviewReason, before: baseline) }
        self.baseline = nil
        Events.post(["type": "baseline", "model": ""])
    }

    static let reviewReason = "Reviewed change"

    /// Changes it to `new`, undoably, asking the shell to save a version first when the Mac's would.
    func change(to new: DataModel, byAssistant: Bool = false) {
        guard new != model else { return }
        if byAssistant {
            if lastAssistantChange.map({ Date.now.timeIntervalSince($0) > 10 * 60 }) ?? true { saveVersion("Before AI assistant changes") }
            lastAssistantChange = .now
        }
        let kept = Set(new.tables.map(\.id))
        let deleted = model.tables.filter { !kept.contains($0.id) }.map(\.name)
        let positions = Dictionary(uniqueKeysWithValues: new.tables.map { ($0.id, $0.position) })
        let moves = Set(model.tables.compactMap { table in
            positions[table.id].flatMap { $0 == table.position ? nil : [$0.x - table.position.x, $0.y - table.position.y] }
        })
        if !deleted.isEmpty {
            saveVersion("Before deleting " + (deleted.count == 1 ? deleted[0] : "\(deleted.count) tables"))
        } else if moves.count >= 4 {
            saveVersion("Before rearranging tables")
        } else if Date.now.timeIntervalSince(lastVersion) > 3600 {
            saveVersion("While editing")
        }
        let next = Replica(new, keeping: replica, was: model)
        let ops = replica.ops(to: next)
        undoStack.append(replica.apply(ops))
        redoStack = []
        model = new
        onChange?(ops)
        Events.post(["type": "changed"])
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() { if let ops = undoStack.popLast() { redoStack.append(apply(ops)) } }
    func redo() { if let ops = redoStack.popLast() { undoStack.append(apply(ops)) } }

    /// Applies `ops` as undoing or redoing does, tidying what's left dangling.
    /// - Returns: The ops that take it back.
    private func apply(_ ops: [Replica.Op]) -> [Replica.Op] {
        let back = replica.apply(ops)
        let tidying = replica.tidying()
        let all = replica.apply(tidying) + back
        model = replica.model
        onChange?(ops + tidying)
        Events.post(["type": "changed"])
        return all
    }

    /// Another person's change, taken by a session this hosts.
    func applyFromSession(_ ops: [Replica.Op]) {
        _ = replica.apply(ops)
        model = replica.model
        Events.post(["type": "changed"])
    }

    /// Takes on the host's copy, as a joined session does.
    func adopt(_ replica: Replica) {
        self.replica = replica
        model = replica.model
        Events.post(["type": "changed"])
    }

    func saveVersion(_ reason: String, before: DataModel? = nil) {
        lastVersion = .now
        var event: [String: Any] = ["type": "version", "reason": reason]
        if let before, let data = try? before.fileData { event["before"] = String(decoding: data, as: UTF8.self) }
        Events.post(event)
    }
}

/// What the shell needs to hear about, collected as it happens and taken with `drainEvents()` after each call:
/// `changed`, `version`, `baseline`, and a session's `send`, `links`, `peers`, `status`, `reconnect`, `ended`.
enum Events {
    nonisolated(unsafe) private static var queue: [[String: Any]] = []

    static func post(_ event: [String: Any]) { queue.append(event) }

    static func drain() -> String {
        defer { queue = [] }
        return json(queue)
    }
}

/// `object` as JSON. A bare `null` is fine too: JSONSerialization traps on one without `.fragmentsAllowed`, and
/// "nothing here" (`NSNull()`) is a common answer. (Not checked with `isValidJSONObject`, which turns down CGFloat
/// off Apple platforms, though writing it works.)
func json(_ object: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
}

func object(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}
