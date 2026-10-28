import SwiftUI

extension Peer {
    var swiftUIColor: Color { TableColor(rawValue: color)?.color ?? .gray }
    var initials: String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
}

/// Sharing the open model, or the session it's in: how others join, and who's here.
struct SharePanel: View {
    let open: OpenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let host = open.session as? SessionHost {
                hosting(host)
            } else if let session = open.session {
                Label(session.status, systemImage: "person.2.fill").font(.headline)
                if (session as? SessionClient)?.canEdit == false {
                    Text("You can watch, but not edit: the link you joined with is a view link.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let me = (session as? SessionClient)?.me
                people([me].compactMap { $0 } + session.peers.values.sorted { $0.name < $1.name }, you: me?.id)
                Button("Leave Session", role: .destructive) { session.close() }
                    .help("Close the data model and leave the session")
            } else {
                Text("Share Live").font(.headline)
                Text("Others can join through a link and edit with you as you go, in Joinery. Everything is encrypted end to end, and this Mac keeps the data model.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Start Sharing") { open.session = SessionHost(model: open) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private func hosting(_ host: SessionHost) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(host.status, systemImage: "dot.radiowaves.left.and.right").font(.headline)
            if let links = host.links {
                VStack(alignment: .leading, spacing: 8) {
                    CopyLink(title: "Edit link", link: links.edit)
                    CopyLink(title: "View link", link: links.view)
                    Text("Send a link as you would a password: anyone with it can join while you share. Paste it into Join in Joinery's library.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            people([host.me] + host.peers.values.sorted { $0.name < $1.name }, you: host.me.id)
            Button("Stop Sharing", role: .destructive) { host.close() }
                .help("Ends the session for everyone, and the links stop working")
        }
    }

    private func people(_ peers: [Peer], you: Peer.ID?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(peers.count == 1 ? "Only you so far" : "\(peers.count) people").font(.subheadline).foregroundStyle(.secondary)
            ForEach(peers) { peer in
                HStack(spacing: 8) {
                    Avatar(peer: peer)
                    Text(peer.name)
                    if peer.id == you {
                        Text("You").font(.caption).foregroundStyle(.secondary)
                    } else if peer.id == String(Relay.hostPeer) {
                        Text("Host").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A link, shortened, with a button that copies it.
private struct CopyLink: View {
    let title: String
    let link: String
    @State private var copied = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline)
                Text(link).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                copied = true
            }
        }
    }
}

/// Someone's initials on their color.
struct Avatar: View {
    let peer: Peer
    var size: CGFloat = 22

    var body: some View {
        Text(peer.initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(peer.swiftUIColor, in: .circle)
            .help(peer.name)
    }
}

/// Joining a session from its link, in the library.
struct JoinPanel: View {
    @State private var link = ""
    @State private var isInvalid = false
    let library = Library.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join a Shared Data Model").font(.headline)
            TextField("Link", text: $link, prompt: Text("https://…/r/…#key=…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(join)
                .onChange(of: link) { isInvalid = false }
            if isInvalid {
                Text("That isn't a share link. Ask for the whole link: it has #key= in it.").font(.caption).foregroundStyle(.red)
            } else if let status = library.joining?.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Paste the link someone sent you. The data model opens here while the session lasts; nothing is kept after.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Join", action: join)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(link.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear {
            // A link just copied is very likely the one.
            if let copied = NSPasteboard.general.string(forType: .string), Relay.Link(copied) != nil { link = copied }
        }
    }

    private func join() {
        isInvalid = !library.join(link)
    }
}

/// The share button's face: who else is here, or whether it's shared. Its own view, so it's redrawn as people come
/// and go.
struct ShareLabel: View {
    let open: OpenModel

    var body: some View {
        if let session = open.session, !session.peers.isEmpty {
            HStack(spacing: -6) {
                ForEach(session.peers.values.sorted { $0.name < $1.name }.prefix(4)) { Avatar(peer: $0, size: 20) }
            }
        } else {
            Label("Share", systemImage: open.session == nil ? "person.2" : "person.2.fill")
        }
    }
}

/// Everyone else's pointers on the canvas, named, and their selections ringed in their colors.
struct PresenceLayer: View {
    let open: OpenModel
    let tables: [Table]
    let canvas: CanvasController

    var body: some View {
        let peers = open.session.map { Array($0.peers.values) } ?? []
        let frames = Dictionary(tables.map { ($0.id.uuidString, Metrics.frame(of: $0)) }, uniquingKeysWith: { first, _ in first })
        ZStack(alignment: .topLeading) {
            ForEach(peers) { peer in
                ForEach(peer.selection ?? [], id: \.self) { id in
                    if let frame = frames[id] {
                        let gap = Metrics.selectionGap + Metrics.selectionWidth + 2
                        let rect = frame.insetBy(dx: -gap / canvas.zoom, dy: -gap / canvas.zoom)
                        RoundedRectangle(cornerRadius: Metrics.cornerRadius * canvas.zoom + gap)
                            .stroke(peer.swiftUIColor, lineWidth: Metrics.selectionWidth)
                            .frame(width: rect.width * canvas.zoom, height: rect.height * canvas.zoom)
                            .position(canvas.viewPoint(CGPoint(x: rect.midX, y: rect.midY)))
                    }
                }
                if let cursor = peer.cursor, cursor.count == 2 {
                    Pointer(peer: peer)
                        .offset(x: canvas.viewPoint(CGPoint(x: cursor[0], y: cursor[1])).x, y: canvas.viewPoint(CGPoint(x: cursor[0], y: cursor[1])).y)
                        .animation(.linear(duration: 0.08), value: cursor)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private struct Pointer: View {
        let peer: Peer

        var body: some View {
            ZStack(alignment: .topLeading) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(peer.swiftUIColor)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                Text(peer.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(peer.swiftUIColor, in: .capsule)
                    .offset(x: 14, y: 18)
                    .fixedSize()
            }
        }
    }
}

#if DEBUG
extension Notification.Name {
    /// Opens the sharing popover.
    static let showSharing = Notification.Name("JoineryShowSharing")
    /// Opens the Join popover in the library.
    static let showJoin = Notification.Name("JoineryShowJoin")
}
#endif
