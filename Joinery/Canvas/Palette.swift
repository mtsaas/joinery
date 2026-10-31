import AppKit
import Observation

/// A look for the canvas: its surfaces, and the twelve colors tables and groups can be. One is chosen for light mode
/// and one for dark, in Settings ▸ Themes.
struct Palette: Identifiable, Equatable {
    let name: String
    let canvas: NSColor
    let card: NSColor
    let cardBorder: NSColor
    let gridDot: NSColor
    let tie: NSColor
    let tieHovered: NSColor
    let socket: NSColor
    /// One per `TableColor`, in its order.
    let colors: [NSColor]

    var id: String { name }

    func color(_ color: TableColor) -> NSColor { colors[TableColor.allCases.firstIndex(of: color)!] }
}

/// The palettes chosen for light and dark mode, kept in user defaults. Reading one in a view's body (or a `Canvas`
/// drawn in it) redraws it when the choice changes.
@Observable
final class Themes: @unchecked Sendable { // ponytail: only touched from the main thread
    static let shared = Themes()

    var light: Palette { didSet { UserDefaults.standard.set(light.name, forKey: "lightTheme") } }
    var dark: Palette { didSet { UserDefaults.standard.set(dark.name, forKey: "darkTheme") } }

    private init() {
        let defaults = UserDefaults.standard
        light = Palette.light.first { $0.name == defaults.string(forKey: "lightTheme") } ?? Palette.light[0]
        dark = Palette.dark.first { $0.name == defaults.string(forKey: "darkTheme") } ?? Palette.dark[0]
    }
}

extension Palette {
    /// The first of each is the default.
    static let light = [
        Palette(name: "Joinery Light", canvas: .white, card: .white,
                cardBorder: NSColor(white: 0, alpha: 0.1), gridDot: NSColor(white: 0, alpha: 0.13),
                tie: NSColor(white: 0.56, alpha: 1), tieHovered: NSColor(white: 0.36, alpha: 1),
                socket: NSColor(white: 0, alpha: 0.28), colors: system),
        Palette(name: "Paper", canvas: hex(0xF7F3EA), card: hex(0xFFFDF8),
                cardBorder: hex(0x3C2D14, 0.12), gridDot: hex(0x503C14, 0.16),
                tie: hex(0x9A8F7E), tieHovered: hex(0x5E5546), socket: hex(0x3C2D14, 0.3),
                colors: hexes(0x3E6FB0, 0x7E5AA8, 0xC2588C, 0xC0463B, 0xD47A2C, 0xC9A227,
                              0x4F8F45, 0x2F8F8A, 0x4B54A8, 0x4FA88A, 0x3A93B8, 0x8A6243)),
        Palette(name: "Glacier", canvas: hex(0xF3F7FA), card: .white,
                cardBorder: hex(0x1E466E, 0.12), gridDot: hex(0x1E466E, 0.14),
                tie: hex(0x8A9AAA), tieHovered: hex(0x4A5A6A), socket: hex(0x1E466E, 0.3),
                colors: hexes(0x2F7DE1, 0x8A63D2, 0xE0609A, 0xE2524A, 0xF08A3C, 0xE6B422,
                              0x3DAA6A, 0x1FA5A0, 0x5561D6, 0x3CC7A4, 0x22A9D6, 0x9C7458)),
        Palette(name: "Sage", canvas: hex(0xF2F5F0), card: hex(0xFCFDFB),
                cardBorder: hex(0x284628, 0.12), gridDot: hex(0x284628, 0.14),
                tie: hex(0x8E9A8A), tieHovered: hex(0x556052), socket: hex(0x284628, 0.3),
                colors: hexes(0x4A78A8, 0x8467A0, 0xB86A8E, 0xB85448, 0xC9803F, 0xB89B3A,
                              0x5E8F4E, 0x4A8F86, 0x5A63A0, 0x6AA88C, 0x4F92A8, 0x86684C)),
        // GitHub's Primer colors.
        Palette(name: "GitHub Light", canvas: hex(0xF6F8FA), card: .white,
                cardBorder: hex(0xD0D7DE), gridDot: hex(0x1F2328, 0.12),
                tie: hex(0x8C959F), tieHovered: hex(0x57606A), socket: hex(0x1F2328, 0.3),
                colors: hexes(0x0969DA, 0x8250DF, 0xBF3989, 0xCF222E, 0xBC4C00, 0xBF8700,
                              0x1A7F37, 0x1B7C83, 0x6639BA, 0x2DA44E, 0x218BFF, 0x953800)),
    ]

    static let dark = [
        Palette(name: "Joinery Dark", canvas: NSColor(white: 0.118, alpha: 1), card: NSColor(white: 0.172, alpha: 1),
                cardBorder: NSColor(white: 1, alpha: 0.1), gridDot: NSColor(white: 1, alpha: 0.11),
                tie: NSColor(white: 0.64, alpha: 1), tieHovered: NSColor(white: 0.86, alpha: 1),
                socket: NSColor(white: 1, alpha: 0.3), colors: system),
        Palette(name: "Midnight", canvas: hex(0x0F1420), card: hex(0x182030),
                cardBorder: hex(0xC8D2E4, 0.12), gridDot: hex(0xC8D2E4, 0.1),
                tie: hex(0x6E7A90), tieHovered: hex(0xC8D2E4), socket: hex(0xC8D2E4, 0.3),
                colors: hexes(0x5B9CFF, 0xA88BFF, 0xFF7AB8, 0xFF6B6B, 0xFF9F55, 0xFFD15C,
                              0x5ED38A, 0x3FD0C9, 0x7C86FF, 0x6FE3BE, 0x4CC9F0, 0xC49A74)),
        Palette(name: "Ember", canvas: hex(0x17120E), card: hex(0x221A14),
                cardBorder: hex(0xFFC88C, 0.11), gridDot: hex(0xFFC88C, 0.09),
                tie: hex(0x8A7866), tieHovered: hex(0xE6D2BC), socket: hex(0xFFC88C, 0.28),
                colors: hexes(0x6E9BD1, 0xB08AC9, 0xE48AA8, 0xE8664F, 0xF2934A, 0xF2C14E,
                              0x9BBF6A, 0x6FB8A8, 0x8A8FD6, 0x8FD1B0, 0x6EC0D6, 0xC9946A)),
        Palette(name: "Charcoal", canvas: hex(0x1A1A1A), card: hex(0x262626),
                cardBorder: NSColor(white: 1, alpha: 0.09), gridDot: NSColor(white: 1, alpha: 0.08),
                tie: hex(0x7A7A7A), tieHovered: hex(0xDADADA), socket: NSColor(white: 1, alpha: 0.28),
                colors: hexes(0x7A9CC6, 0xA68FC2, 0xCC8FAE, 0xD9776B, 0xDB9A6B, 0xD6BE7A,
                              0x93B887, 0x7DB5AD, 0x8E93C9, 0x8CC7AE, 0x84B8CC, 0xB59479)),
        Palette(name: "GitHub Dark", canvas: hex(0x0D1117), card: hex(0x161B22),
                cardBorder: hex(0x30363D), gridDot: hex(0xF0F6FC, 0.08),
                tie: hex(0x6E7681), tieHovered: hex(0xC9D1D9), socket: hex(0xF0F6FC, 0.28),
                colors: hexes(0x58A6FF, 0xBC8CFF, 0xF778BA, 0xFF7B72, 0xFFA657, 0xD29922,
                              0x3FB950, 0x39C5CF, 0x8C8CFF, 0x56D364, 0x79C0FF, 0xBD8D5E)),
    ]

    /// The system's colors, which shift a little between light and dark themselves.
    private static let system: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemRed, .systemOrange,
                                            .systemYellow, .systemGreen, .systemTeal, .systemIndigo, .systemMint,
                                            .systemCyan, .systemBrown]

    private static func hex(_ rgb: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    private static func hexes(_ rgbs: Int...) -> [NSColor] { rgbs.map { hex($0) } }
}
