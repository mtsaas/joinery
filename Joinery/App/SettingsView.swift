import SwiftUI

/// Joinery ▸ Settings (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            SharingSettings()
                .tabItem { Label("Sharing", systemImage: "person.2") }
            AIAssistantSettings()
                .tabItem { Label("AI Assistants", systemImage: "sparkles") }
        }
        .frame(width: 580)
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
                Toggle("Let AI assistants read and edit data models", isOn: $isEnabled)
                LabeledContent("Server") { status }
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
