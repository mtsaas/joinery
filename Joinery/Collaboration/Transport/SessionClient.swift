import Foundation

/// A session joined from a share link, through its relay. Connects `RelayGuestCore`, which keeps the protocol, to a
/// `RelayConnection`: reconnecting when it drops, with what's shown here caught up on reconnecting and nothing made here
/// lost or made twice.
///
/// Like remote access: the model is open here only while the session is, and nothing's kept after.
@MainActor @Observable
final class SessionClient: Session {
    static let leftReason = RelayGuestCore.leftReason

    private(set) var peers: [String: Peer] = [:]
    private(set) var status = "Connecting…"
    /// This person, as others see them, once let in.
    var me: Peer? { core.you.map { Relay.peer($0, name: Array(core.name.utf8)) } }
    /// Whether this link lets this person edit, or only watch.
    var canEdit: Bool { core.canEdit }
    /// Whether presence is going by UDP now, beside the WebSocket.
    var presenceOverUDP: Bool { socket.presenceOverUDP }

    @ObservationIgnored private let core: RelayGuestCore
    @ObservationIgnored private let socket: RelayConnection
    @ObservationIgnored private weak var model: OpenModel?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var reconnecting: Task<Void, Never>?
    /// Heard once let in and sent the host's copy: the session's title and the copy, to open.
    @ObservationIgnored private var onWelcome: ((String, Replica) -> Void)?
    /// The session's title, from the relay's welcome, which comes before the host's copy.
    @ObservationIgnored private var title: String?
    /// Told why, when the host turns down a change made here (which is then taken back).
    @ObservationIgnored var onRefusal: ((String) -> Void)?
    /// Told why, when the session ends: left, or the host stopped.
    @ObservationIgnored var onEnd: ((String) -> Void)?

    /// Connects to the session at `link`, calling `welcomed` with its title and the host's copy once in.
    init?(link text: String, welcomed: @escaping (String, Replica) -> Void) {
        guard let link = Relay.Link(text) else { return nil }
        core = RelayGuestCore(room: link.room, secret: link.secret, key: link.key, name: Self.ownName, canEdit: link.canEdit)
        socket = RelayConnection(link.socket)
        onWelcome = welcomed
        socket.onMessage = { [weak self] bytes in
            guard let self else { return }
            self.perform(self.core.received(bytes, at: .now))
        }
        socket.onClose = { [weak self] in
            guard let self else { return }
            self.perform(self.core.disconnected())
        }
        ticker = ticking(every: .seconds(1)) { [weak self] in
            guard let self else { return }
            self.perform(self.core.tick(at: .now))
        }
        connect()
    }

    /// Joined, with the model opened: changes made to it from now on are shared.
    func attach(to model: OpenModel) {
        self.model = model
        model.adopt(core.shown)
        model.session = self
        model.onChange = { [weak self] ops in
            guard let self else { return }
            self.perform(self.core.changedHere(ops))
        }
    }

    func share(_ presence: Relay.Presence) {
        perform(core.share(presence))
    }

    func close() {
        perform(core.leave())
    }

    private func connect() {
        socket.connect()
        perform(core.connected(at: .now))
    }

    private func perform(_ effects: [RelayGuestCore.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let bytes):
                socket.send(bytes)
            case .show(let replica):
                if let model, model.replica != replica { model.adopt(replica) }
            case .welcomed(let title):
                self.title = title
            case .reconnect(let delay):
                socket.close()
                reconnecting?.cancel()
                reconnecting = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    self?.connect()
                }
            case .refused(let reason):
                onRefusal?(reason)
            case .ended(let reason):
                socket.close()
                ticker?.cancel()
                reconnecting?.cancel()
                onWelcome = nil
                status = reason
                model?.onChange = nil
                if model?.session === self { model?.session = nil }
                onEnd?(reason)
            }
        }
        if let title, core.hasCopy, let welcomed = onWelcome {
            onWelcome = nil
            welcomed(title, core.shown)
        }
        status = switch core.state {
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .ended: status
        }
        let peers = Dictionary(uniqueKeysWithValues: core.peers.values.map { ($0.id, $0) })
        if self.peers != peers { self.peers = peers }
    }
}
