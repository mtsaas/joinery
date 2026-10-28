import Foundation

/// A shared editing session, hosted here or joined: who else is in it, and where they are. See
/// `docs/collaboration.md` for the protocol.
@MainActor
protocol Session: AnyObject, Observable {
    /// Everyone else in it, by ID.
    var peers: [String: Peer] { get }
    /// What to show about it: hosting, connected, or why it ended.
    var status: String { get }
    var isHost: Bool { get }
    /// Shares where this person's pointer is on the canvas, and what they have selected.
    func share(cursor: CGPoint?, selection: [UUID])
    /// Ends it: hosting stops for everyone; joined, this person leaves, keeping their copy.
    func close()
}

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
    // welcome
    var you: String?
    var title: String?
    var entities: [Replica.Entity]?
    var peers: [Peer]?
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
        (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "{}"
    }

    init?(text: String) {
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) else { return nil }
        self = message
    }
}

extension Session {
    /// A name for this person, as others see it.
    static var ownName: String {
        let name = NSFullUserName()
        return name.isEmpty ? NSUserName() : name
    }
}
