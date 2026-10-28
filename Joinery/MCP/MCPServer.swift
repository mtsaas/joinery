import AppKit
import Foundation
import Network

/// An MCP server, so AI assistants can read and edit models: Streamable HTTP at `url`, on this Mac only. Edits go to
/// the model open in the window, appear as they're made, save themselves, and undo like any other.
///
/// Stateless and answered with plain JSON: every request is a POST of JSON-RPC, so there are no sessions or event
/// streams to keep.
@MainActor @Observable
final class MCPServer {
    static let shared = MCPServer()
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
    /// Whether it runs, from Settings; on unless turned off.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "mcpServerEnabled") as? Bool ?? true }

    enum Status: Equatable {
        case off, starting, running
        /// Why it couldn't start, usually something else on the port.
        case failed(String)
    }

    private(set) var status = Status.off
    @ObservationIgnored private var listener: NWListener?

    /// Starts listening. If something else has the port, there's simply no server, and Settings says why; the app
    /// works the same.
    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        // Only this Mac: nothing on the network can reach it.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            status = .failed("Couldn't set up the server.")
            return
        }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { Self.receive(on: connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.status = .running
                case .failed(let error), .waiting(let error):
                    self.status = .failed(error == .posix(.EADDRINUSE)
                        ? "Port \(Self.port) is in use by another app, perhaps another copy of Joinery."
                        : error.localizedDescription)
                    self.listener?.cancel()
                    self.listener = nil
                default:
                    break
                }
            }
        }
        status = .starting
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        status = .off
    }

    /// Each tool's name and what it does, in a sentence, for Settings.
    static var toolSummaries: [(name: String, summary: String)] {
        (libraryTools + ModelTools.definitions).compactMap { tool in
            guard let name = tool["name"] as? String, let description = tool["description"] as? String else { return nil }
            return (name, description.split(separator: ".").first.map { $0 + "." } ?? description)
        }
    }

    // MARK: HTTP

    private struct Request {
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

    private static func receive(on connection: NWConnection, buffer: Data = Data()) {
        if buffer.isEmpty { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            MainActor.assumeIsolated {
                let buffer = buffer + (data ?? Data())
                if let request = Request(buffer) {
                    respond(to: request, on: connection)
                } else if isComplete || error != nil || buffer.count > 8 << 20 {
                    connection.cancel()
                } else {
                    receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private static func respond(to request: Request, on connection: NWConnection) {
        Task { await respond(to: request, on: connection) }
    }

    private static func respond(to request: Request, on connection: NWConnection) async {
        let (status, body) = await response(to: request)
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        if status.hasPrefix("405") { head += "Allow: POST\r\n" }
        connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func response(to request: Request) async -> (status: String, body: Data) {
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
            if let reply = await reply(to: message) { replies.append(reply) }
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
    static func reply(to message: Any) async -> [String: Any]? {
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
                    Joinery is a Mac app for designing SQL databases on a canvas. These tools edit the data model open in its \
                    window: changes appear there at once, save themselves and can be undone. Call get_model before \
                    changing anything. create_tables can make many related tables in one call.

                    To show someone how a change, such as a pull request, alters a database schema, review it: \
                    start_review, draw the schema as it was before with create_tables, mark_baseline, apply the change \
                    with the editing tools, then get_changes. Joinery shows the result as a diff. The \
                    review_schema_changes prompt has the steps in full.

                    To let others edit the open data model live, start_sharing: it serves it on a port of this Mac. \
                    Expose that port publicly with a tunnel, then call start_sharing again with the tunnel's address \
                    for the link to send.
                    """,
            ])
        case "ping":
            return result(id: id, [:])
        case "prompts/list":
            return result(id: id, ["prompts": [reviewPrompt]])
        case "prompts/get":
            guard params["name"] as? String == reviewPrompt["name"] as? String else {
                return Self.error(id: id, code: -32602, "There's no prompt called \(params["name"] ?? "").")
            }
            let change = (params["arguments"] as? [String: Any])?["change"] as? String
            return result(id: id, [
                "description": reviewPrompt["description"] ?? "",
                "messages": [["role": "user", "content": ["type": "text", "text": reviewSteps(change.flatMap { $0.isEmpty ? nil : $0 })]]],
            ])
        case "tools/list":
            return result(id: id, ["tools": libraryTools + ModelTools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return result(id: id, ["content": [["type": "text", "text": try await call(name, arguments)]]])
            } catch {
                return result(id: id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return Self.error(id: id, code: -32601, "There's no method called \(method).")
        }
    }

    private static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: Any, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    // MARK: Tools

    private static let libraryTools: [[String: Any]] = [
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
                3. mark_baseline.
                4. Make the change with alter_table (rename with rename_to, so a rename shows as one), create_tables, \
                drop_tables, add_foreign_key and remove_foreign_key. Don't arrange or move tables now.
                5. get_changes, to check the diff shows the change and nothing else, then tell the person what changed. \
                Joinery's window shows it as a diff.
                The review_schema_changes prompt has these steps in full.
                """,
            "inputSchema": [
                "type": "object",
                "properties": ["title": ["type": "string", "description": "What's being reviewed, briefly, such as \"PR 482: refunds\"."]],
                "required": ["title"],
            ],
        ],
        [
            "name": "mark_baseline",
            "description": """
                Step 3 of a schema review (see start_review): takes the open data model as it is now as the schema \
                BEFORE the change. From then on Joinery shows the model as a diff against it: tables, columns and \
                foreign keys added in green, removed in red, changed columns as they were and as they are. Call it once \
                the before schema is complete and arranged, and before making any of the change. Calling it again \
                starts the comparison over from the model as it is then, so don't, to correct a mistake: undo it with \
                the editing tools instead.
                """,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "get_changes",
            "description": """
                Step 5 of a schema review (see start_review): what's changed in the open data model since \
                mark_baseline. Tables added, removed and changed; each changed column as it was → as it is; foreign \
                keys added and removed. Use it to check the diff shows the change under review, nothing missing and \
                nothing extra, and to sum it up for the person.
                """,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "start_sharing",
            "description": """
                Shares the open data model live, so others can edit it with you: in a browser, or in Joinery with Join. \
                Serves it on a port of this Mac, for this Mac only, and returns the port and the link. To share beyond \
                this Mac, expose the port with a tunnel (such as `cloudflared tunnel --url http://localhost:<port>` or \
                `ngrok http <port>`), then call start_sharing again with the tunnel's public address to get the link to \
                send. Calling it while already sharing keeps the session and its link's token, only giving the link at \
                the new address. The link's token gives full editing, so treat it as a password.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "address": ["type": "string", "description": "Where others reach the port, such as the tunnel's https://… address. This Mac's own address if left out."],
                    "port": ["type": "integer", "description": "The port to serve on, when first starting; 8724 if left out."],
                ],
            ],
        ],
    ]

    // MARK: Prompts

    private static let reviewPrompt: [String: Any] = [
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
        5. Call mark_baseline.
        6. Make the change, in the order the migrations do: alter_table to add, drop, change and rename columns and to \
        rename tables (rename_to keeps a rename a rename, instead of a drop and an add); create_tables for new tables; \
        drop_tables for removed ones; add_foreign_key and remove_foreign_key for keys alone. Don't move or arrange tables.
        7. Call get_changes. If it doesn't match the change, fix it with more editing tool calls, not mark_baseline.
        8. Tell me in a few lines what changed, and anything risky about it: data lost with dropped or narrowed columns, \
        NOT NULL columns added to existing tables without a default, foreign keys without an index, renames that \
        running code still uses. Joinery's window shows the diff.
        """
    }

    /// Runs a tool, as an assistant's call would.
    static func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        let library = Library.shared
        let all = library.models + library.collections.flatMap(\.models)
        switch name {
        case "list_models":
            let lines = all.map { url in
                let collection = library.collection(of: url).map { $0.lastPathComponent + "/" } ?? ""
                return "- " + collection + Library.name(of: url) + (url == library.selection ? " (open)" : "")
            }
            return lines.isEmpty ? "The library is empty." : lines.joined(separator: "\n")
        case "open_model":
            let wanted = (arguments["name"] as? String ?? "").lowercased()
            guard let url = all.first(where: { Library.name(of: $0).lowercased() == wanted }) else {
                throw ModelTools.Failure("There's no data model called \(arguments["name"] ?? ""). Use list_models to see them.")
            }
            library.selection = url
            return "Opened \(Library.name(of: url))."
        case "new_model":
            library.newModel(in: library.selection.flatMap(library.collection(of:)))
            if let url = library.selection, let wanted = arguments["name"] as? String, !wanted.isEmpty {
                library.rename(url, to: wanted)
            }
            return "Opened a new, empty data model: \(library.open?.name ?? "Untitled Data Model")."
        case "start_review":
            // Names can't hold these.
            let title = (arguments["title"] as? String ?? "").replacingOccurrences(of: ":", with: " –")
                .replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            library.newModel(in: try library.reviewsCollection(), named: title.isEmpty ? "Review" : title)
            guard let open = library.open else { throw ModelTools.Failure("Couldn't start a review: \(library.failure ?? "no data model opened").") }
            return "Opened \(open.name), a new, empty data model in Reviews. Next, draw the schema as it was before the change with create_tables, arrange it, then call mark_baseline."
        case "mark_baseline", "get_changes":
            guard let open = library.open else { throw ModelTools.Failure("No data model is open in Joinery. Use start_review first.") }
            if name == "mark_baseline" {
                guard !open.model.tables.isEmpty else {
                    throw ModelTools.Failure("The data model is empty. Draw the schema as it was before the change with create_tables first.")
                }
                try open.markBaseline()
                return "Took the \(open.model.tables.count) tables in \(open.name) as the baseline: Joinery now shows changes from here as a diff. Next, make the change with alter_table, create_tables, drop_tables, add_foreign_key and remove_foreign_key."
            }
            guard let baseline = open.baseline else { throw ModelTools.Failure("There's no baseline to compare with: call mark_baseline first.") }
            return SchemaDiff(from: baseline, to: open.model).report
        case "start_sharing":
            guard let open = library.open else { throw ModelTools.Failure("No data model is open in Joinery. Use open_model or new_model first.") }
            if open.session != nil, !(open.session is SessionHost) {
                throw ModelTools.Failure("\(open.name) is a session joined from someone else; only its host can share it.")
            }
            let host = try open.session as? SessionHost ?? SessionHost(model: open, port: (arguments["port"] as? Int).flatMap(UInt16.init(exactly:)) ?? SessionHost.defaultPort)
            open.session = host
            // The port is taken, or isn't, a moment after starting.
            for _ in 0..<100 where host.port == nil && open.session === host { try? await Task.sleep(for: .milliseconds(20)) }
            guard let port = host.port, open.session === host else { throw ModelTools.Failure("Couldn't start sharing: \(host.status)") }
            let address = (arguments["address"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // The share panel shows the same link.
            if let address { UserDefaults.standard.set(address, forKey: "sessionAddress") }
            let link = host.link(at: address ?? "localhost:\(port)")
            let others = host.peers.isEmpty ? "No one else has joined yet." : "\(host.peers.count) others have joined."
            return address == nil
                ? "Sharing \(open.name) on port \(port), on this Mac only, at \(link). To share beyond this Mac, expose port \(port) with a tunnel, then call start_sharing again with its public address. \(others)"
                : "Sharing \(open.name) at \(link): send that link to whoever should edit it, as you would a password. It opens in a browser, or in Joinery with Join. Make sure the tunnel forwards to port \(port). \(others)"
        default:
            guard ModelTools.names.contains(name) else { throw ModelTools.Failure("There's no tool called \(name).") }
            guard let open = library.open else {
                throw ModelTools.Failure("No data model is open in Joinery. Use open_model or new_model first.")
            }
            var model = open.model
            let result = try ModelTools.call(name, arguments, on: &model)
            open.change(to: model, byAssistant: true)
            return result
        }
    }
}
