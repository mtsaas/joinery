import AppKit
import Foundation
import Network

/// An MCP server, so AI assistants can read and edit schemas: Streamable HTTP at `url`, on this Mac only. Edits go to
/// the schema open in the window, appear as they're made, save themselves, and undo like any other.
///
/// Stateless and answered with plain JSON: every request is a POST of JSON-RPC, so there are no sessions or event
/// streams to keep.
@MainActor
final class MCPServer {
    static let shared = MCPServer()
    static let port: UInt16 = 8723
    static let url = "http://127.0.0.1:\(port)/mcp"
    /// For Claude Code; other assistants take `url` in their own settings.
    static let setupCommand = "claude mcp add --transport http joinery \(url)"

    private var listener: NWListener?

    /// Starts listening. If something else has the port, there's simply no server; the app works the same.
    func start() {
        let parameters = NWParameters.tcp
        // Only this Mac: nothing on the network can reach it.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { connection in
            MainActor.assumeIsolated { Self.receive(on: connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
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
        let (status, body) = response(to: request)
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        if status.hasPrefix("405") { head += "Allow: POST\r\n" }
        connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func response(to request: Request) -> (status: String, body: Data) {
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
        let replies = (message as? [Any] ?? [message]).compactMap { reply(to: $0) }
        // Notifications and responses to us get nothing back.
        guard !replies.isEmpty else { return ("202 Accepted", Data()) }
        return ("200 OK", encode(message is [Any] ? replies : replies[0]))
    }

    private static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: JSON-RPC

    private static func reply(to message: Any) -> [String: Any]? {
        guard let message = message as? [String: Any], let method = message["method"] as? String else { return nil }
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return result(id: id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "joinery", "title": "Joinery", "version": "1.0"],
                "instructions": """
                    Joinery is a Mac app for designing SQL schemas on a canvas. These tools edit the schema open in its \
                    window: changes appear there at once, save themselves and can be undone. Call get_schema before \
                    changing anything. create_tables can make many related tables in one call.
                    """,
            ])
        case "ping":
            return result(id: id, [:])
        case "tools/list":
            return result(id: id, ["tools": libraryTools + SchemaTools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return result(id: id, ["content": [["type": "text", "text": try call(name, arguments)]]])
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
            "name": "list_schemas",
            "description": "The schemas in Joinery's library, by collection, and which one is open.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": "open_schema",
            "description": "Opens a schema from the library in the window, for the other tools to work on.",
            "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
        ],
        [
            "name": "new_schema",
            "description": "Starts an empty schema and opens it.",
            "inputSchema": ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"]],
        ],
    ]

    private static func call(_ name: String, _ arguments: [String: Any]) throws -> String {
        let library = Library.shared
        let all = library.schemas + library.collections.flatMap(\.schemas)
        switch name {
        case "list_schemas":
            let lines = all.map { url in
                let collection = library.collection(of: url).map { $0.lastPathComponent + "/" } ?? ""
                return "- " + collection + Library.name(of: url) + (url == library.selection ? " (open)" : "")
            }
            return lines.isEmpty ? "The library is empty." : lines.joined(separator: "\n")
        case "open_schema":
            let wanted = (arguments["name"] as? String ?? "").lowercased()
            guard let url = all.first(where: { Library.name(of: $0).lowercased() == wanted }) else {
                throw SchemaTools.Failure("There's no schema called \(arguments["name"] ?? ""). Use list_schemas to see them.")
            }
            library.selection = url
            return "Opened \(Library.name(of: url))."
        case "new_schema":
            library.newSchema(in: library.selection.flatMap(library.collection(of:)))
            if let url = library.selection, let wanted = arguments["name"] as? String, !wanted.isEmpty {
                library.rename(url, to: wanted)
            }
            return "Opened a new, empty schema: \(library.open?.name ?? "Untitled Schema")."
        default:
            guard SchemaTools.names.contains(name) else { throw SchemaTools.Failure("There's no tool called \(name).") }
            guard let open = library.open else {
                throw SchemaTools.Failure("No schema is open in Joinery. Use open_schema or new_schema first.")
            }
            var schema = open.schema
            let result = try SchemaTools.call(name, arguments, on: &schema)
            open.change(to: schema)
            return result
        }
    }
}
