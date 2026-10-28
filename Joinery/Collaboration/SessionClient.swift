import Foundation

/// A session joined from a host's link. The host's copy is the true one: changes made here show at once and are sent
/// on, and the host's changes, everyone's in one order, are laid under them as they arrive. A change the host turns
/// down (on something since deleted, say) is taken back.
///
/// The model is kept as a file in the library's Shared collection, so it's there, as it was, after the session ends.
@MainActor @Observable
final class SessionClient: Session {
    private(set) var peers: [String: Peer] = [:]
    private(set) var status = "Connecting…"
    var isHost: Bool { false }

    @ObservationIgnored private let task: URLSessionWebSocketTask
    @ObservationIgnored private let token: String
    @ObservationIgnored private weak var model: OpenModel?
    /// Who this is, to the host.
    @ObservationIgnored private var you: String?
    /// The host's copy, as far as it's been heard.
    @ObservationIgnored private var confirmed = Replica()
    /// Changes made here the host hasn't confirmed yet, in order.
    @ObservationIgnored private var pending: [(cseq: Int, ops: [Replica.Op])] = []
    @ObservationIgnored private var cseq = 0
    /// Heard once welcomed: the session's title and the host's copy, to open.
    @ObservationIgnored private var onWelcome: ((String, Replica) -> Void)?

    /// Where a link points, as a socket address, and its token; nil if it isn't a session link.
    static func address(of link: String) -> (url: URL, token: String)? {
        guard var parts = URLComponents(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let token = parts.fragment?.split(separator: "&").first(where: { $0.hasPrefix("token=") })?.dropFirst(6), !token.isEmpty
        else { return nil }
        switch parts.scheme {
        case "https", "wss": parts.scheme = "wss"
        case "http", "ws": parts.scheme = "ws"
        default: return nil
        }
        parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url.map { ($0, String(token)) }
    }

    /// Connects to the session at `link`, calling `welcomed` with its title and the host's copy once in.
    init?(link: String, welcomed: @escaping (String, Replica) -> Void) {
        guard let (url, token) = Self.address(of: link) else { return nil }
        self.token = token
        task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = SocketPeer.maximumMessage
        onWelcome = welcomed
        task.resume()
        var hello = Message("hello")
        hello.protocol = Message.version
        hello.token = token
        hello.name = Self.ownName
        send(hello)
        receive()
    }

    /// Joined, with the model opened: changes made to it from now on are shared.
    func attach(to model: OpenModel) {
        self.model = model
        model.adopt(confirmed)
        model.session = self
        model.onChange = { [weak self] ops in self?.submit(ops) }
    }

    func share(cursor: CGPoint?, selection: [UUID]) {
        var message = Message("presence")
        message.cursor = cursor.map { [$0.x, $0.y] }
        message.selection = selection.map(\.uuidString)
        send(message)
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        end("Left the session. This copy is yours to keep.")
    }

    // MARK: Messages

    private func submit(_ ops: [Replica.Op]) {
        guard !ops.isEmpty, you != nil else { return }
        cseq += 1
        pending.append((cseq, ops))
        var message = Message("ops")
        message.cseq = cseq
        message.ops = ops
        send(message)
    }

    private func send(_ message: Message) {
        task.send(.string(message.text)) { _ in }
    }

    private func receive() {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(.string(let text)):
                    if let message = Message(text: text) { self.handle(message) }
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    self.end(self.you == nil ? "Couldn't join: check the link, and that its host is still sharing." : "The session ended. This copy is yours to keep.")
                }
            }
        }
    }

    private func handle(_ message: Message) {
        switch message.type {
        case "welcome":
            you = message.you
            for entity in message.entities ?? [] { confirmed.apply(.put(entity)) }
            peers = Dictionary((message.peers ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            status = "Connected"
            onWelcome?(message.title ?? "Shared Data Model", confirmed)
            onWelcome = nil
        case "ops":
            _ = confirmed.apply(message.ops ?? [])
            if message.author == you, let cseq = message.cseq, pending.first?.cseq == cseq { pending.removeFirst() }
            relayPending()
        case "reject":
            guard let cseq = message.cseq else {
                return end(message.reason ?? "The host turned this copy away.")
            }
            pending.removeAll { $0.cseq == cseq }
            relayPending()
            Library.shared.failure = "A change couldn't be shared, so it's been taken back: \(message.reason ?? "")"
        case "joined", "presence":
            if let peer = message.peer, peer.id != you { peers[peer.id] = peer }
        case "left":
            if let id = message.peer?.id { peers[id] = nil }
        default:
            break
        }
    }

    /// The host's copy with the changes made here and not yet confirmed on top: what's shown.
    private func relayPending() {
        guard let model else { return }
        var shown = confirmed
        for change in pending { _ = shown.apply(change.ops) }
        if shown != model.replica { model.adopt(shown) }
    }

    private func end(_ reason: String) {
        guard you != nil || status == "Connecting…" else { return }
        you = nil
        peers = [:]
        status = reason
        onWelcome = nil
        model?.onChange = nil
        if model?.session === self { model?.session = nil }
    }
}
