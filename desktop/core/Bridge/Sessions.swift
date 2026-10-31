import Foundation

/// A live session on the open model, through a relay, as the Mac's `SessionHost` and `SessionClient` run one: the
/// protocol is the core's state machines, and the shell holds the WebSocket. Bytes to send, links, people and status go
/// out as events; bytes heard come in through `received`.
final class Sessions {
    private enum Role {
        case host(RelayHostCore, relay: URL)
        case guest(RelayGuestCore)
    }

    private var role: Role?
    private let workspace: Workspace
    /// A guest's: the session's title, once welcomed, and whether the host's copy has been opened.
    private var title: String?
    private var opened = false

    init(workspace: Workspace) { self.workspace = workspace }

    /// Starts sharing the open model through `relay`; the shell then connects to `socket` in the `connect` event.
    func host(relay: String, name: String, title: String) throws {
        guard let url = URL(string: relay), url.host != nil else { throw Edits.Failure("“\(relay)” isn't a relay's address.") }
        let core = RelayHostCore(workspace.replica, title: title, name: name)
        role = .host(core, relay: url)
        workspace.onChange = { [weak self] ops in self?.perform(core.changedHere(ops)) }
        Events.post(["type": "connect", "socket": Relay.socket(of: url).absoluteString])
    }

    /// Joins the session a share link names.
    func join(link: String, name: String) throws {
        guard let link = Relay.Link(link) else { throw Edits.Failure("That isn't a Joinery share link.") }
        let core = RelayGuestCore(room: link.room, secret: link.secret, key: link.key, name: name, canEdit: link.canEdit)
        role = .guest(core)
        title = nil
        opened = false
        Events.post(["type": "connect", "socket": link.socket.absoluteString])
    }

    func connected() {
        switch role {
        case .host(let core, _): perform(core.connected(at: .now))
        case .guest(let core): perform(core.connected(at: .now))
        case nil: break
        }
    }

    func disconnected() {
        switch role {
        case .host(let core, _): perform(core.disconnected())
        case .guest(let core): perform(core.disconnected())
        case nil: break
        }
    }

    func received(_ bytes: [UInt8]) {
        switch role {
        case .host(let core, _): perform(core.received(bytes, at: .now))
        case .guest(let core): perform(core.received(bytes, at: .now))
        case nil: break
        }
    }

    /// Once a second, for pings and timeouts.
    func tick() {
        switch role {
        case .host(let core, _): perform(core.tick(at: .now))
        case .guest(let core): perform(core.tick(at: .now))
        case nil: break
        }
    }

    func share(_ presence: Relay.Presence) {
        switch role {
        case .host(let core, _): perform(core.share(presence))
        case .guest(let core): perform(core.share(presence))
        case nil: break
        }
    }

    func leave() {
        switch role {
        case .host(let core, _): perform(core.stop("The host stopped sharing."))
        case .guest(let core): perform(core.leave())
        case nil: break
        }
    }

    private func perform(_ effects: [RelayHostCore.Effect]) {
        guard case .host(let core, let relay) = role else { return }
        for effect in effects {
            switch effect {
            case .send(let bytes): send(bytes)
            case .apply(let ops): workspace.applyFromSession(ops)
            case .shared(let welcome):
                let link = { (secret: String, canEdit: Bool) in
                    Relay.Link(relay: relay, room: welcome.room, key: core.key, secret: secret, canEdit: canEdit).text
                }
                Events.post(["type": "links", "edit": link(welcome.guestSecret, true), "view": link(welcome.viewSecret, false)])
            case .reconnect(let delay): Events.post(["type": "reconnect", "after": delay])
            case .ended(let reason): end(reason)
            }
        }
        report(state: core.state, peers: core.peers.values.map { $0 }, me: core.me, labels: ("Connecting to the relay…", "Sharing", "Reconnecting to the relay…"))
    }

    private func perform(_ effects: [RelayGuestCore.Effect]) {
        guard case .guest(let core) = role else { return }
        for effect in effects {
            switch effect {
            case .send(let bytes): send(bytes)
            case .show(let replica): if opened, workspace.replica != replica { workspace.adopt(replica) }
            case .welcomed(let title): self.title = title
            case .reconnect(let delay): Events.post(["type": "reconnect", "after": delay])
            case .refused(let reason): Events.post(["type": "refused", "reason": reason])
            case .ended(let reason): end(reason)
            }
        }
        if !opened, let title, core.hasCopy {
            opened = true
            workspace.open(core.shown.model, baseline: nil)
            workspace.adopt(core.shown)
            workspace.onChange = { [weak self] ops in self?.perform(core.changedHere(ops)) }
            Events.post(["type": "joined", "title": title, "canEdit": core.canEdit])
        }
        let me = core.you.map { Relay.peer($0, name: Array(core.name.utf8)) }
        report(state: core.state, peers: core.peers.values.map { $0 }, me: me, labels: ("Connecting…", "Connected", "Reconnecting…"))
    }

    private func report(state: RelayHostCore.State, peers: [Peer], me: Peer?, labels: (String, String, String)) {
        let status = switch state {
        case .connecting: labels.0
        case .connected: labels.1
        case .reconnecting: labels.2
        case .ended: ""
        }
        if !status.isEmpty { Events.post(["type": "status", "status": status]) }
        Events.post(["type": "peers", "me": me.map(Self.describe) ?? NSNull(), "peers": peers.map(Self.describe)])
    }

    private func report(state: RelayGuestCore.State, peers: [Peer], me: Peer?, labels: (String, String, String)) {
        let hostState: RelayHostCore.State = switch state {
        case .connecting: .connecting
        case .connected: .connected
        case .reconnecting: .reconnecting
        case .ended: .ended
        }
        report(state: hostState, peers: peers, me: me, labels: labels)
    }

    private func send(_ bytes: [UInt8]) {
        Events.post(["type": "send", "data": Data(bytes).base64EncodedString()])
    }

    private func end(_ reason: String) {
        workspace.onChange = nil
        role = nil
        Events.post(["type": "ended", "reason": reason])
    }

    private static func describe(_ peer: Peer) -> [String: Any] {
        ["id": peer.id, "name": peer.name, "color": peer.color, "cursor": peer.cursor ?? NSNull(),
         "selection": peer.selection ?? NSNull(), "drag": peer.drag ?? NSNull(), "marquee": peer.marquee ?? NSNull()]
    }
}
