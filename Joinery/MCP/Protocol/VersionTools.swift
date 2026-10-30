import Foundation

/// What the version tools work on: the open model and its named versions.
struct VersionState {
    var model: DataModel
    var named: NamedVersions
}

/// The tools for named versions: save the model as it is under a name, list them, compare any two (or one with the
/// model as it is), restore one, delete one. Every call names what it works on, so an assistant needn't keep track of
/// anything between calls, and a failure says what to call instead.
enum VersionTools {
    nonisolated(unsafe) static let definitions: [[String: Any]] = [
        [
            "name": "save_version",
            "description": """
                Saves the open data model as it is now under a name, such as "main", "draft 1" or "after PR 482", to \
                compare with later. Name versions after what they are: a branch, a draft, a commit. The data model \
                itself carries on as it is, to edit. Names are matched ignoring case; "current" is reserved for the \
                model as it is now. Saving under a name already used fails, unless replace is true.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "What to call it, such as \"main\" or \"draft 1\"."],
                    "replace": ["type": "boolean", "description": "Save over a version already called that. Default false."],
                ],
                "required": ["name"],
            ],
        ],
        [
            "name": "list_versions",
            "description": """
                The open data model's named versions, oldest first: when each was saved, its tables, and what changed \
                from the one before. Then how the model as it is now (current) stands: the same as a version, or \
                changed since the latest. Call it first to find out what there is to compare.
                """,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "compare",
            "description": """
                What changed from one version to another, and shows that comparison in Joinery's window as a diff: \
                tables, columns and foreign keys added in green, removed in red, changed columns as they were and as \
                they are. Either side can be a named version or "current", the data model as it is now; a comparison \
                with current follows later edits live. Lists tables added, removed and changed, each changed column as \
                it was → as it is, and foreign keys added and removed. Call it once for each pair to compare; the \
                window shows the last.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "from": ["type": "string", "description": "The earlier side: a version's name, or \"current\"."],
                    "to": ["type": "string", "description": "The later side: a version's name, or \"current\"."],
                ],
                "required": ["from", "to"],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "restore_version",
            "description": """
                Makes the open data model as a named version is, to carry on from there: to try another design from \
                the same starting point, say. Can be undone in Joinery. Fails if the model has changes saved in no \
                version, which restoring would lose: save_version first, or pass discard_unsaved.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"],
                    "discard_unsaved": ["type": "boolean", "description": "Restore even though the model's changes since its last version would be lost."],
                ],
                "required": ["name"],
            ],
        ],
        [
            "name": "delete_version",
            "description": "Deletes a named version. The data model as it is now stays.",
            "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
        ],
    ]

    static var names: Set<String> { Set(definitions.compactMap { $0["name"] as? String }) }

    /// Runs `name` on `state`, which is left alone if it fails; `get_model` with a `version` reads that version.
    /// - Returns: What happened, for the assistant.
    static func call(_ name: String, _ arguments: [String: Any], on state: inout VersionState) throws -> String {
        var draft = state
        let result: String
        switch name {
        case "save_version": result = try save(arguments, in: &draft)
        case "list_versions": result = list(draft)
        case "compare": result = try compare(arguments, in: &draft)
        case "restore_version": result = try restore(arguments, in: &draft)
        case "delete_version":
            let version = try existing(arguments, in: draft)
            draft.named.remove(version.name)
            result = "Deleted \(quoted(version.name)). " + remaining(draft)
        case "get_model":
            let version = try existing(arguments, key: "version", in: draft)
            result = "The version \(quoted(version.name)), saved \(stamp(version.date)):\n" + (try ModelTools.describe(version.model))
        default: throw ModelTools.Failure("There's no tool called \(name).")
        }
        state = draft
        return result
    }

    /// Whether a call runs here: `get_model` does when it names a version.
    static func handles(_ name: String, _ arguments: [String: Any]) -> Bool {
        names.contains(name) || (name == "get_model" && (arguments["version"] as? String).map { !NamedVersions.isCurrent($0) } == true)
    }

    // MARK: Tools

    private static func save(_ arguments: [String: Any], in state: inout VersionState) throws -> String {
        let name = NamedVersions.clean(arguments["name"] as? String ?? "")
        guard !name.isEmpty else { throw ModelTools.Failure("Give the version a name, such as \"main\" or \"draft 1\".") }
        guard !NamedVersions.isCurrent(name) else {
            throw ModelTools.Failure("\"current\" stands for the data model as it is now, so it can't name a version. Pick another name.")
        }
        guard !state.model.tables.isEmpty else {
            throw ModelTools.Failure("The data model is empty. Draw the schema first, with create_tables, then save it.")
        }
        if let existing = state.named.version(named: name), arguments["replace"] as? Bool != true {
            throw ModelTools.Failure("There's already a version called \(quoted(existing.name)), saved \(stamp(existing.date)). "
                + "Pass replace: true to save over it, or pick another name. " + remaining(state))
        }
        state.named.save(state.model, as: name)
        return "Saved the \(plural(state.model.tables.count, "table")) as they are now as \(quoted(name)). " + remaining(state)
            + " Compare two with compare, using \"current\" for the data model as it is."
    }

    private static func list(_ state: VersionState) -> String {
        guard !state.named.versions.isEmpty else {
            return "There are no named versions yet. Save the data model as it is with save_version, such as \"main\" for how it is on the main branch."
        }
        var lines = ["Named versions, oldest first:"]
        var previous: NamedVersions.Version?
        for version in state.named.versions {
            var line = "- \(version.name): saved \(stamp(version.date)), \(plural(version.model.tables.count, "table"))"
            if let previous { line += "; from \(previous.name): " + SchemaDiff(from: previous.model, to: version.model).summary.lowercasedFirst }
            lines.append(line)
            previous = version
        }
        lines.append("\n" + standing(state))
        if let comparison = state.named.comparison {
            lines.append("Joinery's window compares \(comparison.from) → \(comparison.to).")
        }
        return lines.joined(separator: "\n")
    }

    private static func compare(_ arguments: [String: Any], in state: inout VersionState) throws -> String {
        let from = try side("from", arguments, in: state), to = try side("to", arguments, in: state)
        state.named.comparison = NamedVersions.Comparison(from: from.name, to: to.name)
        return SchemaDiff(from: from.model, to: to.model).report(from: from.name, to: to.name)
            + "\n\nJoinery's window now shows \(from.name) → \(to.name) as a diff."
    }

    private static func restore(_ arguments: [String: Any], in state: inout VersionState) throws -> String {
        let version = try existing(arguments, in: state)
        if savedIn(state) == nil, arguments["discard_unsaved"] as? Bool != true {
            let latest = state.named.versions.last.map { " since \($0.name): " + SchemaDiff(from: $0.model, to: state.model).summary.lowercasedFirst } ?? ""
            throw ModelTools.Failure("The data model has changes saved in no version\(latest). Restoring would lose them: "
                + "save_version first, or pass discard_unsaved: true to restore anyway.")
        }
        state.model = version.model
        return "The data model is now as \(quoted(version.name)) was saved, \(stamp(version.date)): "
            + "\(plural(version.model.tables.count, "table")). It can be undone in Joinery."
    }

    // MARK: Helpers

    /// The version saved with the same schema as the model as it is, the latest if more than one.
    private static func savedIn(_ state: VersionState) -> NamedVersions.Version? {
        state.named.versions.last { SchemaDiff(from: $0.model, to: state.model).isEmpty }
    }

    /// How the model as it is stands against the versions.
    private static func standing(_ state: VersionState) -> String {
        if let same = savedIn(state) { return "current (the data model as it is now): the same as \(same.name)." }
        guard let latest = state.named.versions.last else { return "current (the data model as it is now): not saved as a version." }
        return "current (the data model as it is now): since \(latest.name), " + SchemaDiff(from: latest.model, to: state.model).summary.lowercasedFirst + "."
    }

    /// A side of a comparison: a version, or the model as it is.
    private static func side(_ key: String, _ arguments: [String: Any], in state: VersionState) throws -> (name: String, model: DataModel) {
        guard let name = arguments[key] as? String, !NamedVersions.clean(name).isEmpty else {
            throw ModelTools.Failure("Say what to compare \(key): a version's name, or \"current\". " + remaining(state))
        }
        if NamedVersions.isCurrent(name) { return (NamedVersions.current, state.model) }
        let version = try existing([key: name], key: key, in: state)
        return (version.name, version.model)
    }

    private static func existing(_ arguments: [String: Any], key: String = "name", in state: VersionState) throws -> NamedVersions.Version {
        let name = arguments[key] as? String ?? ""
        guard let version = state.named.version(named: name) else {
            throw ModelTools.Failure("There's no version called \(quoted(NamedVersions.clean(name))). " + remaining(state))
        }
        return version
    }

    /// The versions there are, to say after anything that changes them or can't find one.
    private static func remaining(_ state: VersionState) -> String {
        state.named.versions.isEmpty ? "There are no named versions now."
            : "Versions, oldest first: " + state.named.versions.map(\.name).joined(separator: ", ") + "."
    }

    private static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }

    private static func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// When, the same on every platform and in every locale: "2026-10-30T14:02:11Z".
    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
