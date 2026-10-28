import Foundation

/// A shared editing session, hosted here or joined: who else is in it, and where they are. See `docs/relay.md`.
@MainActor
protocol Session: AnyObject, Observable {
    /// Everyone else in it, by ID.
    var peers: [String: Peer] { get }
    /// What to show about it: hosting, connected, or why it ended.
    var status: String { get }
    /// Shares where this person's pointer is on the canvas, what they have selected, and what they're dragging.
    func share(_ presence: Relay.Presence)
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
    /// How far they're dragging their selection, in canvas points, before letting go makes it a change.
    var drag: [Double]?
    /// The selection rectangle they're dragging out, as x, y, width and height in canvas points.
    var marquee: [Double]?

    mutating func show(_ presence: Relay.Presence) {
        cursor = presence.cursor
        selection = presence.selection
        drag = presence.drag
        marquee = presence.marquee
    }
}

extension Relay.Presence {
    init(cursor: CGPoint?, selection: some Collection<UUID>, drag: CGPoint? = nil, marquee: CGRect? = nil) {
        self.init(cursor: cursor.map { [$0.x, $0.y] }, selection: selection.map(\.uuidString), drag: drag.map { [$0.x, $0.y] },
                  marquee: marquee.map { [$0.minX, $0.minY, $0.width, $0.height] })
    }
}
