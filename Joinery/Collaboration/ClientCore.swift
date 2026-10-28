import Foundation

/// A client's side of the protocol, without the network or the app: what's heard in, what to send, show and do out, so
/// it can be tested by simulation, on any thread. `SessionClient` connects it to a WebSocket. See docs/collaboration.md for why it's correct.
///
/// It keeps `confirmed`, the host's document as of change `seq`, and `pending`, the changes made here the host hasn't
/// yet taken; what's shown is the one with the other on top. Whenever anything heard doesn't fit (a change out of
/// order, a digest that doesn't match, a reply to a change it didn't send next) the connection is dropped, and on
/// reconnecting the host sends its copy afresh, says which of the pending changes it's taken, and the rest are sent
/// again. So however connections fail, every change made here is taken once, and the copy here comes back to the host's.
final class ClientCore {
    enum Effect {
        case send(Message)
        /// What's shown is now this.
        case show(Replica)
        /// Let in for the first time: the session's title.
        case welcomed(String)
        /// Drop the connection, if there is one, and connect again after this long.
        case reconnect(after: TimeInterval)
        /// The host turned down a change made here, which is no longer shown.
        case refused(String)
        /// It's over: the host ended it, or turned this client away.
        case ended(String)
    }

    enum State: Equatable { case connecting, connected, reconnecting, ended }

    let token: String
    let name: String
    /// Who this client is to the host, for the life of the session here, through every reconnection.
    let client = UUID().uuidString
    private(set) var state = State.connecting
    private(set) var you: String?
    private(set) var peers: [String: Peer] = [:]
    /// The host's document, as of `seq`.
    private(set) var confirmed = CheckedReplica()
    private(set) var seq = 0
    /// Changes made here and sent, or to send, that the host hasn't taken yet, in order.
    private(set) var pending: [(cseq: Int, ops: [Replica.Op])] = []
    private var nextCseq = 1
    /// Whether digests are checked: they are, unless the host's first one didn't match a copy just sent whole, which
    /// means it writes JSON differently, not that anything's wrong.
    private(set) var checksDigests = true
    private var attempts = 0
    private var heard = Date.distantPast
    private var pinged = Date.distantPast
    /// The last change sent on this connection, and the last sent before the latest ping: the host's answer to that
    /// ping, having read everything before it, must have taken it.
    private var sentThrough = 0
    private var pingCovers = 0
    private var title: String?

    /// Pings this often, and reconnects if nothing's heard for `silence`.
    static let pingInterval: TimeInterval = 10
    static let silence: TimeInterval = 25

    init(token: String, name: String) {
        self.token = token
        self.name = name
    }

    /// What's shown: the host's document with the changes made here on top.
    var shown: Replica {
        var replica = confirmed.replica
        for change in pending { _ = replica.apply(change.ops) }
        return replica
    }

    // MARK: Events

    func connected(at now: Date) -> [Effect] {
        guard state != .ended else { return [] }
        heard = now
        pinged = now
        sentThrough = 0
        pingCovers = 0
        var hello = Message("hello")
        hello.protocol = Message.version
        hello.token = token
        hello.name = name
        hello.client = client
        return [.send(hello)]
    }

    /// The connection's gone, or couldn't be made: try again, sooner at first.
    func disconnected() -> [Effect] {
        guard state != .ended else { return [] }
        if state == .connected { attempts = 0 }
        attempts += 1
        // Never let in: the link's wrong, or its host has gone.
        if title == nil, attempts > 3 { return end("Couldn't join: check the link, and that its host is still sharing.") }
        state = title == nil ? .connecting : .reconnecting
        return [.reconnect(after: min(10, 0.25 * pow(2, Double(attempts - 1))))]
    }

    /// A change made here: shown at once, and sent when it can be.
    func changedHere(_ ops: [Replica.Op]) -> [Effect] {
        guard !ops.isEmpty, state != .ended else { return [] }
        pending.append((nextCseq, ops))
        nextCseq += 1
        guard state == .connected else { return [] }
        sentThrough = pending.last!.cseq
        return [.send(changeMessage(pending.last!))]
    }

    func share(cursor: CGPoint?, selection: [UUID]) -> [Effect] {
        guard state == .connected else { return [] }
        var message = Message("presence")
        message.cursor = cursor.map { [$0.x, $0.y] }
        message.selection = selection.map(\.uuidString)
        return [.send(message)]
    }

    func tick(at now: Date) -> [Effect] {
        guard state == .connected else { return [] }
        if now.timeIntervalSince(heard) > Self.silence { return resync() }
        guard now.timeIntervalSince(pinged) >= Self.pingInterval else { return [] }
        pinged = now
        pingCovers = sentThrough
        return [.send(Message("ping"))]
    }

    func leave() -> [Effect] {
        end("Left the session. This copy is yours to keep.")
    }

    func received(_ text: String, at now: Date) -> [Effect] {
        guard state != .ended else { return [] }
        heard = now
        guard let message = Message(text: text) else { return resync() }
        switch message.type {
        case "welcome": return welcome(message)
        case "reject" where message.cseq == nil: return end(message.reason ?? "The host turned this copy away.")
        case "bye": return end(message.reason ?? "The session has ended.")
        default: break
        }
        // Anything else only once welcomed on this connection.
        guard state == .connected else { return resync() }
        switch message.type {
        case "ops":
            guard let seq = message.seq, seq == self.seq + 1, let ops = message.ops else { return resync() }
            confirmed.apply(ops)
            self.seq = seq
            if message.author == you {
                guard let cseq = message.cseq, pending.first?.cseq == cseq else { return resync() }
                pending.removeFirst()
            }
            guard digestMatches(message.hash) else { return resync() }
            return [.show(shown)]
        case "reject":
            guard pending.first?.cseq == message.cseq else { return resync() }
            pending.removeFirst()
            return [.show(shown), .refused(message.reason ?? "")]
        case "pong":
            // Everything the host sent before it has come; it had read every change sent before the ping; and no change
            // still waiting here has been taken, as its answer would have come first, unless it went to a connection
            // since let go of (turned down after being sent again on this one).
            let taken = message.acked ?? 0
            guard message.seq == seq, taken >= pingCovers, pending.first.map({ $0.cseq > taken }) ?? true,
                  digestMatches(message.hash) else { return resync() }
            return []
        case "joined", "presence":
            if let peer = message.peer, peer.id != you { peers[peer.id] = peer }
            return []
        case "left":
            if let id = message.peer?.id { peers[id] = nil }
            return []
        default:
            return []
        }
    }

    // MARK: Messages

    private func welcome(_ message: Message) -> [Effect] {
        guard let you = message.you, let seq = message.seq, let entities = message.entities else { return resync() }
        var copy = Replica()
        for entity in entities { _ = copy.apply(.put(entity)) }
        confirmed = CheckedReplica(copy)
        self.seq = seq
        self.you = you
        peers = Dictionary((message.peers ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Its copy, whole, is the truth: a digest that doesn't match it means the host writes JSON differently.
        if message.hash != confirmed.digest.description { checksDigests = false }
        // What the host took of the changes made here, made or turned down, is in its copy or never will be.
        let taken = message.acked ?? 0
        pending.removeAll { $0.cseq <= taken }
        state = .connected
        attempts = 0
        var effects: [Effect] = []
        if title == nil {
            title = message.title ?? "Shared Data Model"
            effects.append(.welcomed(title!))
        }
        effects.append(.show(shown))
        sentThrough = pending.last?.cseq ?? 0
        return effects + pending.map { .send(changeMessage($0)) }
    }

    private func digestMatches(_ hash: String?) -> Bool {
        !checksDigests || hash == confirmed.digest.description
    }

    /// Starts afresh from the host's copy: drops the connection to reconnect at once.
    private func resync() -> [Effect] {
        guard state != .ended else { return [] }
        state = .reconnecting
        attempts = 0
        return [.reconnect(after: 0)]
    }

    private func end(_ reason: String) -> [Effect] {
        guard state != .ended else { return [] }
        state = .ended
        peers = [:]
        return [.ended(reason)]
    }

    private func changeMessage(_ change: (cseq: Int, ops: [Replica.Op])) -> Message {
        var message = Message("ops")
        message.cseq = change.cseq
        message.ops = change.ops
        return message
    }
}
