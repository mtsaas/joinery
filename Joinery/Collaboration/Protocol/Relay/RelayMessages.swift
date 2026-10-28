import CryptoKit
import Foundation

/// The bodies of a relayed session's messages (see `docs/relay.md`). A relay reads only `Hello`; it writes `Welcome`,
/// `joined`, `left`, `pong` and `bye`; everything else it passes on as bytes. Peer 1 is always the host.
enum Relay {
    static let hostPeer: UInt32 = 1
    /// The relay sessions go through unless Settings names another.
    static let ours = URL(string: "https://relay.joinery.clarkmccauley.com")!
    /// The room version this copy speaks: what's inside the encryption, the ops and the model's fields.
    static let roomVersion: UInt64 = 1
    /// The longest a `hello`'s client, name and title can be, in bytes, so a relay can keep them in fixed space.
    static let maxClient = 64, maxName = 64, maxTitle = 256

    /// What a relay holds each room to. Clients check against them before sending.
    struct Limits: Equatable {
        /// The largest frame, header included.
        var maxFrame = 1 << 20
        var maxSnapshot = 1 << 20
        /// How many bytes of frames a room's log holds.
        var logBytes = 2 << 20
        var maxPeers = 32
    }

    enum Role: UInt8 { case host = 1, resume, guest, view }

    struct Hello: Equatable {
        var role: Role
        /// For all but `host`, which makes a new room.
        var room = ""
        var secret = ""
        /// Who's connecting, kept through every reconnection, so a guest stays the same peer.
        var client = ""
        /// The last change a guest has, if it has a copy at all.
        var applied: UInt64?
        /// The host's room version, for guests to check.
        var version = Relay.roomVersion
        /// Who's connecting, to show others: a name.
        var name: [UInt8] = []
        /// The host's: what the room's called, to show guests.
        var title: [UInt8] = []

        var frame: Wire.Frame {
            var body = [role.rawValue]
            body.appendString(room)
            body.appendString(secret)
            body.appendString(client)
            body.appendVarint(Int(applied.map { $0 + 1 } ?? 0))
            body.appendVarint(Int(version))
            body.appendBytes(name)
            body.appendBytes(title)
            return Wire.Frame(.hello, body: body)
        }

        init(role: Role, room: String = "", secret: String = "", client: String = "", applied: UInt64? = nil,
             version: UInt64 = Relay.roomVersion, name: [UInt8] = [], title: [UInt8] = []) {
            self.role = role
            self.room = room
            self.secret = secret
            self.client = client
            self.applied = applied
            self.version = version
            self.name = name
            self.title = title
        }

        init(_ body: [UInt8]) throws(Wire.Malformed) {
            var reader = Wire.Reader(body)
            guard let role = Role(rawValue: try reader.byte()) else { throw Wire.Malformed("an unknown role") }
            self.role = role
            room = try reader.string()
            secret = try reader.string()
            client = try reader.string()
            let applied = try reader.varint()
            self.applied = applied == 0 ? nil : applied - 1
            version = try reader.varint()
            name = try reader.blob()
            title = try reader.blob()
        }
    }

    /// The relay's answer to `Hello`.
    struct Welcome: Equatable {
        var peer: UInt32
        var room: String
        /// Only for the host: the secrets its links carry, and its own, to come back with.
        var hostSecret = "", guestSecret = "", viewSecret = ""
        var limits: Limits
        /// The room's latest change, as the relay has it.
        var latest: UInt64
        var version: UInt64
        var title: [UInt8]
        /// Who's here besides the one welcomed, by peer, with their names.
        var peers: [UInt32: [UInt8]]

        var frame: Wire.Frame {
            var body: [UInt8] = []
            body.appendVarint(Int(peer))
            body.appendString(room)
            body.appendString(hostSecret)
            body.appendString(guestSecret)
            body.appendString(viewSecret)
            for limit in [limits.maxFrame, limits.maxSnapshot, limits.logBytes, limits.maxPeers] { body.appendVarint(limit) }
            body.appendVarint(Int(latest))
            body.appendVarint(Int(version))
            body.appendBytes(title)
            body.appendVarint(peers.count)
            for peer in peers.keys.sorted() {
                body.appendVarint(Int(peer))
                body.appendBytes(peers[peer]!)
            }
            return Wire.Frame(.hello, body: body)
        }

        init(peer: UInt32, room: String, hostSecret: String = "", guestSecret: String = "", viewSecret: String = "",
             limits: Limits, latest: UInt64, version: UInt64, title: [UInt8], peers: [UInt32: [UInt8]]) {
            self.peer = peer
            self.room = room
            self.hostSecret = hostSecret
            self.guestSecret = guestSecret
            self.viewSecret = viewSecret
            self.limits = limits
            self.latest = latest
            self.version = version
            self.title = title
            self.peers = peers
        }

        init(_ body: [UInt8]) throws(Wire.Malformed) {
            var reader = Wire.Reader(body)
            peer = UInt32(truncatingIfNeeded: try reader.varint())
            room = try reader.string()
            hostSecret = try reader.string()
            guestSecret = try reader.string()
            viewSecret = try reader.string()
            limits = Limits(maxFrame: Int(try reader.varint()), maxSnapshot: Int(try reader.varint()),
                            logBytes: Int(try reader.varint()), maxPeers: Int(try reader.varint()))
            latest = try reader.varint()
            version = try reader.varint()
            title = try reader.blob()
            peers = [:]
            for _ in 0..<(try reader.count()) {
                let peer = UInt32(truncatingIfNeeded: try reader.varint())
                peers[peer] = try reader.blob()
            }
        }
    }

    /// The host's decision on a change, numbered by the frame's `seq`: made (an `ops` frame, with its ops) or turned
    /// down (a `reject` frame, with why). Either way, with the document's digest after it. The author is the guest whose
    /// change it was, or the host, whose own changes have no `cseq`.
    struct Decision: Equatable {
        var author: UInt32
        var cseq: UInt64
        var digest: [UInt8]
        /// An `ops` frame's ops, or a `reject` frame's reason, as UTF-8.
        var content: [UInt8]

        var body: [UInt8] {
            var body: [UInt8] = []
            body.appendVarint(Int(author))
            body.appendVarint(Int(cseq))
            body.append(contentsOf: digest)
            return body + content
        }

        init(author: UInt32, cseq: UInt64, digest: [UInt8], content: [UInt8]) {
            self.author = author
            self.cseq = cseq
            self.digest = digest
            self.content = content
        }

        init(_ body: [UInt8]) throws(Wire.Malformed) {
            var reader = Wire.Reader(body)
            author = UInt32(truncatingIfNeeded: try reader.varint())
            cseq = try reader.varint()
            digest = Array(try reader.take(8))
            content = reader.rest()
        }
    }

    /// The whole document as of the frame's `seq`, with its digest and the last change taken from each guest, so a guest
    /// catching up from it knows which of its own are done.
    struct Snapshot: Equatable {
        var digest: [UInt8]
        var taken: [UInt32: UInt64]
        var entities: [Replica.Entity]

        var body: [UInt8] {
            var body = digest
            body.appendVarint(taken.count)
            for peer in taken.keys.sorted() {
                body.appendVarint(Int(peer))
                body.appendVarint(Int(taken[peer]!))
            }
            return body + Wire.encode(entities.map { .put($0) })
        }

        init(digest: [UInt8], taken: [UInt32: UInt64], entities: [Replica.Entity]) {
            self.digest = digest
            self.taken = taken
            self.entities = entities
        }

        init(_ body: [UInt8]) throws(Wire.Malformed) {
            var reader = Wire.Reader(body)
            digest = Array(try reader.take(8))
            taken = [:]
            for _ in 0..<(try reader.count()) {
                let peer = UInt32(truncatingIfNeeded: try reader.varint())
                taken[peer] = try reader.varint()
            }
            entities = try Wire.decode(reader.rest()).compactMap { if case .put(let entity) = $0 { entity } else { nil } }
        }
    }

    /// Where someone's pointer is and what they have selected, sealed: the relay stamps who it's from.
    struct Presence: Equatable {
        /// In canvas points, if it's over the canvas.
        var cursor: [Double]?
        /// The IDs of what's selected.
        var selection: [String] = []

        var body: [UInt8] {
            var body: [UInt8] = [cursor == nil ? 0 : 1]
            for value in cursor ?? [] { body.append(littleEndian: value.bitPattern) }
            body.appendVarint(selection.count)
            for id in selection { body.appendString(id) }
            return body
        }

        init(cursor: [Double]? = nil, selection: [String] = []) {
            self.cursor = cursor
            self.selection = selection
        }

        init(_ body: [UInt8]) throws(Wire.Malformed) {
            var reader = Wire.Reader(body)
            if try reader.byte() != 0 {
                cursor = [Double(bitPattern: try reader.integer()), Double(bitPattern: try reader.integer())]
            }
            for _ in 0..<(try reader.count()) { selection.append(try reader.string()) }
        }
    }

    /// Someone in a room, as everyone else shows them: named as they joined, colored by their peer.
    static func peer(_ peer: UInt32, name: [UInt8]) -> Peer {
        Peer(id: String(peer), name: name.isEmpty ? "Guest" : String(decoding: name, as: UTF8.self), color: color(of: peer))
    }

    /// Everyone's color, by their peer, so it needn't be sent: the host's is blue.
    static func color(of peer: UInt32) -> String {
        let palette = ["blue", "purple", "pink", "orange", "green", "teal", "indigo", "red", "mint", "cyan", "brown", "yellow"]
        return palette[Int(peer &- 1) % palette.count]
    }

    /// A share link, `https://<relay>/r/<room>#key=…&token=…` (or `&view=…`, to only watch). The key and secret are
    /// after the `#`, so they never travel in a request, and the relay never learns the key.
    struct Link: Equatable {
        /// The relay's address, as `https://…` or `http://…`.
        var relay: URL
        var room: String
        var key: SymmetricKey
        var secret: String
        var canEdit: Bool

        static func == (a: Link, b: Link) -> Bool {
            a.relay == b.relay && a.room == b.room && a.secret == b.secret && a.canEdit == b.canEdit
                && a.key.withUnsafeBytes { Data($0) } == b.key.withUnsafeBytes { Data($0) }
        }

        var text: String {
            let key = key.withUnsafeBytes { Data($0) }.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let base = relay.absoluteString.hasSuffix("/") ? String(relay.absoluteString.dropLast()) : relay.absoluteString
            return "\(base)/r/\(room)#key=\(key)&\(canEdit ? "token" : "view")=\(secret)"
        }

        /// Where to connect: the relay's WebSocket.
        var socket: URL { Relay.socket(of: relay) }

        init(relay: URL, room: String, key: SymmetricKey, secret: String, canEdit: Bool) {
            self.relay = relay
            self.room = room
            self.key = key
            self.secret = secret
            self.canEdit = canEdit
        }

        init?(_ text: String) {
            guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  parts.scheme == "https" || parts.scheme == "http", let host = parts.host, !host.isEmpty,
                  parts.path.hasPrefix("/r/"), case let room = String(parts.path.dropFirst(3)), !room.isEmpty, !room.contains("/")
            else { return nil }
            var fields: [String: String] = [:]
            for pair in (parts.fragment ?? "").split(separator: "&") {
                let field = pair.split(separator: "=", maxSplits: 1)
                if field.count == 2 { fields[String(field[0])] = String(field[1]) }
            }
            var base64 = (fields["key"] ?? "").replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let key = Data(base64Encoded: base64), key.count == 32, let secret = fields["token"] ?? fields["view"], !secret.isEmpty
            else { return nil }
            var relay = parts
            relay.path = ""
            relay.fragment = nil
            relay.query = nil
            guard let url = relay.url else { return nil }
            self.init(relay: url, room: room, key: SymmetricKey(data: key), secret: secret, canEdit: fields["token"] != nil)
        }
    }

    /// A relay's WebSocket, from its address: `wss://` for `https://`, `ws://` for `http://`.
    static func socket(of relay: URL) -> URL {
        var parts = URLComponents(url: relay, resolvingAgainstBaseURL: false) ?? URLComponents()
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.path = "/"
        parts.fragment = nil
        return parts.url ?? relay
    }

    /// Why a relay or host ended a session, or turned a connection away.
    static func bye(_ reason: String) -> Wire.Frame { bye(Array(reason.utf8)) }
    static func bye(_ reason: [UInt8]) -> Wire.Frame { Wire.Frame(.bye, body: reason) }
}
