import Foundation

/// The link that opens a session, `https://tunnel.example/#token=…`: made by the host, read by Joinery's Join and by
/// the web client the address serves. The token's after the `#`, so it's never sent in a request for the page.
enum SessionLink {
    /// The link to a session with `token`, reached at `address`, such as a tunnel's `https://…` or `localhost:8724`.
    static func link(to address: String, token: String) -> String {
        var address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://") { address = "http://" + address }
        while address.hasSuffix("/") { address.removeLast() }
        return "\(address)/#token=\(token)"
    }

    /// Where a link points, as a WebSocket address, and its token; nil if it isn't a session's link.
    static func address(of link: String) -> (url: URL, token: String)? {
        guard var parts = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let token = parts.fragment?.split(separator: "&").first(where: { $0.hasPrefix("token=") })?.dropFirst(6), !token.isEmpty
        else { return nil }
        switch parts.scheme {
        case "https", "wss": parts.scheme = "wss"
        case "http", "ws": parts.scheme = "ws"
        default: return nil
        }
        parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url.map { ($0, String(token)) }
    }
}
