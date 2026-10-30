import Foundation

/// What the app around the MCP server provides: its library, reviews and sharing, and the open data model. Everything
/// else, from the HTTP to the tools, is here and the same on every platform.
protocol MCPHost {
    /// Runs one of `MCP.libraryTools`.
    func callLibraryTool(_ name: String, _ arguments: [String: Any]) async throws -> String
    /// Applies `change` to the open data model as one change, and one undo, made by an assistant.
    func edit(_ change: (inout DataModel) throws -> String) async throws -> String
    /// Runs `body` on the open data model and its named versions, keeping what it changes: the versions and what's
    /// compared saved into the model's package, and a changed model (a version restored) applied as `edit` applies one.
    func withVersions(_ body: (inout VersionState) throws -> String) async throws -> String
}

/// An MCP server, so AI assistants can read and edit models: Streamable HTTP at `url`, on this computer only. The app
/// listens and hands each request's bytes to `response(to:host:)`.
///
/// Stateless and answered with plain JSON: every request is a POST of JSON-RPC, so there are no sessions or event
/// streams to keep.
enum MCP {
    static let port: UInt16 = 8723
    static let url = "http://127.0.0.1:\(port)/mcp"
    /// For Claude Code; other assistants take `url` in their own settings.
    static let setupCommand = "claude mcp add --transport http joinery \(url)"
    /// For assistants that only start servers themselves, such as Claude Desktop: a bridge to `url`.
    static let bridgeConfiguration = """
        {
          "mcpServers": {
            "joinery": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "\(url)"]
            }
          }
        }
        """

    /// Each tool's name and what it does, in a sentence, for Settings.
    static var toolSummaries: [(name: String, summary: String)] {
        tools.compactMap { tool in
            guard let name = tool["name"] as? String, let description = tool["description"] as? String else { return nil }
            return (name, description.split(separator: ".").first.map { $0 + "." } ?? description)
        }
    }

    // MARK: HTTP

    struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        /// A whole request, or nil if more is still to come.
        init?(_ data: Data) {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let words = lines.first?.split(separator: " ") ?? []
            guard words.count >= 2 else { return nil }
            method = String(words[0])
            path = String(words[1].split(separator: "?").first ?? "")
            headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }, uniquingKeysWith: { first, _ in first })
            let length = Int(headers["content-length"] ?? "") ?? 0
            body = data[end.upperBound...]
            guard body.count >= length else { return nil }
            body = body.prefix(length)
        }
    }

    /// The whole HTTP response to `request`, to send before closing the connection.
    static func response(to request: Request, host: some MCPHost) async -> Data {
        let (status, body) = await answer(request, host: host)
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        if status.hasPrefix("405") { head += "Allow: POST\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    private static func answer(_ request: Request, host: some MCPHost) async -> (status: String, body: Data) {
        guard request.path == "/mcp" else { return ("404 Not Found", Data()) }
        // A web page could otherwise reach it through the browser (DNS rebinding); only local origins may.
        if let origin = request.headers["origin"],
           !["http://localhost", "http://127.0.0.1", "https://localhost", "https://127.0.0.1"].contains(where: origin.hasPrefix) {
            return ("403 Forbidden", Data())
        }
        // No event stream to offer.
        guard request.method == "POST" else { return ("405 Method Not Allowed", Data()) }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) else {
            return ("400 Bad Request", encode(error(id: NSNull(), code: -32700, "That isn't JSON.")))
        }
        var replies: [[String: Any]] = []
        for message in message as? [Any] ?? [message] {
            if let reply = await reply(to: message, host: host) { replies.append(reply) }
        }
        // Notifications and responses to us get nothing back.
        guard !replies.isEmpty else { return ("202 Accepted", Data()) }
        return ("200 OK", encode(message is [Any] ? replies : replies[0]))
    }

    private static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: JSON-RPC

    /// The answer to one JSON-RPC message, or nil for a notification.
    static func reply(to message: Any, host: some MCPHost) async -> [String: Any]? {
        guard let message = message as? [String: Any], let method = message["method"] as? String else { return nil }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return result(id: id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false]],
                "serverInfo": ["name": "joinery", "title": "Joinery", "version": "1.0"],
                "instructions": """
                    Joinery is an app for designing SQL databases on a canvas. These tools edit the data model open in \
                    its window: changes appear there at once, save themselves and can be undone. Call get_model before \
                    changing anything. create_tables can make many related tables in one call.

                    A data model can keep named versions, such as "main", "draft 1" and "draft 2": save_version saves \
                    it as it is under a name, and compare shows what changed between any two, or between one and \
                    "current", the model as it is now, as a diff in Joinery's window. list_versions says what there is.

                    To show someone how a change, such as a pull request, alters a database schema, review it: \
                    start_review, draw the schema as it was before with create_tables, save_version named for the \
                    base (such as "main"), apply the change with the editing tools, then compare it with current. When \
                    the change is updated later, save_version the state reviewed so far ("draft 1"), apply what's new, \
                    and compare any pair. The review_schema_changes prompt has the steps in full.

                    To let others edit the open data model live, start_sharing: it shares it through a relay and \
                    returns links to send, one to edit and one only to watch.
                    """,
            ])
        case "ping":
            return result(id: id, [:])
        case "prompts/list":
            return result(id: id, ["prompts": [reviewPrompt]])
        case "prompts/get":
            guard params["name"] as? String == reviewPrompt["name"] as? String else {
                return error(id: id, code: -32602, "There's no prompt called \(params["name"] ?? "").")
            }
            let change = (params["arguments"] as? [String: Any])?["change"] as? String
            return result(id: id, [
                "description": reviewPrompt["description"] ?? "",
                "messages": [["role": "user", "content": ["type": "text", "text": reviewSteps(change.flatMap { $0.isEmpty ? nil : $0 })]]],
            ])
        case "tools/list":
            return result(id: id, ["tools": tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return result(id: id, ["content": [["type": "text", "text": try await call(name, arguments, host: host)]]])
            } catch {
                return result(id: id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return error(id: id, code: -32601, "There's no method called \(method).")
        }
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// Runs a tool, as an assistant's call would.
    static func call(_ name: String, _ arguments: [String: Any], host: some MCPHost) async throws -> String {
        if libraryToolNames.contains(name) { return try await host.callLibraryTool(name, arguments) }
        if VersionTools.handles(name, arguments) { return try await host.withVersions { try VersionTools.call(name, arguments, on: &$0) } }
        guard ModelTools.names.contains(name) else { throw ModelTools.Failure("There's no tool called \(name).") }
        return try await host.edit { try ModelTools.call(name, arguments, on: &$0) }
    }

    // MARK: Tools

    /// Every tool, in the order an assistant meets them: the library's, named versions, then editing the model.
    nonisolated(unsafe) static var tools: [[String: Any]] { libraryTools + VersionTools.definitions + ModelTools.definitions }

    private static var libraryToolNames: Set<String> { Set(libraryTools.compactMap { $0["name"] as? String }) }

    /// The tools the app runs itself (`MCPHost.callLibraryTool`).
    nonisolated(unsafe) static let libraryTools: [[String: Any]] = [
        [
            "name": "list_models",
            "description": "The data models in Joinery's library, by collection, and which one is open.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "open_model",
            "description": "Opens a data model from the library in the window, for the other tools to work on.",
            "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
        ],
        [
            "name": "new_model",
            "description": "Starts an empty data model and opens it.",
            "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
        ],
        [
            "name": "start_review",
            "description": """
                Step 1 of a schema review: showing someone, in Joinery, how a change such as a pull request alters a \
                database schema. Makes a new, empty data model named for the change in the library's Reviews \
                collection and opens it, so the other tools work on it. The steps, in order:
                1. start_review.
                2. Draw the schema as it was BEFORE the change, with create_tables: one call, real table and column \
                names, types, keys and foreign keys. Only the tables the change touches and the tables their foreign \
                keys join, each with all its columns; not the whole database. Then arrange, layout hierarchical.
                3. save_version, named for the base, such as "main".
                4. Make the change with alter_table (rename with rename_to, so a rename shows as one), create_tables, \
                drop_tables, add_foreign_key and remove_foreign_key. Don't arrange or move tables now.
                5. compare from the base to "current", to check the diff shows the change and nothing else, then tell \
                the person what changed. Joinery's window shows it as a diff.
                The review_schema_changes prompt has these steps in full.
                """,
            "inputSchema": [
                "type": "object",
                "properties": ["title": ["type": "string", "description": "What's being reviewed, briefly, such as \"PR 482: refunds\"."]],
                "required": ["title"],
            ],
        ],
        [
            "name": "start_sharing",
            "description": """
                Shares the open data model live, so others can edit it with you in Joinery, by pasting a link into Join. \
                Shares it through the relay set in Joinery's Settings, end-to-end encrypted, and returns two links: one \
                to edit, one only to watch. Calling it while already sharing gives the same links. Anyone with a link \
                can join while sharing lasts, so treat links as passwords.
                """,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
    ]

    // MARK: Prompts

    nonisolated(unsafe) private static let reviewPrompt: [String: Any] = [
        "name": "review_schema_changes",
        "title": "Review schema changes",
        "description": "Shows how a pull request, branch or uncommitted change alters the database schema, as a diff in Joinery.",
        "arguments": [[
            "name": "change",
            "description": "What to review: a pull request's number or URL, a branch, or \"uncommitted changes\". The current branch against its base if left out.",
            "required": false,
        ]],
    ]

    /// The review, step by step, for an assistant to follow.
    static func reviewSteps(_ change: String?) -> String {
        """
        Show me in Joinery how \(change ?? "the current branch") changes the database schema, using the joinery tools.

        1. Find the schema changes in it: migrations (SQL, Rails, Django, Alembic, Prisma, Drizzle, Knex, TypeORM and so \
        on), schema files (schema.sql, structure.sql, db/schema.rb, schema.prisma) and ORM model definitions. If nothing \
        in it changes the schema, tell me so and stop.
        2. Work out the schema BEFORE the change for the tables it touches, from the base (for a branch or pull request, \
        `git show <base>:<path>`), and the tables their foreign keys join. Keep each table's full column list.
        3. Call start_review with a short title naming the change, such as "PR 482: refunds".
        4. Call create_tables once with every table as it was before: real names, types, primary keys, nullability, \
        unique and references, and `schema` if the database has schemas. Then call arrange with layout "hierarchical".
        5. Call save_version named for the base, such as "main" (for an update to a change reviewed before, see below).
        6. Make the change, in the order the migrations do: alter_table to add, drop, change and rename columns and to \
        rename tables (rename_to keeps a rename a rename, instead of a drop and an add); create_tables for new tables; \
        drop_tables for removed ones; add_foreign_key and remove_foreign_key for keys alone. Don't move or arrange tables.
        7. Call compare with from the base and to "current". If it doesn't match the change, fix it with more editing \
        tool calls, not by saving the base again.
        8. Tell me in a few lines what changed, and anything risky about it: data lost with dropped or narrowed columns, \
        NOT NULL columns added to existing tables without a default, foreign keys without an index, renames that \
        running code still uses. Joinery's window shows the diff.

        If Joinery already has a review of this change and the change has been updated since, such as new commits on \
        the pull request: open_model that review instead of steps 3 to 5 and call list_versions. Save the state \
        reviewed so far with save_version (such as "draft 1") unless it's saved already, make only what's new as in \
        step 6, save that too ("draft 2"), and compare each pair that's wanted, such as main → draft 1, draft 1 → \
        draft 2 and main → draft 2.
        """
    }
}
