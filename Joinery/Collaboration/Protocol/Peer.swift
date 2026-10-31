import Foundation

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
