import CryptoKit
import Foundation

/// The host's side of a relayed session, without the network or the app, as `HostCore` is for a local one. See
/// `docs/relay.md`.
///
/// It's the authority, as before: it keeps the document, takes each guest's changes exactly once and in order, and
/// numbers every decision, made or turned down, `seq` 1, 2, 3…, publishing each to the relay with the document's digest
/// after it. A guest's change is taken only when its `cseq` is one past the last taken from that guest; anything else is
/// ignored, as the guest sends it again (on joining, and whenever the host comes back) until it's taken.
///
/// Every connection starts with a snapshot of the document as it is. So after a dropped connection, nothing needs
/// working out about which changes reached the relay: the snapshot covers them, and the relay catches guests up from it.
final class RelayHostCore {
    enum Effect {
        case send([UInt8])
        /// A guest's change, taken, and the tidying after it: to make to the open model.
        case apply([Replica.Op])
        /// Let in for the first time: the room, with the secrets its links carry.
        case shared(Relay.Welcome)
        case reconnect(after: TimeInterval)
        case ended(String)
    }

    enum State: Equatable { case connecting, connected, reconnecting, ended }

    let name: String
    let title: String
    /// The room key, which seals every body and goes only into the links the host hands out.
    let key = SymmetricKey(size: .bits256)
    private(set) var state = State.connecting
    /// The document, with its digest, as of decision `seq`.
    private(set) var document: CheckedReplica
    private(set) var seq: UInt64 = 0
    /// The last change taken from each guest, made or turned down.
    private(set) var taken: [UInt32: UInt64] = [:]
    /// The room, once the relay's made it.
    private(set) var room: Relay.Welcome?
    private(set) var peers: [UInt32: [UInt8]] = [:]
    /// Told of every decision as it's numbered: its ops (none for one turned down), author and cseq. For tests.
    var onPublish: ((_ seq: UInt64, _ ops: [Replica.Op], _ author: UInt32, _ cseq: UInt64) -> Void)?

    private var attempts = 0
    /// Whether there's a connection to send on: from its hello, which the relay reads before anything after it.
    private var isOpen = false
    private var heard = Date.distantPast
    private var pinged = Date.distantPast
    static let pingInterval: TimeInterval = 10
    static let silence: TimeInterval = 25

    init(_ replica: Replica, title: String, name: String) {
        document = CheckedReplica(replica)
        self.title = title
        self.name = name
    }

    // MARK: Events

    /// Connected to the relay: asks for a room, or for its room back, and sends the document as it is.
    func connected(at now: Date) -> [Effect] {
        guard state != .ended else { return [] }
        heard = now
        pinged = now
        isOpen = true
        let hello = room.map { Relay.Hello(role: .resume, room: $0.room, secret: $0.hostSecret, name: Array(name.utf8)) }
            ?? Relay.Hello(role: .host, name: Array(name.utf8), title: Array(title.utf8))
        return [.send(hello.frame.bytes), .send(snapshot)]
    }

    func disconnected() -> [Effect] {
        guard state != .ended else { return [] }
        isOpen = false
        if state == .connected { attempts = 0 }
        attempts += 1
        if room == nil, attempts > 3 { return end("Couldn't reach the relay.") }
        state = room == nil ? .connecting : .reconnecting
        return [.reconnect(after: min(10, 0.25 * pow(2, Double(attempts - 1))))]
    }

    func received(_ bytes: [UInt8], at now: Date) -> [Effect] {
        guard state != .ended else { return [] }
        heard = now
        guard let frame = try? Wire.Frame(bytes) else { return resync() }
        switch frame.header.kind {
        case .hello:
            guard let welcome = try? Relay.Welcome(frame.body) else { return resync() }
            let isNew = room == nil
            room = welcome
            peers = welcome.peers
            state = .connected
            attempts = 0
            return isNew ? [.shared(welcome)] : []
        case .bye:
            return end(String(decoding: frame.body, as: UTF8.self))
        default:
            break
        }
        guard state == .connected else { return [] }
        switch frame.header.kind {
        case .change:
            return change(frame)
        case .snapshotRequest:
            return [.send(snapshot)]
        case .joined:
            peers[frame.header.peer] = frame.body
            return []
        case .left:
            peers[frame.header.peer] = nil
            return []
        default:
            return []
        }
    }

    /// The document changed here, by `ops`, as they were made to the open model.
    func changedHere(_ ops: [Replica.Op]) -> [Effect] {
        guard state != .ended else { return [] }
        document.apply(ops)
        return publish(ops, author: Relay.hostPeer, cseq: 0)
    }

    func tick(at now: Date) -> [Effect] {
        guard state == .connected else { return [] }
        if now.timeIntervalSince(heard) > Self.silence { return resync() }
        guard now.timeIntervalSince(pinged) >= Self.pingInterval else { return [] }
        pinged = now
        return [.send(Wire.Frame(.ping, seq: seq).bytes)]
    }

    /// Ends the session for everyone.
    func stop(_ reason: String) -> [Effect] {
        guard state != .ended else { return [] }
        let bye = isOpen ? [Effect.send(Relay.bye(reason).bytes)] : []
        state = .ended
        return bye + [.ended(reason)]
    }

    // MARK: Changes

    private func change(_ frame: Wire.Frame) -> [Effect] {
        let guest = frame.header.peer, cseq = frame.header.seq
        // Taken already, or one before it missing: it'll come again, in order.
        guard guest != Relay.hostPeer, cseq == (taken[guest] ?? 0) + 1 else { return [] }
        taken[guest] = cseq
        do {
            let ops = try Wire.decode(try frame.opened(with: key))
            var trial = document.replica
            let tidying = try trial.receive(ops)
            // Each published with the digest after it: the change, then the tidying the host does after it.
            document.apply(ops)
            let change = publish(ops, author: guest, cseq: cseq)
            document.apply(tidying)
            return [.apply(ops + tidying)] + change + publish(tidying, author: Relay.hostPeer, cseq: 0)
        } catch {
            seq += 1
            let reason = (error as? Wire.Malformed).map { "The change couldn't be read: \($0.what)." } ?? error.localizedDescription
            onPublish?(seq, [], guest, cseq)
            let decision = Relay.Decision(author: guest, cseq: cseq, digest: document.digest.bytes, content: Array(reason.utf8))
            return sendIfConnected(Wire.Frame(.reject, seq: seq, sealing: decision.body, with: key))
        }
    }

    /// Numbers a change made to the document and publishes it. While away from the relay it's numbered all the same:
    /// the snapshot sent on coming back covers it.
    private func publish(_ ops: [Replica.Op], author: UInt32, cseq: UInt64) -> [Effect] {
        guard !ops.isEmpty else { return [] }
        seq += 1
        onPublish?(seq, ops, author, cseq)
        let decision = Relay.Decision(author: author, cseq: cseq, digest: document.digest.bytes, content: Wire.encode(ops))
        return sendIfConnected(Wire.Frame(.ops, seq: seq, sealing: decision.body, with: key))
    }

    private func sendIfConnected(_ frame: Wire.Frame) -> [Effect] {
        isOpen ? [.send(frame.bytes)] : []
    }

    private var snapshot: [UInt8] {
        let entities = document.replica.entities.keys.sorted().map { document.replica.entities[$0]! }
        let body = Relay.Snapshot(digest: document.digest.bytes, taken: taken, entities: entities).body
        return Wire.Frame(.snapshot, seq: seq, sealing: body, with: key).bytes
    }

    private func resync() -> [Effect] {
        guard state != .ended else { return [] }
        isOpen = false
        state = .reconnecting
        attempts = 0
        return [.reconnect(after: 0)]
    }

    private func end(_ reason: String) -> [Effect] {
        guard state != .ended else { return [] }
        state = .ended
        return [.ended(reason)]
    }
}
