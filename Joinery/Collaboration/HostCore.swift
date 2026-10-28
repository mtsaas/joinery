import Foundation

/// The host's side of the protocol, without the network or the app: what's heard on each connection in, what to send,
/// close and apply out, so it can be tested by simulation, on any thread. `SessionHost` connects it to sockets and the
/// open model. See docs/collaboration.md.
///
/// It keeps the document itself: the open model is changed by applying, in order, the ops it's told of (`changedHere`)
/// and the ops it hands out (`Effect.apply`), so the two are always the same.
///
/// It numbers every change to the document, `seq` 1, 2, 3…, and sends each to every client in that order, with the
/// document's digest after it. It takes each client's changes exactly once and in the client's order: `cseq` must be one
/// past the last it took from that client, on any connection, or the connection's closed for the client to reconnect.
final class HostCore {
    typealias Connection = Int

    enum Effect {
        /// Another's change, taken, and the tidying after it: to make to the open model.
        case apply([Replica.Op])
        case send(Connection, Message)
        case close(Connection)
    }

    let token: String
    let me: Peer
    private(set) var seq = 0
    /// Everyone joined, by peer ID.
    private(set) var peers: [String: Peer] = [:]
    /// Clients are let go if nothing's heard from them in this long, as they ping every ten seconds.
    static let timeout: TimeInterval = 30

    /// The document, with its digest, as of change `seq`.
    private(set) var document: CheckedReplica
    /// What it's called, for those joining.
    var title: String

    private struct Link {
        var heard: Date
        /// Once it's said hello: the client, and who it is to others.
        var client: String?
        var peer: String?
    }
    private var links: [Connection: Link] = [:]
    /// Each client's last change taken (made or turned down), by its client ID, kept through reconnecting.
    private var taken: [String: Int] = [:]
    /// Each client's peer ID, kept through reconnecting, so others see the same person.
    private var peerIDs: [String: String] = [:]
    private var colors = 0
    /// Told of every change as it's numbered, before it's sent: for tests to follow the document's history.
    var onPublish: ((Message) -> Void)?
    private static let palette = ["purple", "pink", "orange", "green", "teal", "indigo", "red", "mint", "cyan", "brown", "yellow"]

    init(_ replica: Replica, title: String, token: String, name: String) {
        document = CheckedReplica(replica)
        self.title = title
        self.token = token
        me = Peer(id: "host", name: name, color: "blue")
    }

    // MARK: Events

    func opened(_ connection: Connection, at now: Date) {
        links[connection] = Link(heard: now)
    }

    func closed(_ connection: Connection) -> [Effect] {
        guard let link = links.removeValue(forKey: connection), let peer = link.peer else { return [] }
        // Gone, unless it's reconnected already.
        guard !links.values.contains(where: { $0.peer == peer }) else { return [] }
        peers[peer] = nil
        var left = Message("left")
        left.peer = Peer(id: peer, name: "", color: "")
        return broadcast(left)
    }

    func received(_ text: String, on connection: Connection, at now: Date) -> [Effect] {
        guard var link = links[connection] else { return [] }
        link.heard = now
        links[connection] = link
        // Not a message, which no client sends: lost in transit, perhaps. Letting go of the connection costs a correct
        // client only a reconnection; turning it away would end its session.
        guard let message = Message(text: text) else { return [.close(connection)] }
        guard let client = link.client, let peer = link.peer else { return hello(message, on: connection) }
        switch message.type {
        case "ops":
            return change(message, from: client, as: peer, on: connection)
        case "presence":
            guard var person = peers[peer] else { return [] }
            person.cursor = message.cursor
            person.selection = message.selection
            peers[peer] = person
            var presence = Message("presence")
            presence.peer = person
            return broadcast(presence, except: peer)
        case "ping":
            var pong = Message("pong")
            pong.seq = seq
            pong.acked = taken[client] ?? 0
            pong.hash = document.digest.description
            return [.send(connection, pong)]
        default:
            // From a later version, perhaps: not this one's business.
            return []
        }
    }

    /// The document changed here, by `ops`, as they were made to the open model.
    func changedHere(_ ops: [Replica.Op]) -> [Effect] {
        document.apply(ops)
        return publish(ops, author: me.id)
    }

    func share(_ presence: Peer) -> [Effect] {
        var message = Message("presence")
        message.peer = presence
        return broadcast(message)
    }

    /// Lets go of connections nothing's been heard on for `timeout`.
    func tick(at now: Date) -> [Effect] {
        links.filter { now.timeIntervalSince($0.value.heard) > Self.timeout }.keys.sorted().map(Effect.close)
    }

    /// Ends the session for everyone.
    func stop(_ reason: String) -> [Effect] {
        var bye = Message("bye")
        bye.reason = reason
        return links.keys.sorted().flatMap { [Effect.send($0, bye), .close($0)] }
    }

    // MARK: Messages

    private func hello(_ message: Message, on connection: Connection) -> [Effect] {
        guard message.type == "hello" else { return [.close(connection)] }
        guard message.protocol == Message.version else { return refuse(connection, "This copy of Joinery speaks protocol \(Message.version).") }
        guard message.token == token else { return refuse(connection, "That link isn't valid, or the session has ended.") }
        guard let client = message.client, !client.isEmpty, client.count <= 100 else { return refuse(connection, "Say which client this is.") }
        var effects: [Effect] = []
        // The same client on another connection is a dead one it's left behind.
        for (other, link) in links where link.client == client && other != connection {
            links[other] = nil
            effects.append(.close(other))
        }
        let peer = peerIDs[client] ?? UUID().uuidString
        let isNew = peers[peer] == nil
        peerIDs[client] = peer
        links[connection]?.client = client
        links[connection]?.peer = peer
        if isNew {
            let name = message.name?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60) ?? ""
            peers[peer] = Peer(id: peer, name: name.isEmpty ? "Guest" : String(name), color: Self.palette[colors % Self.palette.count])
            colors += 1
        }
        var welcome = Message("welcome")
        welcome.protocol = Message.version
        welcome.you = peer
        welcome.seq = seq
        welcome.acked = taken[client] ?? 0
        welcome.hash = document.digest.description
        welcome.title = title
        welcome.entities = document.replica.entities.keys.sorted().compactMap { document.replica.entities[$0] }
        welcome.peers = [me] + peers.values.filter { $0.id != peer }.sorted { $0.id < $1.id }
        effects.append(.send(connection, welcome))
        if isNew, let person = peers[peer] {
            var joined = Message("joined")
            joined.peer = person
            effects += broadcast(joined, except: peer)
        }
        return effects
    }

    private func change(_ message: Message, from client: String, as peer: String, on connection: Connection) -> [Effect] {
        let last = taken[client] ?? 0
        guard let cseq = message.cseq else { return refuse(connection, "A change needs its number.") }
        // Sent again after reconnecting, though it was taken: already done.
        if cseq <= last { return [] }
        // A change missing before it: something's gone wrong, so the client starts afresh.
        guard cseq == last + 1 else { return [.close(connection)] }
        taken[client] = cseq
        let ops = message.ops ?? []
        do {
            let tidying = try document.receive(ops)
            return [.apply(ops + tidying)] + publish(ops, author: peer, cseq: cseq) + publish(tidying, author: me.id)
        } catch {
            var reject = Message("reject")
            reject.cseq = cseq
            reject.reason = error.localizedDescription
            return [.send(connection, reject)]
        }
    }

    /// Numbers a change made to the document and sends it to everyone, its author included, who learns from it that
    /// theirs was made.
    private func publish(_ ops: [Replica.Op], author: String, cseq: Int? = nil) -> [Effect] {
        guard !ops.isEmpty else { return [] }
        seq += 1
        var message = Message("ops")
        message.seq = seq
        message.author = author
        message.cseq = cseq
        message.ops = ops
        message.hash = document.digest.description
        onPublish?(message)
        return broadcast(message)
    }

    private func broadcast(_ message: Message, except excluded: String? = nil) -> [Effect] {
        links.filter { $0.value.peer != nil && $0.value.peer != excluded }.keys.sorted().map { .send($0, message) }
    }

    /// Turns a connection away: told why, then closed.
    private func refuse(_ connection: Connection, _ reason: String) -> [Effect] {
        var reject = Message("reject")
        reject.reason = reason
        return [.send(connection, reject), .close(connection)]
    }
}
