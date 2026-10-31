import CryptoKit
import Foundation
import Testing
@testable import Joinery

/// Presence over UDP (`docs/relay.md`, "Presence over UDP"): the datagrams, byte for byte as the Zig relay's; the link's
/// every state and way out of it, on a clock the tests hold; presence kept in order whichever way it came; and, against
/// the Zig relay itself when `scripts/relay-e2e.sh` starts it, sessions through it with UDP, without, and with UDP
/// blocked.
struct DatagramTests {
    /// `relay/src/server/udp.zig`'s `vector`.
    static let ticket: [UInt8] = {
        var body: [UInt8] = []
        body.append(littleEndian: UInt64(0x0100_0000_1234_0005))
        body += (0..<16).map { UInt8($0) }
        body += (0..<16).map { UInt8(0xF0 + $0) }
        body.append(littleEndian: UInt16(8787))
        return body
    }()
    static let frame: [UInt8] = [1, 7, 0, 0, 4, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0xDE, 0xAD, 0xBE, 0xEF]

    @Test func aDatagramMatchesTheRelays() throws {
        let ticket = try #require(Datagram.Ticket(Self.ticket))
        #expect(ticket.id == 0x0100_0000_1234_0005 && ticket.port == 8787)
        var session = Datagram.Session(ticket)
        _ = session.seal(.toClient, Self.frame)
        let second = session.seal(.toClient, Self.frame)
        let hex = second.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "0500341200000001ac37f6a85e0d947a594da54bf1364c12336faebebc052a7c13b0cb923de3bbe9f3ebd7e80706174b5c90772267329bdadeadbeef")
    }

    @Test func aDatagramOpensOnceForItsOwnSessionUnaltered() throws {
        let ticket = try #require(Datagram.Ticket(Self.ticket))
        var client = Datagram.Session(ticket), relay = Datagram.Session(ticket)
        let datagram = client.seal(.toRelay, Self.frame)
        #expect(relay.open(.toRelay, datagram) == Self.frame)
        #expect(relay.open(.toRelay, datagram) == nil, "a replay")
        // Altered in its ID, counter, tag, header or body, or meant for the other way: dropped, changing nothing.
        for at in [0, 9, 20, 35, Datagram.prefix + Wire.Header.size + 1] {
            var altered = client.seal(.toRelay, Self.frame)
            altered[at] ^= 1
            #expect(relay.open(.toRelay, altered) == nil, "altered at \(at)")
        }
        #expect(relay.open(.toClient, client.seal(.toRelay, Self.frame)) == nil)
        #expect(relay.open(.toRelay, Array(datagram.prefix(40))) == nil, "too short")
        // Out of order within the window, once each; too far behind, never.
        let early = client.seal(.toRelay, Self.frame)
        let late = client.seal(.toRelay, Self.frame)
        #expect(relay.open(.toRelay, late) != nil && relay.open(.toRelay, early) != nil)
        #expect(relay.open(.toRelay, early) == nil)
        let stale = client.seal(.toRelay, Self.frame)
        for _ in 0..<70 { _ = relay.open(.toRelay, client.seal(.toRelay, Self.frame)) }
        #expect(relay.open(.toRelay, stale) == nil)
    }

    @Test func aTicketMayNameAHost() throws {
        #expect(Datagram.Ticket(Array(Self.ticket.dropLast())) == nil, "too short")
        #expect(try #require(Datagram.Ticket(Self.ticket)).host == nil, "the WebSocket's")
        #expect(try #require(Datagram.Ticket(Self.ticket + Array("udp.relay.example.com".utf8))).host == "udp.relay.example.com")
        #expect(Datagram.Ticket(Self.ticket + [UInt8](repeating: 0x61, count: 254)) == nil, "longer than a DNS name")
    }
}

/// `UdpLink`, every way through it, on a clock the test holds. The relay's side of each datagram is a `Datagram.Session`
/// on the same ticket.
struct UdpLinkTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let timing = UdpLink.Timing()
    let presence = Wire.Frame(.presence, seq: 1, body: [1, 2, 3]).bytes

    func at(_ seconds: TimeInterval) -> Date { t0 + seconds }

    /// A link with a ticket, and the relay's session for it.
    func ticketed(enabled: Bool = true) throws -> (UdpLink, Datagram.Session, [UdpLink.Effect]) {
        var link = UdpLink(enabled: enabled, timing: timing)
        let effects = link.ticket(DatagramTests.ticket, at: t0)
        return (link, Datagram.Session(try #require(Datagram.Ticket(DatagramTests.ticket))), effects)
    }

    /// The probe in `effect`, opened by the relay, or nil if it isn't one.
    func probe(_ effect: UdpLink.Effect?, _ relay: inout Datagram.Session) -> Bool {
        guard case .datagram(let bytes) = effect, let frame = relay.open(.toRelay, bytes) else { return false }
        return frame == Datagram.probe
    }

    /// The relay's answer to a probe.
    func answer(_ relay: inout Datagram.Session) -> [UInt8] { relay.seal(.toClient, Datagram.probe) }

    @Test func turnedOffItIgnoresTickets() throws {
        let (link, _, effects) = try ticketed(enabled: false)
        #expect(effects.isEmpty && link.state == .off && link.deadline == nil)
    }

    @Test func aTicketOpensASocketAndProbesOnSchedule() throws {
        var (link, relay, effects) = try ticketed()
        #expect(effects.first == .open(host: nil, port: 8787) && effects.count == 2 && probe(effects.last, &relay))
        #expect(link.state == .probing(since: t0, sent: 1) && link.deadline == at(0.25))
        // Presence goes by WebSocket until a probe's answered.
        #expect(link.presence(presence, at: at(0.1)) == .webSocket(presence))
        #expect(link.tick(at(0.2)).isEmpty)
        for time in [0.25, 0.5, 1, 2, 4] {
            let sent = link.tick(at(time))
            #expect(sent.count == 1 && probe(sent.first, &relay), "probe at \(time)")
        }
        #expect(link.deadline == at(8))
        #expect(link.tick(at(7.9)).isEmpty)
        // None answered: down, the relay told over the WebSocket, presence by WebSocket.
        #expect(link.tick(at(8)) == [.webSocket(Datagram.probe)])
        #expect(link.state == .down(until: at(38)) && link.presence(presence, at: at(9)) == .webSocket(presence))
    }

    @Test func aLateTickSendsOneProbeNotABurst() throws {
        var (link, relay, _) = try ticketed()
        let sent = link.tick(at(3))
        #expect(sent.count == 1 && probe(sent.first, &relay))
        #expect(link.state == .probing(since: t0, sent: 5) && link.deadline == at(4))
    }

    @Test func anAnswerBringsItUpAndPresenceGoesByUDP() throws {
        var (link, relay, _) = try ticketed()
        #expect(link.datagram(answer(&relay), at: at(0.1)) == nil, "an answer carries no presence")
        #expect(link.isUp && link.state == .up(heard: at(0.1), probed: at(0.1)))
        guard case .datagram(let bytes) = link.presence(presence, at: at(0.2)) else { Issue.record("not by UDP"); return }
        #expect(relay.open(.toRelay, bytes) == presence)
        // Presence from the relay comes out as a frame, and counts as heard.
        let from = Wire.Frame(.presence, seq: 9, peer: 2, body: [4]).bytes
        #expect(link.datagram(relay.seal(.toClient, from), at: at(3)) == from)
        #expect(link.state == .up(heard: at(3), probed: at(0.1)))
    }

    @Test func upItProbesWhenIdleAndGivesUpOnSilence() throws {
        var (link, relay, _) = try ticketed()
        _ = link.datagram(answer(&relay), at: at(1))
        #expect(link.deadline == at(6))
        let idle = link.tick(at(6))
        #expect(idle.count == 1 && probe(idle.first, &relay) && link.deadline == at(11))
        #expect(link.tick(at(10)).isEmpty)
        #expect(probe(link.tick(at(11)).first, &relay))
        // Answered: heard again, and the silence clock starts over.
        _ = link.datagram(answer(&relay), at: at(11.5))
        #expect(link.deadline == at(16.5))
        // Nothing more heard, through probes: down at 15 s of silence.
        _ = link.tick(at(16.5))
        _ = link.tick(at(21.5))
        #expect(link.tick(at(26.5)) == [.webSocket(Datagram.probe)])
        #expect(link.state == .down(until: at(56.5)) && !link.isUp)
    }

    @Test func downItTriesAgainLaterAndLaterUntilUp() throws {
        var (link, relay, _) = try ticketed()
        var now = 8.0
        var wait = timing.retry
        _ = link.tick(at(now))
        // Each failed try waits twice as long, up to the most.
        for _ in 0..<6 {
            #expect(link.state == .down(until: at(now + wait)))
            now += wait
            let retried = link.tick(at(now))
            #expect(retried.count == 1 && probe(retried.first, &relay), "a probe at \(now)")
            for step in timing.probes.dropFirst() { _ = link.tick(at(now + step)) }
            now += timing.probeTimeout
            #expect(link.tick(at(now)) == [.webSocket(Datagram.probe)])
            wait = min(wait * 2, timing.maxRetry)
        }
        #expect(link.state == .down(until: at(now + timing.maxRetry)))
        // A try that's answered comes up, and the next fall waits the first while again.
        now += timing.maxRetry
        _ = link.tick(at(now))
        _ = link.datagram(answer(&relay), at: at(now + 0.1))
        #expect(link.isUp)
        _ = link.socketFailed(at: at(now + 1))
        #expect(link.state == .down(until: at(now + 1 + timing.retry)))
    }

    @Test func aFailedSocketGoesDownAndIsOpenedAfresh() throws {
        var (link, relay, _) = try ticketed()
        _ = link.datagram(answer(&relay), at: at(1))
        #expect(link.socketFailed(at: at(2)) == [.webSocket(Datagram.probe)])
        #expect(link.presence(presence, at: at(3)) == .webSocket(presence))
        #expect(link.socketFailed(at: at(4)).isEmpty, "down already")
        let retried = link.tick(at(32))
        #expect(retried.first == .open(host: nil, port: 8787) && retried.count == 2 && probe(retried.last, &relay))
    }

    @Test func aDroppedWebSocketTakesItsTicket() throws {
        var (link, relay, _) = try ticketed()
        _ = link.datagram(answer(&relay), at: at(1))
        #expect(link.disconnected() == [.close])
        #expect(link.state == .off && link.deadline == nil && link.presence(presence, at: at(2)) == .webSocket(presence))
        #expect(link.datagram(answer(&relay), at: at(3)) == nil && link.state == .off, "the old ticket's datagrams")
        #expect(link.disconnected().isEmpty, "nothing open")
        // The next connection's ticket starts over.
        #expect(link.ticket(DatagramTests.ticket, at: at(4)).first == .open(host: nil, port: 8787))
    }

    @Test func whatDoesntOpenChangesNothing() throws {
        var (link, relay, _) = try ticketed()
        var forged = answer(&relay)
        forged[40] ^= 1
        #expect(link.datagram(forged, at: at(0.1)) == nil && link.state == .probing(since: t0, sent: 1))
        #expect(link.datagram([1, 2, 3], at: at(0.1)) == nil)
        // Up, a replayed answer doesn't count as heard.
        let answered = answer(&relay)
        _ = link.datagram(answered, at: at(1))
        _ = link.datagram(answered, at: at(9))
        #expect(link.state == .up(heard: at(1), probed: at(1)))
    }

    @Test func aLateAnswerWhileDownLeavesItDown() throws {
        var (link, relay, _) = try ticketed()
        let late = answer(&relay)
        _ = link.tick(at(8))
        #expect(link.datagram(late, at: at(9)) == nil && link.state == .down(until: at(38)))
    }

    @Test func presenceTooBigForADatagramGoesByWebSocket() throws {
        var (link, relay, _) = try ticketed()
        _ = link.datagram(answer(&relay), at: at(1))
        let big = Wire.Frame(.presence, body: [UInt8](repeating: 0, count: Datagram.maxSize)).bytes
        #expect(link.presence(big, at: at(2)) == .webSocket(big))
    }
}

/// Presence kept in order whichever way it came, and only for people here.
struct PresenceOrderTests {
    let key = SymmetricKey(size: .bits256)

    func welcomedGuest() -> RelayGuestCore {
        let core = RelayGuestCore(room: "room", secret: "secret", key: key, name: "Guest")
        _ = core.connected(at: .now)
        let welcome = Relay.Welcome(peer: 2, room: "room", limits: Relay.Limits(), latest: 0, version: Relay.roomVersion,
                                    title: Array("Title".utf8), peers: [1: Array("Host".utf8)])
        _ = core.received(welcome.frame.bytes, at: .now)
        return core
    }

    func presence(_ x: Double, seq: UInt64, from peer: UInt32) -> [UInt8] {
        Wire.stamp(Wire.Frame(.presence, seq: seq, sealing: Relay.Presence(cursor: [x, 0]).body, with: key).bytes, peer: peer)
    }

    @Test func olderPresenceThanShownIsDropped() {
        let guest = welcomedGuest()
        _ = guest.received(presence(3, seq: 3, from: 1), at: .now)
        _ = guest.received(presence(2, seq: 2, from: 1), at: .now)
        _ = guest.received(presence(3.5, seq: 3, from: 1), at: .now)
        #expect(guest.peers[1]?.cursor == [3, 0])
        _ = guest.received(presence(4, seq: 4, from: 1), at: .now)
        #expect(guest.peers[1]?.cursor == [4, 0])
        // An older client numbers nothing: each is taken.
        _ = guest.received(presence(1, seq: 0, from: 1), at: .now)
        #expect(guest.peers[1]?.cursor == [1, 0])
    }

    @Test func presenceFromSomeoneNotHereIsDropped() {
        let guest = welcomedGuest()
        _ = guest.received(presence(5, seq: 1, from: 3), at: .now)
        #expect(guest.peers[3] == nil, "before joined")
        _ = guest.received(Wire.Frame(.joined, peer: 3, body: Array("Ann".utf8)).bytes, at: .now)
        _ = guest.received(presence(6, seq: 2, from: 3), at: .now)
        #expect(guest.peers[3]?.cursor == [6, 0])
        _ = guest.received(Wire.Frame(.left, peer: 3).bytes, at: .now)
        _ = guest.received(presence(7, seq: 3, from: 3), at: .now)
        #expect(guest.peers[3] == nil, "after left")
    }

    @Test func sharedPresenceIsNumbered() throws {
        let guest = welcomedGuest()
        var seqs: [UInt64] = []
        for _ in 0..<3 {
            guard case .send(let bytes) = guest.share(Relay.Presence(cursor: [1, 1])).first else { Issue.record("not sent"); return }
            seqs.append(try Wire.Frame(bytes).header.seq)
        }
        #expect(seqs == [1, 2, 3])
    }
}

/// Sessions through the Zig relay, started by `scripts/relay-e2e.sh`: with UDP, without, and with UDP blocked (its
/// tickets name a port nothing's on). Skipped when it hasn't started them.
@MainActor @Suite(.serialized)
struct ZigRelayTests {
    nonisolated static func relay(_ name: String) -> URL? {
        ProcessInfo.processInfo.environment[name].flatMap(URL.init(string:))
    }

    private func openStorefront() throws -> OpenModel {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let example = try #require(Bundle.main.urls(forResourcesWithExtension: "joinery", subdirectory: nil)?.first { $0.lastPathComponent == "Storefront.joinery" })
        let url = folder.appending(path: "Storefront.joinery")
        try FileManager.default.copyItem(at: example, to: url)
        return try OpenModel(url: url)
    }

    private func until(_ seconds: Double = 5, _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let end = Date.now + seconds
        while !condition(), Date.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    /// A host and a guest through `relay`, with the model opened on both.
    private func session(through relay: URL) async throws -> (host: SessionHost, guest: SessionClient, hosted: OpenModel, joined: OpenModel) {
        let hosted = try openStorefront()
        let host = SessionHost(model: hosted, relay: relay)
        hosted.session = host
        try await until { host.links != nil }
        var opened: OpenModel?
        let guest = try #require(SessionClient(link: host.links?.edit ?? "") { _, _ in opened = try? self.openStorefront() })
        try await until { opened != nil }
        let joined = try #require(opened)
        guest.attach(to: joined)
        try await until { !host.peers.isEmpty && !guest.peers.isEmpty }
        return (host, guest, hosted, joined)
    }

    /// Pointers moving both ways: each side ends up showing where the other's stopped.
    private func pointersMove(_ host: SessionHost, _ guest: SessionClient, from start: Int = 0) async throws {
        for x in start + 1...start + 40 {
            guest.share(Relay.Presence(cursor: [Double(x), 1]))
            host.share(Relay.Presence(cursor: [1, Double(x)]))
            try await Task.sleep(for: .milliseconds(5))
        }
        let end = Double(start + 40)
        try await until { host.peers.values.first?.cursor == [end, 1] && guest.peers.values.first?.cursor == [1, end] }
    }

    /// What the relay's counted, from its metrics.
    private func metric(_ name: String, at metrics: URL) async throws -> Double? {
        let (data, _) = try await URLSession.shared.data(from: metrics.appending(path: "metrics"))
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .first { $0.hasPrefix("joinery_relay_\(name) ") }.flatMap { Double($0.split(separator: " ").last ?? "") }
    }

    @Test(.enabled(if: relay("JOINERY_RELAY_UDP") != nil))
    func presenceGoesByUDPWhenItCan() async throws {
        let relay = try #require(Self.relay("JOINERY_RELAY_UDP"))
        let metrics = try #require(Self.relay("JOINERY_RELAY_UDP_METRICS"))
        let before = try await metric("udp_received_total", at: metrics) ?? 0
        let (host, guest, hosted, joined) = try await session(through: relay)
        defer { guest.close(); host.close() }
        try await until { host.presenceOverUDP && guest.presenceOverUDP }
        try await pointersMove(host, guest)
        #expect(host.presenceOverUDP && guest.presenceOverUDP)
        // The relay took them as datagrams: 80 pointer updates, and the probes. It publishes its counts once a second.
        var after = before
        for _ in 0..<50 where after - before < 80 {
            try await Task.sleep(for: .milliseconds(100))
            after = try await metric("udp_received_total", at: metrics) ?? 0
        }
        #expect(after - before >= 80, "the relay took \(after - before) datagrams")
        // Changes still go by WebSocket, both ways.
        var model = joined.model
        model.tables[0].name = "by_websocket"
        joined.change(to: model)
        try await until { hosted.model == joined.model }
    }

    @Test(.enabled(if: relay("JOINERY_RELAY_TCP") != nil))
    func presenceGoesByWebSocketWhenTheRelayHasNoUDP() async throws {
        let relay = try #require(Self.relay("JOINERY_RELAY_TCP"))
        let (host, guest, _, _) = try await session(through: relay)
        defer { guest.close(); host.close() }
        try await pointersMove(host, guest)
        #expect(!host.presenceOverUDP && !guest.presenceOverUDP)
    }

    @Test(.enabled(if: relay("JOINERY_RELAY_BLOCKED") != nil))
    func presenceGoesByWebSocketWhenUDPIsBlocked() async throws {
        let relay = try #require(Self.relay("JOINERY_RELAY_BLOCKED"))
        let saved = RelayConnection.timing
        RelayConnection.timing.probes = [0, 0.1, 0.2]
        RelayConnection.timing.probeTimeout = 0.5
        defer { RelayConnection.timing = saved }
        let (host, guest, _, _) = try await session(through: relay)
        defer { guest.close(); host.close() }
        // Moving from the start, while the link's still probing, and after it's given up: nothing's lost either way.
        try await pointersMove(host, guest)
        try await Task.sleep(for: .seconds(0.6))
        try await pointersMove(host, guest, from: 100)
        #expect(!host.presenceOverUDP && !guest.presenceOverUDP)
    }
}
