import SwiftUI

/// Joinery ▸ Settings (⌘,): a sidebar of panes, as System Settings has.
struct SettingsView: View {
    @AppStorage("settingsPane") private var pane = Pane.themes
    @State private var search = ""

    enum Pane: String, CaseIterable, Identifiable {
        case themes, sharing, assistants

        var id: Self { self }

        var title: String {
            switch self {
            case .themes: "Themes"
            case .sharing: "Sharing"
            case .assistants: "AI Assistants"
            }
        }

        var symbol: String {
            switch self {
            case .themes: "paintpalette.fill"
            case .sharing: "person.2.fill"
            case .assistants: "sparkles"
            }
        }

        var tint: Color {
            switch self {
            case .themes: .pink
            case .sharing: .blue
            case .assistants: .purple
            }
        }

        /// What else a search finds it by.
        var keywords: String {
            switch self {
            case .themes: "appearance colors light dark palette canvas"
            case .sharing: "relay collaborate link server"
            case .assistants: "mcp claude server tools"
            }
        }
    }

    private var panes: [Pane] {
        let search = search.trimmingCharacters(in: .whitespaces)
        return search.isEmpty ? Pane.allCases : Pane.allCases.filter { "\($0.title) \($0.keywords)".localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView {
            List(panes, selection: Binding { pane } set: { if let new = $0 { pane = new } }) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    IconTile(symbol: pane.symbol, tint: pane.tint)
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .themes: ThemeSettings()
                case .sharing: SharingSettings()
                case .assistants: AIAssistantSettings()
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

/// A symbol on a rounded square of color, as System Settings marks its panes.
private struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.27))
    }
}

/// Which palette the canvas uses in light mode and in dark.
private struct ThemeSettings: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable private var themes = Themes.shared

    var body: some View {
        Form {
            section("Light Mode", palettes: Palette.light, selection: $themes.light, isDark: false)
            section("Dark Mode", palettes: Palette.dark, selection: $themes.dark, isDark: true)
        }
        .formStyle(.grouped)
    }

    private func section(_ title: String, palettes: [Palette], selection: Binding<Palette>, isDark: Bool) -> some View {
        Section {
            // As many to a row as fit, the rest wrapping, so none is out of sight.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: ThemeCard.size.width), spacing: 14)], spacing: 14) {
                ForEach(palettes) { palette in
                    Button { selection.wrappedValue = palette } label: {
                        ThemeCard(palette: palette, isDark: isDark, isSelected: selection.wrappedValue == palette)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Room for the selection ring, which sits outside each card.
            .padding(ThemeCard.ringOutset)
        } header: {
            HStack(spacing: 4) {
                Text(title)
                if (colorScheme == .dark) == isDark { Text("— Active").foregroundStyle(.secondary) }
            }
        }
    }
}

/// A palette in miniature: a table card on its canvas, and its colors.
private struct ThemeCard: View {
    let palette: Palette
    /// Which mode it's for, so the system colors in the default palettes show as they will there.
    let isDark: Bool
    let isSelected: Bool

    static let size = CGSize(width: 150, height: 84)
    static let cornerRadius: CGFloat = 12
    static let ringWidth: CGFloat = 3
    static let ringGap: CGFloat = 2
    /// The ring's outer edge from the card's, and so its radius over the card's (concentric).
    static let ringOutset = ringWidth + ringGap
    static let padding: CGFloat = 12
    static let dot: CGFloat = 14
    /// The colors fill the card's width, less its padding, each overlapping the last.
    static var dotOverlap: CGFloat {
        let count = CGFloat(TableColor.allCases.count)
        return (count * dot - (size.width - 2 * padding)) / (count - 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            preview
                .frame(width: Self.size.width, height: Self.size.height)
                .background(Color(nsColor: palette.canvas), in: .rect(cornerRadius: Self.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(Color(nsColor: palette.cardBorder))
                }
                .environment(\.colorScheme, isDark ? .dark : .light)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Self.cornerRadius + Self.ringOutset)
                            .strokeBorder(Color.accentColor, lineWidth: Self.ringWidth)
                            .padding(-Self.ringOutset)
                    }
                }
            Text(palette.name)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(.rect)
    }

    private var preview: some View {
        let ink = Color(nsColor: isDark ? .white : .black).opacity(0.85)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Aa").font(.system(size: 24, weight: .regular)).foregroundStyle(ink)
                Spacer()
                miniTable
            }
            Spacer(minLength: 0)
            HStack(spacing: -Self.dotOverlap) {
                ForEach(palette.colors.indices, id: \.self) { index in
                    Circle()
                        .fill(Color(nsColor: palette.colors[index]))
                        .overlay(Circle().strokeBorder(Color(nsColor: palette.canvas), lineWidth: 1))
                        .frame(width: Self.dot, height: Self.dot)
                }
            }
        }
        .padding(Self.padding)
    }

    /// A table: a header washed with the first color, and two rows.
    private var miniTable: some View {
        let card = Color(nsColor: palette.card)
        return VStack(spacing: 0) {
            card.mix(with: Color(nsColor: palette.colors[0]), by: 0.13).frame(height: 10)
            Color(nsColor: palette.cardBorder).frame(height: 1)
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(Color(nsColor: palette.tie)).frame(width: 30, height: 3)
                Capsule().fill(Color(nsColor: palette.tie)).frame(width: 22, height: 3)
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(card)
        }
        .frame(width: 46)
        .clipShape(.rect(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: palette.cardBorder)))
    }
}

/// Which relay sessions go through.
private struct SharingSettings: View {
    @AppStorage("relay") private var relay = ""

    var body: some View {
        Form {
            Section {
                TextField("Relay", text: $relay, prompt: Text(Relay.ours.absoluteString))
                    .textFieldStyle(.roundedBorder)
            } footer: {
                Text("""
                    Sharing goes through a relay, which passes changes between this Mac and everyone who's joined. \
                    It can't read them: everything is encrypted end to end, with a key only the links carry. Give the \
                    address of one you run, such as wss://relay.example.com; left empty, it's one on this Mac. Links \
                    name their relay, so people joining needn't set anything.
                    """)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// How to connect an AI assistant to the MCP server, whether it's running, and a switch to turn it off.
private struct AIAssistantSettings: View {
    @AppStorage("mcpServerEnabled") private var isEnabled = true
    private let server = MCPServer.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: "sparkles", tint: .purple, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MCP Server").font(.headline)
                        status.font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { isEnabled.toggle() } label: {
                        Text(isEnabled ? "Stop Server" : "Start Server").foregroundStyle(isEnabled ? .red : .accentColor)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("""
                    While Joinery is open, it runs an MCP server. An assistant connected to it can read the data model \
                    open in the window and make changes, which appear as they're made, save themselves and undo \
                    with ⌘Z. Before an assistant's first change in a while, Joinery keeps a version to go back to \
                    (the clock button above the canvas). Only apps on this Mac can reach it.
                    """)
                    .foregroundStyle(.secondary)
            }

            Section("Claude Code") {
                Text("Run this in Terminal, then ask Claude to work on your data model:")
                Snippet(text: MCP.setupCommand)
            }

            Section("Claude Desktop and others") {
                Text("Apps that connect to MCP servers by URL can use:")
                Snippet(text: MCP.url)
                Text("Apps that start their servers themselves, like Claude Desktop, can reach it through a bridge. Add this to its configuration (Claude Desktop: Settings ▸ Developer ▸ Edit Config):")
                Snippet(text: MCP.bridgeConfiguration)
            }

            Section("What assistants can do") {
                ForEach(MCP.toolSummaries, id: \.name) { tool in
                    LabeledContent {
                        Text(tool.summary).foregroundStyle(.secondary)
                    } label: {
                        Text(tool.name).font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
        .onChange(of: isEnabled) { if isEnabled { server.start() } else { server.stop() } }
    }

    private var status: some View {
        let (color, text): (Color, String) = switch server.status {
        case .running: (.green, "Running at \(MCP.url)")
        case .starting: (.yellow, "Starting…")
        case .off: (.secondary, "Off")
        case .failed(let reason): (.red, reason)
        }
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).textSelection(.enabled)
        }
    }
}

/// Text to paste somewhere else, with a button that copies it.
private struct Snippet: View {
    let text: String
    @State private var isCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                isCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    isCopied = false
                }
            }
            .labelStyle(.iconOnly)
            .help("Copy")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}
