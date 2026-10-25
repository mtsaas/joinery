import SwiftUI

enum Theme {
    static let canvas = Color(light: .white, dark: NSColor(white: 0.118, alpha: 1))
    static let card = Color(light: .white, dark: NSColor(white: 0.172, alpha: 1))
    static let cardBorder = Color(light: NSColor(white: 0, alpha: 0.1), dark: NSColor(white: 1, alpha: 0.1))
    static let gridDot = Color(light: NSColor(white: 0, alpha: 0.13), dark: NSColor(white: 1, alpha: 0.11))
    static let tie = Color(light: NSColor(white: 0.56, alpha: 1), dark: NSColor(white: 0.64, alpha: 1))
    static let tieHovered = Color(light: NSColor(white: 0.36, alpha: 1), dark: NSColor(white: 0.86, alpha: 1))
    static let stroke = Color.red
    static let socket = Color(light: NSColor(white: 0, alpha: 0.28), dark: NSColor(white: 1, alpha: 0.3))
}

extension TableColor {
    /// The header's background: a wash of the color.
    var headerFill: Color { color.opacity(0.13) }

    /// The header's edge: a darker shade of its fill, in either appearance.
    func headerBorder(in scheme: ColorScheme) -> Color {
        scheme == .dark ? color.mix(with: .black, by: 0.78) : color.mix(with: .black, by: 0.15).opacity(0.5)
    }

    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .indigo: .indigo
        case .mint: .mint
        case .cyan: .cyan
        case .brown: .brown
        }
    }
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
}
