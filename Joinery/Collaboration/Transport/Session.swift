import Foundation

/// A shared editing session, hosted here or joined: who else is in it, and where they are. See `docs/relay.md`.
@MainActor
protocol Session: AnyObject, Observable {
    /// Everyone else in it, by ID.
    var peers: [String: Peer] { get }
    /// What to show about it: hosting, connected, or why it ended.
    var status: String { get }
    /// Shares where this person's pointer is on the canvas, and what they have selected.
    func share(cursor: CGPoint?, selection: [UUID])
    /// Ends it: hosting stops for everyone; joined, this person leaves.
    func close()
}

extension Session {
    /// A name for this person, as others see it.
    static var ownName: String {
        let name = NSFullUserName()
        return name.isEmpty ? NSUserName() : name
    }

    /// Where to share through: the relay set in Settings, or ours.
    static var relay: URL {
        URL(string: UserDefaults.standard.string(forKey: "relay") ?? "").flatMap { $0.host == nil ? nil : $0 } ?? Relay.ours
    }
}

/// Someone in a session.
struct Peer: Identifiable, Equatable {
    /// Their peer number in the room, as text.
    var id: String
    var name: String
    /// A `TableColor` name, to tell people apart by.
    var color: String
    /// Where their pointer is, in canvas points, if it's over the canvas.
    var cursor: [Double]?
    /// The IDs of what they have selected.
    var selection: [String]?

    mutating func show(_ presence: Relay.Presence) {
        cursor = presence.cursor
        selection = presence.selection
    }
}
