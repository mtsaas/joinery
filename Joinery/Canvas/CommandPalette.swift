import SwiftUI

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    var subtitle: String?
    let symbol: String
    /// Shown at the trailing edge, as on a menu item.
    var shortcut: String?
    var isDestructive = false
    /// The symbol's color, if it shows one, as a color to choose does.
    var tint: Color?
    let action: () -> Void

    /// How well `query` matches `text` as letters in order, higher being better: consecutive letters and letters
    /// starting words count extra. Nil if it doesn't match.
    static func score(_ query: String, in text: String) -> Int? {
        let query = Array(query.lowercased().filter { !$0.isWhitespace }), text = Array(text.lowercased())
        var score = 0, start = 0, previous = -2
        for character in query {
            guard let found = text[start...].firstIndex(of: character) else { return nil }
            score += found == previous + 1 ? 3 : 1
            if found == 0 || [" ", "_", "."].contains(text[found - 1]) { score += 2 }
            previous = found
            start = found + 1
        }
        return score
    }
}

/// ⌘K: a search field over every command and table, Spotlight-style. Arrow keys move, Return runs, Escape closes.
struct CommandPalette: View {
    let commands: [PaletteCommand]
    /// Which match is highlighted; the canvas's key monitor moves it with the arrow keys.
    @Binding var highlight: Int
    let dismiss: () -> Void

    @State private var query = ""
    @FocusState private var isFocused: Bool

    private static let width: CGFloat = 560
    private static let cornerRadius: CGFloat = 18
    /// Between the panel's edge and the rows; rows are rounded at `cornerRadius - inset`, concentric with the panel.
    private static let inset: CGFloat = 6
    private static let rowHeight: CGFloat = 36
    private static let maxListHeight: CGFloat = 340

    /// Best match first, then the shorter (closer) title; otherwise they keep their order, so an empty query lists
    /// New Table first.
    private var matches: [PaletteCommand] {
        guard !query.isEmpty else { return commands }
        return commands.enumerated()
            .compactMap { index, command in PaletteCommand.score(query, in: command.title).map { (command, $0, index) } }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.title.count != b.0.title.count { return a.0.title.count < b.0.title.count }
                return a.2 < b.2
            }
            .map(\.0)
    }

    var body: some View {
        let matches = matches
        let selected = matches.isEmpty ? nil : min(max(highlight, 0), matches.count - 1)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search commands and tables", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($isFocused)
                    // Worked out now, not when the field was set up: it keeps its first submit action.
                    .onSubmit(runHighlighted)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Divider()
            if matches.isEmpty {
                Text("No Matches")
                    .foregroundStyle(.secondary)
                    .frame(height: Self.rowHeight + Self.inset * 2)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                                row(command, isHighlighted: index == selected)
                                    .id(command.id)
                                    .onHover { if $0 { highlight = index } }
                                    .onTapGesture { run(command) }
                            }
                        }
                        .padding(Self.inset)
                    }
                    .frame(height: min(CGFloat(matches.count) * Self.rowHeight + Self.inset * 2, Self.maxListHeight))
                    .onChange(of: selected) { if let selected { proxy.scrollTo(matches[selected].id) } }
                }
            }
        }
        .frame(width: Self.width)
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cornerRadius))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .onAppear { isFocused = true }
        .onChange(of: query) { highlight = 0 }
    }

    private func row(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .foregroundStyle(command.tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.foreground))
                .frame(width: 20)
            Text(command.title)
            if let subtitle = command.subtitle {
                Text(subtitle)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 12)
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .foregroundStyle(isHighlighted ? .white : .primary)
        .background(isHighlighted ? Color.accentColor : .clear, in: .rect(cornerRadius: Self.cornerRadius - Self.inset))
        .contentShape(.rect)
    }

    private func runHighlighted() {
        let matches = matches
        guard !matches.isEmpty else { return }
        run(matches[min(max(highlight, 0), matches.count - 1)])
    }

    private func run(_ command: PaletteCommand) {
        dismiss()
        command.action()
    }
}
