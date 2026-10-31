import SwiftUI

/// The canvas's colors, from the palettes chosen in Settings ▸ Themes (see `Themes`).
enum Theme {
    static var canvas: Color { pair(\.canvas) }
    static var card: Color { pair(\.card) }
    static var cardBorder: Color { pair(\.cardBorder) }
    static var gridDot: Color { pair(\.gridDot) }
    static var tie: Color { pair(\.tie) }
    static var tieHovered: Color { pair(\.tieHovered) }
    static let stroke = Color.red
    /// How much darker a selected wire's outline is than the wire.
    static let selectedWireDarkening = 0.2
    /// How much darker a header's edge is than the header.
    static let headerEdgeDarkening = 0.07
    static var socket: Color { pair(\.socket) }
    /// Lines showing a dragged table lining up with another: there, but quiet.
    static let guide = Color.accentColor.opacity(0.45)

    /// Read now, so a view drawing it redraws when the choice changes.
    private static func pair(_ color: KeyPath<Palette, NSColor>) -> Color {
        Color(light: Themes.shared.light[keyPath: color], dark: Themes.shared.dark[keyPath: color])
    }
}

extension TableColor {
    /// The header's background: the card with a wash of the color.
    var headerFill: Color { Theme.card.mix(with: color, by: 0.18) }

    /// The header's edge: its fill, `Theme.headerEdgeDarkening` darker. Opaque, so the card's own edge doesn't show
    /// through it.
    var headerBorder: Color { headerFill.mix(with: .black, by: Theme.headerEdgeDarkening) }

    var color: Color {
        Color(light: Themes.shared.light.color(self), dark: Themes.shared.dark.color(self))
    }
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
}

extension SchemaDiff.Change {
    var color: Color {
        switch self {
        case .added: .green
        case .removed: .red
        case .modified: .orange
        }
    }

    /// Marked so, as well as in color, for those who can't tell the colors apart.
    var mark: String {
        switch self {
        case .added: "+"
        case .removed: "−"
        case .modified: "~"
        }
    }
}
