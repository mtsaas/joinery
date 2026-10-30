import CryptoKit
import Foundation

/// A guest's side of a relayed session, without the network or the app. See `docs/relay.md`.
///
/// It keeps `confirmed`, the host's document as of decision `seq`, and `pending`, the changes made here the host hasn't
/// decided on yet; what's shown is the one with the other on top. Every decision the host makes is in the relay's log in
/// order, so it learns what became of its own changes by reading that, connected or catching up. Anything that doesn't
/// fit (a decision out of order, a digest that doesn't match, a decision on a change it didn't send next) drops the
/// connection, and on reconnecting the relay catches it up from where it was, or from a snapshot.
final class RelayGuestCore {
    enum Effect {
        case send([UInt8])
        /// What's shown is now this.
        case show(Replica)
        /// Let in for the first time: the session's title.
        case welcomed(String)
        case reconnect(after: TimeInterval)
        /// The host turned down a change made here, which is no longer shown.
        case refused(String)
        case ended(String)
    }

    enum State: Equatable { case connecting, connected, reconnecting, ended }

    let room: String
    let secret: String
    /// The room key, from the link: it opens every body, and seals this guest's changes.
    let key: SymmetricKey
    let name: String
    let canEdit: Bool
    /// Who this guest is to the relay, through every reconnection.
    let client = UUID().uuidString
    private(set) var state = State.connecting
    private(set) var you: UInt32?
    /// Everyone else here.
    private(set) var peers: [UInt32: Peer] = [:]
    /// What the relay holds the room to, once it's said.
    private(set) var limits = Relay.Limits()
    /// The host's document, as of `seq`, once there's a copy.
    private(set) var confirmed = CheckedReplica()
    private(set) var seq: UInt64 = 0
    private(set) var hasCopy = false
    private(set) var pending: [(cseq: UInt64, ops: [Replica.Op])] = []
    private var nextCseq: UInt64 = 1
    /// Whether digests are checked: they are, unless a snapshot's own digest didn't match it, which would mean the host
    /// hashes differently, not that anything's wrong.
    private(set) var checksDigests = true
    private var attempts = 0
    private var heard = Date.distantPast
    private var pinged = Date.distantPast
    private var wasWelcomed = false

    static let pingInterval: TimeInterval = 10
    static let silence: TimeInterval = 25

    init(room: String, secret: String, key: SymmetricKey, name: String, canEdit: Bool = true) {
        self.room = room
        self.secret = secret
        self.key = key
        self.name = name
        self.canEdit = canEdit
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
        let hello = Relay.Hello(role: canEdit ? .guest : .view, room: room, secret: secret, client: client,
                                applied: hasCopy ? seq : nil, name: Array(name.utf8))
        return [.send(hello.frame.bytes)]
    }

    func disconnected() -> [Effect] {
        guard state != .ended else { return [] }
        if state == .connected { attempts = 0 }
        attempts += 1
        if !wasWelcomed, attempts > 3 { return end("Couldn't join: check the link, and that its host is still sharing.") }
        state = wasWelcomed ? .reconnecting : .connecting
        return [.reconnect(after: min(10, 0.25 * pow(2, Double(attempts - 1))))]
    }

    /// A change made here: shown at once, and sent when it can be.
    func changedHere(_ ops: [Replica.Op]) -> [Effect] {
        guard !ops.isEmpty, state != .ended else { return [] }
        // A view link: taken back at once.
        guard canEdit else { return [.refused("You joined with a view link, so you can watch but not edit."), .show(shown)] }
        // The relay would let go of it, and of every try after.
        let size = Wire.Header.size + Wire.Frame.sealing + Wire.encode(ops).count
        guard size <= limits.maxFrame else {
            return [.refused("It's \(size / 1024) KB, and the relay takes changes up to \(limits.maxFrame / 1024) KB."), .show(shown)]
        }
        pending.append((nextCseq, ops))
        nextCseq += 1
        guard state == .connected else { return [] }
        return [.send(changeFrame(pending.last!))]
    }

    /// Where this guest's pointer is and what it has selected, for everyone else.
    func share(_ presence: Relay.Presence) -> [Effect] {
        guard state == .connected else { return [] }
        return [.send(Wire.Frame(.presence, sealing: presence.body, with: key).bytes)]
    }

    func tick(at now: Date) -> [Effect] {
        guard state == .connected else { return [] }
        if now.timeIntervalSince(heard) > Self.silence { return resync() }
        guard now.timeIntervalSince(pinged) >= Self.pingInterval else { return [] }
        pinged = now
        return [.send(Wire.Frame(.ping, seq: seq).bytes)]
    }

    static let leftReason = "Left the session."

    func leave() -> [Effect] { end(Self.leftReason) }

    func received(_ bytes: [UInt8], at now: Date) -> [Effect] {
        guard state != .ended else { return [] }
        heard = now
        guard let frame = try? Wire.Frame(bytes) else { return resync() }
        switch frame.header.kind {
        case .hello: return welcome(frame)
        case .bye: return end(String(decoding: frame.body, as: UTF8.self))
        default: break
        }
        // Anything else only once welcomed on this connection.
        guard state == .connected else { return resync() }
        switch frame.header.kind {
        case .snapshot:
            return snapshot(frame)
        case .ops, .reject:
            return decision(frame)
        case .pong:
            // Everything the relay sent before it has come.
            guard !hasCopy || frame.header.seq == seq else { return resync() }
            return []
        case .joined:
            peers[frame.header.peer] = Relay.peer(frame.header.peer, name: frame.body)
            // The host's back: what it may have missed while away, sent again.
            return frame.header.peer == Relay.hostPeer ? pending.map { .send(changeFrame($0)) } : []
        case .left:
            peers[frame.header.peer] = nil
            return []
        case .presence:
            guard let plain = try? frame.opened(with: key), let presence = try? Relay.Presence(plain) else { return [] }
            peers[frame.header.peer, default: Relay.peer(frame.header.peer, name: [])].show(presence)
            return []
        default:
            return []
        }
    }

    // MARK: Frames

    private func welcome(_ frame: Wire.Frame) -> [Effect] {
        guard let welcome = try? Relay.Welcome(frame.body) else { return resync() }
        guard welcome.version == Relay.roomVersion else {
            return end(welcome.version > Relay.roomVersion ? "This session needs a newer Joinery." : "The host needs a newer Joinery.")
        }
        you = welcome.peer
        limits = welcome.limits
        peers = welcome.peers.reduce(into: [:]) { $0[$1.key] = Relay.peer($1.key, name: $1.value) }
        state = .connected
        attempts = 0
        var effects: [Effect] = []
        if !wasWelcomed {
            wasWelcomed = true
            effects.append(.welcomed(String(decoding: welcome.title, as: UTF8.self)))
        }
        // Sent again: those the host has taken already, it ignores; the rest it takes, in order.
        return effects + pending.map { .send(changeFrame($0)) }
    }

    private func snapshot(_ frame: Wire.Frame) -> [Effect] {
        // Not opening is a wrong key, not a bad connection: trying again won't help.
        guard let plain = try? frame.opened(with: key) else { return end("Couldn't read this session: check the link.") }
        guard let snapshot = try? Relay.Snapshot(plain) else { return resync() }
        var copy = Replica()
        for entity in snapshot.entities { _ = copy.apply(.put(entity)) }
        confirmed = CheckedReplica(copy)
        seq = frame.header.seq
        hasCopy = true
        if snapshot.digest != confirmed.digest.bytes { checksDigests = false }
        // What the host had taken of the changes made here is in its copy, made or turned down.
        let taken = you.flatMap { snapshot.taken[$0] } ?? 0
        pending.removeAll { $0.cseq <= taken }
        return [.show(shown)]
    }

    private func decision(_ frame: Wire.Frame) -> [Effect] {
        guard hasCopy, frame.header.seq == seq + 1, let plain = try? frame.opened(with: key),
              let decision = try? Relay.Decision(plain) else { return resync() }
        var effects: [Effect] = []
        if frame.header.kind == .ops {
            guard let ops = try? Wire.decode(decision.content) else { return resync(discardingCopy: true) }
            confirmed.apply(ops)
        }
        seq = frame.header.seq
        if decision.author == you {
            guard pending.first?.cseq == decision.cseq else { return resync() }
            pending.removeFirst()
            if frame.header.kind == .reject { effects.append(.refused(String(decoding: decision.content, as: UTF8.self))) }
        }
        guard !checksDigests || decision.digest == confirmed.digest.bytes else { return resync(discardingCopy: true) }
        return [.show(shown)] + effects
    }

    private func changeFrame(_ change: (cseq: UInt64, ops: [Replica.Op])) -> [UInt8] {
        Wire.Frame(.change, seq: change.cseq, sealing: Wire.encode(change.ops), with: key).bytes
    }

    /// Starts afresh: drops the connection to reconnect at once, and catch up from where it is, or, if its copy can't be
    /// trusted, from a snapshot.
    private func resync(discardingCopy: Bool = false) -> [Effect] {
        guard state != .ended else { return [] }
        if discardingCopy { hasCopy = false }
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
}
