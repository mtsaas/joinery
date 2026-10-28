import Foundation

/// Someone in a session.
struct Peer: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// A `TableColor` name, to tell people apart by.
    var color: String
    /// Where their pointer is, in canvas points, if it's over the canvas.
    var cursor: [Double]?
    /// The IDs of what they have selected.
    var selection: [String]?
}

/// Every message either way, as JSON with a `type`; only the fields a type uses are there.
struct Message: Codable {
    var type: String
    // hello
    var `protocol`: Int?
    var token: String?
    var name: String?
    /// Which client this is, the same through reconnecting.
    var client: String?
    // welcome
    var you: String?
    var title: String?
    var entities: [Replica.Entity]?
    var peers: [Peer]?
    /// The last of this client's changes the host has taken, made or turned down.
    var acked: Int?
    /// The document's digest, after the change (`Digest`).
    var hash: String?
    // ops, reject
    var seq: Int?
    var cseq: Int?
    var author: String?
    var ops: [Replica.Op]?
    var reason: String?
    // presence, joined, left
    var peer: Peer?
    var cursor: [Double]?
    var selection: [String]?

    static let version = 1

    init(_ type: String) { self.type = type }

    var text: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    init?(text: String) {
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) else { return nil }
        self = message
    }
}
