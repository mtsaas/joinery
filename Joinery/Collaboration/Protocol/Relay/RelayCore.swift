import Foundation

/// A relay, without the network: what's heard on each connection in, what to send and close out. It's the reference the
/// Zig relay is checked against, and what the simulation runs; it doesn't ship. See `docs/relay.md`.
///
/// It never reads a change. It reads headers, `hello`s, and from the host the order of what it publishes: every `ops`
/// and `reject` frame must be the next `seq`. It keeps each room's published frames in a log, bounded in bytes, behind a
/// snapshot the host sends when asked, and catches guests up from the log, or from the snapshot when the log no longer
/// reaches back far enough.
final class RelayCore {
    typealias Connection = Int

    enum Effect: Equatable {
        case send(Connection, [UInt8])
        case close(Connection)
    }

    let limits: Relay.Limits
    /// Connections are let go if nothing's heard on them in this long, as everyone pings every ten seconds.
    static let timeout: TimeInterval = 30
    /// How many clients a room remembers, each keeping its peer for the room's life.
    static let maxClients = 1024
    /// A room whose host has been gone this long ends.
    let hostGrace: TimeInterval
    /// Makes room IDs and secrets; random, unless a test wants them predictable.
    private let makeSecret: () -> String

    private struct Link {
        var heard: Date
        /// Once it's said hello: its room, and whether it's the host there.
        var room: String?
    }

    private struct Guest {
        var peer: UInt32
        var client: String
        var name: [UInt8]
        var canEdit: Bool
        /// The last change it's said it has, from its pings, which the log keeps until it's past.
        var applied: UInt64?
        /// The last change sent to it.
        var sent: UInt64
    }

    private final class Room {
        let id: String, hostSecret: String, guestSecret: String, viewSecret: String
        let version: UInt64, title: [UInt8], hostName: [UInt8]
        var host: Connection?
        var hostGone: Date?
        /// Between the host's hello and its snapshot, which always follows it.
        var awaitingSnapshot = true
        var snapshotRequested = false
        var log: [(seq: UInt64, frame: [UInt8])] = []
        var logBytes = 0
        var latest: UInt64 = 0
        var snapshot: (seq: UInt64, frame: [UInt8])?
        var guests: [Connection: Guest] = [:]
        /// Each client's peer, for the room's life, so it's the same person through reconnecting.
        var peers: [String: UInt32] = [:]
        var nextPeer: UInt32 = Relay.hostPeer + 1

        init(id: String, hostSecret: String, guestSecret: String, viewSecret: String, version: UInt64, title: [UInt8], hostName: [UInt8]) {
            self.id = id
            self.hostSecret = hostSecret
            self.guestSecret = guestSecret
            self.viewSecret = viewSecret
            self.version = version
            self.title = title
            self.hostName = hostName
        }

        /// The log keeps everything back to the older of the snapshot and the oldest guest's last change: frames no one
        /// needs to catch up from go.
        func trim() {
            guard let snapshot else { return }
            let needed = guests.values.map { $0.applied ?? 0 }.min().map { min($0, snapshot.seq) } ?? snapshot.seq
            while let first = log.first, first.seq <= needed {
                logBytes -= first.frame.count
                log.removeFirst()
            }
        }
    }

    private var links: [Connection: Link] = [:]
    private var rooms: [String: Room] = [:]
    private var now = Date.distantPast

    init(limits: Relay.Limits = Relay.Limits(), hostGrace: TimeInterval = 30,
         makeSecret: @escaping () -> String = { (0..<4).map { _ in String(UInt32.random(in: .min ... .max), radix: 36) }.joined() }) {
        self.limits = limits
        self.hostGrace = hostGrace
        self.makeSecret = makeSecret
    }

    /// For tests: how many rooms there are, and a room's log.
    var roomCount: Int { rooms.count }
    func logSeqs(of room: String) -> [UInt64] { rooms[room]?.log.map(\.seq) ?? [] }

    // MARK: Events

    func opened(_ connection: Connection, at now: Date) {
        self.now = now
        links[connection] = Link(heard: now)
    }

    func closed(_ connection: Connection, at now: Date) -> [Effect] {
        self.now = now
        return forget(connection)
    }

    func received(_ bytes: [UInt8], on connection: Connection, at now: Date) -> [Effect] {
        self.now = now
        guard links[connection] != nil else { return [] }
        links[connection]!.heard = now
        let isSnapshot = bytes.count > 1 && bytes[1] == Wire.Kind.snapshot.rawValue
        guard bytes.count <= (isSnapshot ? limits.maxSnapshot : limits.maxFrame), let frame = try? Wire.Frame(bytes) else {
            return drop(connection)
        }
        guard let id = links[connection]!.room else { return hello(frame, on: connection) }
        guard let room = rooms[id] else { return drop(connection) }
        if room.host == connection { return fromHost(frame, bytes, in: room) }
        guard let guest = room.guests[connection] else { return drop(connection) }
        return from(guest, on: connection, frame, bytes, in: room)
    }

    /// Lets go of silent connections, and ends rooms whose host hasn't come back.
    func tick(at now: Date) -> [Effect] {
        self.now = now
        var effects: [Effect] = []
        for connection in links.filter({ now.timeIntervalSince($0.value.heard) > Self.timeout }).keys.sorted() {
            effects += drop(connection)
        }
        for room in rooms.values.sorted(by: { $0.id < $1.id }) {
            if let gone = room.hostGone, now.timeIntervalSince(gone) > hostGrace {
                effects += end(room, Relay.bye("The host stopped sharing.").bytes)
            }
        }
        return effects
    }

    // MARK: Joining

    private func hello(_ frame: Wire.Frame, on connection: Connection) -> [Effect] {
        guard frame.header.kind == .hello, let hello = try? Relay.Hello(frame.body) else { return drop(connection) }
        switch hello.role {
        case .host:
            guard hello.name.count <= Relay.maxName, hello.title.count <= Relay.maxTitle else {
                return refuse(connection, "That name or title is too long.")
            }
            let room = Room(id: makeSecret(), hostSecret: makeSecret(), guestSecret: makeSecret(), viewSecret: makeSecret(),
                            version: hello.version, title: hello.title, hostName: hello.name)
            rooms[room.id] = room
            return attachHost(connection, to: room)
        case .resume:
            guard let room = rooms[hello.room], hello.secret == room.hostSecret else {
                return refuse(connection, "That session has ended.")
            }
            var effects: [Effect] = []
            if let old = room.host { effects += drop(old) }
            return effects + attachHost(connection, to: room)
        case .guest, .view:
            guard let room = rooms[hello.room], !hello.secret.isEmpty,
                  hello.secret == (hello.role == .guest ? room.guestSecret : room.viewSecret) else {
                return refuse(connection, "That link isn't valid, or the session has ended.")
            }
            guard !hello.client.isEmpty, hello.client.utf8.count <= Relay.maxClient else { return refuse(connection, "Say which client this is.") }
            guard hello.name.count <= Relay.maxName else { return refuse(connection, "That name is too long.") }
            return join(connection, hello, to: room)
        }
    }

    private func attachHost(_ connection: Connection, to room: Room) -> [Effect] {
        links[connection]?.room = room.id
        room.host = connection
        room.hostGone = nil
        room.awaitingSnapshot = true
        room.snapshotRequested = false
        let welcome = Relay.Welcome(peer: Relay.hostPeer, room: room.id, hostSecret: room.hostSecret,
                                    guestSecret: room.guestSecret, viewSecret: room.viewSecret, limits: limits,
                                    latest: room.latest, version: room.version, title: room.title,
                                    peers: Dictionary(room.guests.values.map { ($0.peer, $0.name) }, uniquingKeysWith: { a, _ in a }))
        return [.send(connection, welcome.frame.bytes)]
    }

    private func join(_ connection: Connection, _ hello: Relay.Hello, to room: Room) -> [Effect] {
        var effects: [Effect] = []
        let known = room.peers[hello.client]
        // The same client on another connection is a dead one it's left behind.
        for (other, guest) in room.guests where guest.client == hello.client && other != connection {
            room.guests[other] = nil
            links[other] = nil
            effects.append(.close(other))
        }
        if room.guests.count >= limits.maxPeers - 1 || (known == nil && room.peers.count >= Self.maxClients) {
            return effects + refuse(connection, "This session is full.")
        }
        let peer = known ?? room.nextPeer
        if known == nil {
            room.peers[hello.client] = peer
            room.nextPeer += 1
        }
        links[connection]?.room = room.id
        var others = Dictionary(room.guests.values.map { ($0.peer, $0.name) }, uniquingKeysWith: { a, _ in a })
        if room.host != nil { others[Relay.hostPeer] = room.hostName }
        let welcome = Relay.Welcome(peer: peer, room: room.id, limits: limits, latest: room.latest, version: room.version,
                                    title: room.title, peers: others)
        effects.append(.send(connection, welcome.frame.bytes))
        var guest = Guest(peer: peer, client: hello.client, name: hello.name, canEdit: hello.role == .guest,
                          applied: hello.applied, sent: hello.applied ?? 0)
        // Caught up from the log if it reaches back to what the guest has, from the snapshot if not.
        let logStart = room.log.first?.seq ?? room.latest + 1
        if let applied = hello.applied, applied + 1 >= logStart, applied <= room.latest {
            for entry in room.log where entry.seq > applied { effects.append(.send(connection, entry.frame)) }
        } else if let snapshot = room.snapshot {
            effects.append(.send(connection, snapshot.frame))
            for entry in room.log where entry.seq > snapshot.seq { effects.append(.send(connection, entry.frame)) }
            guest.applied = snapshot.seq
        }
        guest.sent = room.latest
        room.guests[connection] = guest
        let joined = Wire.Frame(.joined, peer: peer, body: hello.name).bytes
        return effects + everyone(in: room, except: connection).map { .send($0, joined) }
    }

    // MARK: Frames

    private func fromHost(_ frame: Wire.Frame, _ bytes: [UInt8], in room: Room) -> [Effect] {
        let host = room.host!
        switch frame.header.kind {
        case .snapshot:
            let seq = frame.header.seq
            // After hello, its copy as it is, which may be past what reached here before it left. Asked for, the copy
            // as of its latest change, all of which has come first.
            guard room.awaitingSnapshot ? seq >= room.latest : seq == room.latest else { return drop(host) }
            var effects: [Effect] = []
            room.snapshot = (seq, bytes)
            room.snapshotRequested = false
            if seq > room.latest {
                // Changes that never reached here: the log can't catch anyone up past them, so it starts again.
                room.log = []
                room.logBytes = 0
                room.latest = seq
                for (connection, guest) in room.guests.sorted(by: { $0.key < $1.key }) where guest.sent < seq {
                    effects.append(.send(connection, bytes))
                    room.guests[connection]!.sent = seq
                }
            }
            if room.awaitingSnapshot {
                room.awaitingSnapshot = false
                // Back: guests send again whatever it may have missed.
                let back = Wire.Frame(.joined, peer: Relay.hostPeer, body: room.hostName).bytes
                effects += room.guests.keys.sorted().map { .send($0, back) }
            }
            room.trim()
            return effects
        case .ops, .reject:
            guard !room.awaitingSnapshot, frame.header.seq == room.latest + 1 else { return drop(host) }
            var effects: [Effect] = []
            // Room for it: frames the snapshot covers go, and with them any guest still behind them, which comes back
            // and catches up from the snapshot. Frames past the snapshot can't go, so the host comes back with a new one.
            while room.logBytes + bytes.count > limits.logBytes {
                guard let first = room.log.first, let snapshot = room.snapshot, first.seq <= snapshot.seq else {
                    return effects + drop(host)
                }
                for (connection, guest) in room.guests.sorted(by: { $0.key < $1.key }) where (guest.applied ?? 0) < first.seq {
                    effects += drop(connection)
                }
                // With no one behind it, the snapshot covers it, so trimming takes it.
                room.trim()
                if room.log.first?.seq == first.seq {
                    room.log.removeFirst()
                    room.logBytes -= first.frame.count
                }
            }
            room.log.append((frame.header.seq, bytes))
            room.logBytes += bytes.count
            room.latest = frame.header.seq
            for connection in room.guests.keys.sorted() {
                effects.append(.send(connection, bytes))
                room.guests[connection]!.sent = room.latest
            }
            if !room.snapshotRequested && room.logBytes * 2 > limits.logBytes {
                room.snapshotRequested = true
                effects.append(.send(host, Wire.Frame(.snapshotRequest).bytes))
            }
            return effects
        case .presence:
            let stamped = Wire.stamp(bytes, peer: Relay.hostPeer)
            return room.guests.keys.sorted().map { .send($0, stamped) }
        case .ping:
            return [.send(host, Wire.Frame(.pong, seq: room.latest).bytes)]
        case .bye:
            // Passed on as is, the relay's own.
            return end(room, Relay.bye(frame.body).bytes)
        default:
            return []
        }
    }

    private func from(_ guest: Guest, on connection: Connection, _ frame: Wire.Frame, _ bytes: [UInt8], in room: Room) -> [Effect] {
        switch frame.header.kind {
        case .change:
            guard guest.canEdit else { return drop(connection) }
            // While the host's away, changes go nowhere; guests send them again when it's back.
            guard let host = room.host else { return [] }
            return [.send(host, Wire.stamp(bytes, peer: guest.peer))]
        case .presence:
            let stamped = Wire.stamp(bytes, peer: guest.peer)
            return everyone(in: room, except: connection).map { .send($0, stamped) }
        case .ping:
            room.guests[connection]!.applied = min(frame.header.seq, room.latest)
            room.trim()
            return [.send(connection, Wire.Frame(.pong, seq: room.latest).bytes)]
        default:
            return []
        }
    }

    // MARK: Leaving

    private func everyone(in room: Room, except excluded: Connection? = nil) -> [Connection] {
        ([room.host].compactMap { $0 } + room.guests.keys.sorted()).filter { $0 != excluded }
    }

    /// Closes a connection, as the relay's decision.
    private func drop(_ connection: Connection) -> [Effect] {
        [.close(connection)] + forget(connection)
    }

    private func refuse(_ connection: Connection, _ reason: String) -> [Effect] {
        [.send(connection, Relay.bye(reason).bytes)] + drop(connection)
    }

    /// A connection's gone: others are told who's left.
    private func forget(_ connection: Connection) -> [Effect] {
        guard let link = links.removeValue(forKey: connection), let id = link.room, let room = rooms[id] else { return [] }
        if room.host == connection {
            room.host = nil
            room.hostGone = now
            let left = Wire.Frame(.left, peer: Relay.hostPeer).bytes
            return room.guests.keys.sorted().map { .send($0, left) }
        }
        guard let guest = room.guests.removeValue(forKey: connection) else { return [] }
        room.trim()
        let left = Wire.Frame(.left, peer: guest.peer).bytes
        return everyone(in: room).map { .send($0, left) }
    }

    private func end(_ room: Room, _ bye: [UInt8]) -> [Effect] {
        rooms[room.id] = nil
        return everyone(in: room).flatMap { connection -> [Effect] in
            links[connection] = nil
            return [.send(connection, bye), .close(connection)]
        }
    }
}
