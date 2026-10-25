import SwiftUI

enum Theme {
    static let canvas = Color(light: .white, dark: NSColor(white: 0.118, alpha: 1))
    static let card = Color(light: .white, dark: NSColor(white: 0.172, alpha: 1))
    static let cardBorder = Color(light: NSColor(white: 0, alpha: 0.1), dark: NSColor(white: 1, alpha: 0.1))
    static let gridDot = Color(light: NSColor(white: 0, alpha: 0.13), dark: NSColor(white: 1, alpha: 0.11))
    static let tie = Color(light: NSColor(white: 0.56, alpha: 1), dark: NSColor(white: 0.64, alpha: 1))
    static let stroke = Color.red
    static let socket = Color(light: NSColor(white: 0, alpha: 0.28), dark: NSColor(white: 1, alpha: 0.3))
}

extension TableColor {
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
