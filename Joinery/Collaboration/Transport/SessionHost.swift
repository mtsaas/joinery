import CryptoKit
import Foundation

/// Hosts a session on the open model, through a relay: connects out to it, and others join with the links it makes.
/// Connects `RelayHostCore`, which keeps the protocol, to a `RelaySocket`, reconnecting when it drops.
@MainActor @Observable
final class SessionHost: Session {
    var me: Peer { core.me }
    private(set) var peers: [String: Peer] = [:]
    private(set) var status = "Connecting to the relay…"
    /// The links to send, once the relay's made the room: one to edit, one only to watch.
    private(set) var links: (edit: String, view: String)?

    @ObservationIgnored private let core: RelayHostCore
    @ObservationIgnored private let relay: URL
    @ObservationIgnored private let socket: RelaySocket
    @ObservationIgnored private weak var model: OpenModel?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var reconnecting: Task<Void, Never>?

    /// Starts sharing the open model through `relay`.
    init(model: OpenModel, relay: URL = SessionHost.relay) {
        self.model = model
        self.relay = relay
        core = RelayHostCore(model.replica, title: model.name, name: Self.ownName)
        socket = RelaySocket(Relay.socket(of: relay))
        socket.onMessage = { [weak self] bytes in
            guard let self else { return }
            self.perform(self.core.received(bytes, at: .now))
        }
        socket.onClose = { [weak self] in
            guard let self else { return }
            self.perform(self.core.disconnected())
        }
        model.onChange = { [weak self] ops in
            guard let self else { return }
            self.perform(self.core.changedHere(ops))
        }
        ticker = ticking(every: .seconds(1)) { [weak self] in
            guard let self else { return }
            self.perform(self.core.tick(at: .now))
        }
        connect()
    }

    func share(cursor: CGPoint?, selection: [UUID], drag: CGPoint?) {
        perform(core.share(Relay.Presence(cursor: cursor, selection: selection, drag: drag)))
    }

    func close() {
        perform(core.stop("The host stopped sharing."))
    }

    private func connect() {
        socket.connect()
        perform(core.connected(at: .now))
    }

    private func perform(_ effects: [RelayHostCore.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let bytes):
                socket.send(bytes)
            case .apply(let ops):
                model?.applyFromSession(ops)
            case .shared(let welcome):
                let link = { (secret: String, canEdit: Bool) in
                    Relay.Link(relay: self.relay, room: welcome.room, key: self.core.key, secret: secret, canEdit: canEdit).text
                }
                links = (link(welcome.guestSecret, true), link(welcome.viewSecret, false))
            case .reconnect(let delay):
                socket.close()
                reconnecting?.cancel()
                reconnecting = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    self?.connect()
                }
            case .ended(let reason):
                // What's queued, the goodbye among it, goes before the connection's let go.
                Task { [socket] in
                    try? await Task.sleep(for: .milliseconds(500))
                    socket.close()
                }
                ticker?.cancel()
                reconnecting?.cancel()
                status = reason
                links = nil
                model?.onChange = nil
                if model?.session === self { model?.session = nil }
            }
        }
        if core.state != .ended {
            status = switch core.state {
            case .connecting: "Connecting to the relay…"
            case .connected: "Sharing"
            case .reconnecting: "Reconnecting to the relay…"
            case .ended: status
            }
        }
        let peers = Dictionary(uniqueKeysWithValues: core.peers.values.map { ($0.id, $0) })
        if self.peers != peers { self.peers = peers }
    }
}
