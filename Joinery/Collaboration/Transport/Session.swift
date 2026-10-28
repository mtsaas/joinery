import Foundation

/// A shared editing session, hosted here or joined: who else is in it, and where they are. See
/// `docs/collaboration.md` for the protocol.
@MainActor
protocol Session: AnyObject, Observable {
    /// Everyone else in it, by ID.
    var peers: [String: Peer] { get }
    /// What to show about it: hosting, connected, or why it ended.
    var status: String { get }
    /// Shares where this person's pointer is on the canvas, and what they have selected.
    func share(cursor: CGPoint?, selection: [UUID])
    /// Ends it: hosting stops for everyone; joined, this person leaves, keeping their copy.
    func close()
}

extension Session {
    /// A name for this person, as others see it.
    static var ownName: String {
        let name = NSFullUserName()
        return name.isEmpty ? NSUserName() : name
    }
}
