import CryptoKit
import CoreGraphics
import Foundation
import Testing
@testable import Joinery

/// The relayed session protocol, run as a simulation: a real `RelayCore`, `RelayHostCore` and `RelayGuestCore`s, with a
/// network between them that delivers in any order across connections (each in order, as TCP does) and cuts connections
/// partway, the host's included, while everyone edits at random. Logs are small in most runs, so the relay asks for
/// snapshots, drops guests that fall behind, and drops the host when its log fills.
///
/// After every step, every guest with a copy must have the host's document exactly as it was at some decision. At the
/// end, with the network let settle, every copy must be the host's, and every change every guest made must have been
/// decided, made or turned down, exactly once.
///
/// Unlike `SessionSimulation`, nothing's lost, repeated or garbled on a connection that stays up: TCP rules that out,
/// and from step 3, encryption turns a garbled frame into one that's refused, which a cut connection already covers.
struct RelaySimulation {
    @Test(arguments: 1...400 as ClosedRange<UInt64>)
    func everyCopyComesBackToTheHosts(seed: UInt64) throws {
        let simulation = try RelayNetwork(seed: seed, guests: 3)
        for _ in 0..<300 { simulation.step(); try simulation.checkInvariant() }
        simulation.settle()
        try simulation.checkSettled()
        if !simulation.isSettled { Attachment.record(simulation.trace.suffix(80).joined(separator: "\n"), named: "trace-\(seed).txt") }
    }

    /// Everything the relay heard and did in a few runs, one for each log size, one with a viewer and a host that
    /// doesn't come back: the Zig relay replays them and must send the same bytes (`scripts/record-relay-traces.sh`).
    @Test func recordsTracesForTheZigRelay() throws {
        for seed in 1...4 as ClosedRange<UInt64> {
            let simulation = try RelayNetwork(seed: seed, guests: 3, recording: true)
            for _ in 0..<300 { simulation.step() }
            simulation.settle()
            Attachment.record(Data(simulation.recording!), named: "seed-\(seed).trace")
        }
        let ending = try RelayNetwork(seed: 5, guests: 2, viewers: 1, hostGrace: 30, recording: true)
        for _ in 0..<300 { ending.step() }
        ending.cutHost()
        ending.advanceTime(by: 31)
        ending.deliverAll()
        Attachment.record(Data(ending.recording!), named: "host-gone.trace")
    }

    /// The paths the protocol's correctness rests on actually happen in the runs above, often.
    @Test func theRunsCoverEveryWayOfCatchingUp() throws {
        var totals = RelayNetwork.Counts()
        for seed in 1...60 as ClosedRange<UInt64> {
            let simulation = try RelayNetwork(seed: seed, guests: 3)
            for _ in 0..<300 { simulation.step() }
            simulation.settle()
            totals += simulation.counts
        }
        Attachment.record(totals.description, named: "relay-coverage.txt")
        #expect(totals.snapshotRequests > 20, "\(totals)")
        #expect(totals.laggingGuestsDropped > 5, "\(totals)")
        #expect(totals.hostDropped > 5, "\(totals)")
        #expect(totals.catchUpsFromSnapshot > 20, "\(totals)")
        #expect(totals.catchUpsFromLog > 20, "\(totals)")
        #expect(totals.turnedDown > 5, "\(totals)")
    }
}

extension RelaySimulation {
    /// A room ends when its host has been gone longer than the relay waits, and its guests are told.
    @Test func aRoomEndsWhenItsHostDoesntComeBack() throws {
        let network = try RelayNetwork(seed: 1, guests: 1, faults: false, hostGrace: 30)
        network.settle()
        #expect(network.guests[0].state == .connected)
        network.cutHost()
        network.advanceTime(by: 20)
        network.deliverAll()
        #expect(network.relay.roomCount == 1)
        network.advanceTime(by: 15)
        network.deliverAll()
        #expect(network.relay.roomCount == 0)
        #expect(network.problems == ["guest 0 ended: The host stopped sharing."])
    }

    /// A view link shows the model, and changes nothing: the guest doesn't send, and the relay lets go of one that does.
    @Test func aViewLinkChangesNothing() throws {
        let network = try RelayNetwork(seed: 2, guests: 1, faults: false, viewers: 1)
        network.settle()
        let viewer = network.guests[1]
        #expect(viewer.state == .connected && viewer.confirmed.replica == network.host.document.replica)
        // Taken back here, never sent.
        #expect(!viewer.changedHere([.set(id: UUID().uuidString, field: "name", value: .string("x"))]).contains { if case .send = $0 { true } else { false } })
        let link = try #require(network.currentGuest[1])
        let change = Wire.Frame(.change, seq: 1, body: Wire.encode([.delete(id: "x")])).bytes
        #expect(network.relay.received(change, on: link, at: network.now).first == .close(link))
    }

    /// A guest that can't read the room's version is told which side needs updating.
    @Test func aGuestOfAnotherVersionIsToldWhoNeedsUpdating() {
        for (version, reason) in [(Relay.roomVersion + 1, "This session needs a newer Joinery."), (0, "The host needs a newer Joinery.")] {
            let guest = RelayGuestCore(room: "r", secret: "s", key: SymmetricKey(size: .bits256), name: "Guest")
            _ = guest.connected(at: .now)
            let welcome = Relay.Welcome(peer: 2, room: "r", limits: Relay.Limits(), latest: 0, version: version, title: [], peers: [:])
            guard case .ended(let said)? = guest.received(welcome.frame.bytes, at: .now).first else { Issue.record("joined"); continue }
            #expect(said == reason)
        }
    }

    /// Found by the simulation: a change that leaves something dangling (here, a column deleted out from under a
    /// foreign key) is published with the host's tidying after it, and each must carry the digest of the document right
    /// after it, not after both, or every guest's check fails on the first.
    @Test func aChangeAndItsTidyingEachCarryTheirOwnDigest() throws {
        let example = try #require(Bundle.main.urls(forResourcesWithExtension: "joinery", subdirectory: nil)?.first { $0.lastPathComponent == "Storefront.joinery" })
        let start = Replica(try DataModel(contentsOf: example))
        let wire = try #require(start.entities.values.first { $0["kind"] == .string("relationship") })
        let column = try #require(wire["from"]?.string)
        var copy = CheckedReplica(start)

        // The relayed host.
        let host = RelayHostCore(start, title: "t", name: "Host")
        _ = host.connected(at: .now)
        let welcome = Relay.Welcome(peer: 1, room: "r", limits: Relay.Limits(), latest: 0, version: 1, title: [], peers: [:])
        _ = host.received(welcome.frame.bytes, at: .now)
        let change = Wire.stamp(Wire.Frame(.change, seq: 1, sealing: Wire.encode([.delete(id: column)]), with: host.key).bytes, peer: 2)
        let published = host.received(change, at: .now).compactMap { effect -> Wire.Frame? in
            if case .send(let bytes) = effect { try? Wire.Frame(bytes) } else { nil }
        }
        #expect(published.map(\.header.kind) == [.ops, .ops])
        for frame in published {
            let decision = try Relay.Decision(try frame.opened(with: host.key))
            copy.apply(try Wire.decode(decision.content))
            #expect(decision.digest == copy.digest.bytes, "decision \(frame.header.seq)")
        }
        #expect(copy.replica == host.document.replica)
    }

    /// The relay's messages read back as they were written.
    @Test func relayMessagesReadBack() throws {
        let hello = Relay.Hello(role: .resume, room: "room", secret: "s", client: "c", applied: 0, version: 3, name: [1, 2], title: [3])
        #expect(try Relay.Hello(hello.frame.body) == hello)
        #expect(try Relay.Hello(Relay.Hello(role: .guest).frame.body).applied == nil)
        let welcome = Relay.Welcome(peer: 7, room: "r", hostSecret: "h", guestSecret: "g", viewSecret: "v",
                                    limits: Relay.Limits(maxFrame: 1, maxSnapshot: 2, logBytes: 3, maxPeers: 4),
                                    latest: 99, version: 1, title: Array("T".utf8), peers: [1: [9], 3: []])
        #expect(try Relay.Welcome(welcome.frame.body) == welcome)
        let decision = Relay.Decision(author: 5, cseq: 6, digest: Array(0..<8), content: [1, 2, 3])
        #expect(try Relay.Decision(decision.body) == decision)
        let snapshot = Relay.Snapshot(digest: Array(0..<8), taken: [2: 4, 3: 1], entities: [["id": .string("a"), "kind": .string("table")]])
        #expect(try Relay.Snapshot(snapshot.body) == snapshot)
        for presence in [Relay.Presence(cursor: [1.5, -2], selection: ["A", "B"], drag: [3, 4], marquee: [1, 2, 3, 4]), Relay.Presence(), Relay.Presence(drag: [0, 1]), Relay.Presence(marquee: [5, 6, 7, 8])] {
            #expect(try Relay.Presence(presence.body) == presence)
        }
        // From before drags were shared: not dragging.
        #expect(try Relay.Presence(Array(Relay.Presence(cursor: [1, 2]).body.dropLast())).drag == nil)
        // A relay stamps the sender into the header and changes nothing else.
        let frame = Wire.Frame(.change, seq: 3, body: [7, 7]).bytes
        let stamped = Wire.stamp(frame, peer: 0x0102_0304)
        #expect(try Wire.Frame(stamped).header.peer == 0x0102_0304 && Array(stamped[..<16]) == Array(frame[..<16]) && stamped[20...] == frame[20...])
    }
}

/// A relay, a host and guests, and the network between them.
final class RelayNetwork {
    enum End: Equatable { case host, guest(Int) }

    final class Link {
        let id: Int, end: End
        var toRelay: [[UInt8]] = [], toPeer: [[UInt8]] = []
        /// Each side, once it's been told the connection's gone.
        var isOpen = true, relayKnows = false, peerKnows = false
        init(id: Int, end: End) { self.id = id; self.end = end }
    }

    struct Counts: CustomStringConvertible {
        var snapshotRequests = 0, laggingGuestsDropped = 0, hostDropped = 0, catchUpsFromSnapshot = 0, catchUpsFromLog = 0, turnedDown = 0
        static func += (a: inout Counts, b: Counts) {
            a.snapshotRequests += b.snapshotRequests
            a.laggingGuestsDropped += b.laggingGuestsDropped
            a.hostDropped += b.hostDropped
            a.catchUpsFromSnapshot += b.catchUpsFromSnapshot
            a.catchUpsFromLog += b.catchUpsFromLog
            a.turnedDown += b.turnedDown
        }
        var description: String {
            "snapshot requests \(snapshotRequests), lagging guests dropped \(laggingGuestsDropped), host dropped \(hostDropped), "
                + "caught up from snapshot \(catchUpsFromSnapshot), from log \(catchUpsFromLog), turned down \(turnedDown)"
        }
    }

    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state ^ (state >> 33)
        }
    }

    var random: Seeded
    let faults: Bool
    let relay: RelayCore
    let host: RelayHostCore
    /// The host's open model, as the app keeps it.
    var hostModel: Replica
    private(set) var guests: [RelayGuestCore] = []
    let guestCount: Int, viewers: Int
    var shown: [Replica] = []
    var links: [Int: Link] = [:]
    var currentHost: Int?
    var currentGuest: [Int: Int] = [:]
    var hostWaiting = false
    var waiting: Set<Int> = []
    var nextLink = 1
    var now = Date(timeIntervalSinceReferenceDate: 0)
    /// The host's document after each decision, followed from what it publishes.
    var history: [UInt64: Replica]
    var following: Replica
    /// Each guest's changes made, and those decided (made or turned down), by number.
    var made: [Int] = []
    var settled: [[UInt64]] = []
    var problems: [String] = []
    var counts = Counts()
    /// What happened, in brief, for working out a failure.
    var trace: [String] = []
    private func kind(_ bytes: [UInt8]) -> String {
        guard let frame = try? Wire.Frame(bytes) else { return "?" }
        return "\(frame.header.kind)#\(frame.header.seq)p\(frame.header.peer)"
    }
    /// Guests' links that are catching up, and whether a snapshot's come on them.
    private var catchingUp: [Int: Bool] = [:]

    /// Everything the relay heard and did, when recording, in the form `relay/src/replay_test.zig` reads.
    private(set) var recording: [UInt8]?

    init(seed: UInt64, guests: Int, faults: Bool = true, viewers: Int = 0, hostGrace: TimeInterval = 1e9, recording: Bool = false) throws {
        random = Seeded(state: seed)
        self.faults = faults
        guestCount = guests
        self.viewers = viewers
        var secrets = 0
        // Small logs most of the time, so snapshots, drops and catching up happen; a roomy one sometimes.
        let logBytes = faults ? [1_500, 3_000, 6_000, 1 << 20][Int(seed % 4)] : 1 << 20
        let limits = Relay.Limits(logBytes: logBytes, maxPeers: 8)
        // As the Zig relay makes them, from 16 random bytes; here the bytes count up, as its replay's do.
        relay = RelayCore(limits: limits, hostGrace: hostGrace) {
            secrets += 1
            var bytes: [UInt8] = []
            bytes.append(littleEndian: UInt64(secrets))
            bytes.append(littleEndian: UInt64(0))
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        if recording {
            var header = Array("JRT1".utf8)
            for limit in [limits.maxFrame, limits.maxSnapshot, limits.logBytes, limits.maxPeers] { header.append(littleEndian: UInt32(limit)) }
            header.append(littleEndian: UInt64(hostGrace * 1000))
            self.recording = header
        }
        let example = try #require(Bundle.main.urls(forResourcesWithExtension: "joinery", subdirectory: nil)?.first { $0.lastPathComponent == "Storefront.joinery" })
        let start = Replica(try DataModel(contentsOf: example))
        hostModel = start
        host = RelayHostCore(start, title: "Simulated", name: "Host")
        history = [0: start]
        following = start
        host.onPublish = { [unowned self] seq, ops, author, cseq in
            _ = self.following.apply(ops)
            self.history[seq] = self.following
            if ops.isEmpty { self.counts.turnedDown += 1 }
            if author != Relay.hostPeer, let index = self.guests.firstIndex(where: { $0.you == author }) {
                self.settled[index].append(cseq)
            }
        }
        connectHost()
    }

    var orderedLinks: [Link] { links.keys.sorted().map { links[$0]! } }

    // MARK: Recording

    enum Event: UInt8 { case opened = 1, closed, received, tick }

    private func relayReceived(_ bytes: [UInt8], on connection: Int) -> [RelayCore.Effect] {
        record(.received, connection, bytes: bytes, relay.received(bytes, on: connection, at: now))
    }

    /// Writes down an event and what the relay did: tag, time in ms, connection, bytes, then each effect.
    @discardableResult
    private func record(_ event: Event, _ connection: Int, bytes: [UInt8] = [], _ effects: [RelayCore.Effect]) -> [RelayCore.Effect] {
        guard recording != nil else { return effects }
        func append(_ tag: UInt8, _ connection: Int, _ bytes: [UInt8]) {
            recording!.append(tag)
            recording!.append(littleEndian: UInt32(connection))
            recording!.append(littleEndian: UInt32(bytes.count))
            recording!.append(contentsOf: bytes)
        }
        append(event.rawValue, connection, bytes)
        recording!.append(littleEndian: UInt64(now.timeIntervalSinceReferenceDate * 1000))
        recording!.append(littleEndian: UInt32(effects.count))
        for effect in effects {
            switch effect {
            case .send(let to, let bytes): append(1, to, bytes)
            case .close(let to): append(2, to, [])
            }
        }
        return effects
    }

    // MARK: Steps

    func step() {
        switch Int.random(in: 0..<100, using: &random) {
        case 0..<30: deliverToRelay()
        case 30..<60: deliverToPeer()
        case 60..<72: guestEdits()
        case 72..<78: hostEdits()
        case 78..<85: connectOne()
        case 85..<90: if faults { cut() } else { deliverToPeer() }
        default: advanceTime(by: .random(in: 1...12, using: &random))
        }
        finishClosing()
    }

    private func deliverToRelay() {
        guard let link = orderedLinks.filter({ !$0.toRelay.isEmpty && !$0.relayKnows }).randomElement(using: &random) else { return }
        route(relayReceived(link.toRelay.removeFirst(), on: link.id))
    }

    private func deliverToPeer() {
        guard let link = orderedLinks.filter({ !$0.toPeer.isEmpty && !$0.peerKnows }).randomElement(using: &random) else { return }
        deliver(link)
    }

    private func deliver(_ link: Link) {
        let bytes = link.toPeer.removeFirst()
        switch link.end {
        case .host:
            if bytes[1] == Wire.Kind.snapshotRequest.rawValue { counts.snapshotRequests += 1 }
            route(host.received(bytes, at: now))
        case .guest(let index):
            trace.append("t\(Int(now.timeIntervalSinceReferenceDate)) g\(index) L\(link.id) <- \(kind(bytes)) (at \(guests[index].seq), \(guests[index].state))")
            if bytes[1] == Wire.Kind.snapshot.rawValue { catchingUp[link.id] = true }
            if bytes[1] == Wire.Kind.pong.rawValue, let fromSnapshot = catchingUp.removeValue(forKey: link.id) {
                if fromSnapshot { counts.catchUpsFromSnapshot += 1 } else { counts.catchUpsFromLog += 1 }
            }
            route(guests[index].received(bytes, at: now), from: index)
        }
    }

    private func guestEdits() {
        guard !guests.isEmpty else { return }
        let index = Int.random(in: 0..<guests.count, using: &random)
        let guest = guests[index]
        guard guest.hasCopy, guest.canEdit, guest.state != .ended else { return }
        let before = shown[index]
        let model = before.model
        var edited = model
        Simulation.randomEdit(&edited, &random)
        let ops = before.ops(to: Replica(edited, keeping: before, was: model))
        guard !ops.isEmpty else { return }
        _ = shown[index].apply(ops)
        made[index] += 1
        route(guest.changedHere(ops), from: index)
    }

    private func hostEdits() {
        let model = hostModel.model
        var edited = model
        Simulation.randomEdit(&edited, &random)
        let ops = hostModel.ops(to: Replica(edited, keeping: hostModel, was: model))
        guard !ops.isEmpty else { return }
        _ = hostModel.apply(ops)
        route(host.changedHere(ops))
    }

    private func connectOne() {
        if hostWaiting && (waiting.isEmpty || Bool.random(using: &random)) { return connectHost() }
        guard let index = waiting.sorted().randomElement(using: &random) else { return }
        connect(index)
    }

    private func connectHost() {
        hostWaiting = false
        let link = open(.host)
        currentHost = link.id
        route(host.connected(at: now))
    }

    private func connect(_ index: Int) {
        waiting.remove(index)
        let link = open(.guest(index))
        currentGuest[index] = link.id
        if guests[index].hasCopy { catchingUp[link.id] = false }
        route(guests[index].connected(at: now), from: index)
    }

    private func open(_ end: End) -> Link {
        let link = Link(id: nextLink, end: end)
        nextLink += 1
        links[link.id] = link
        relay.opened(link.id, at: now)
        record(.opened, link.id, [])
        return link
    }

    /// The network drops a connection: each way, some of what was on its way still arrives, the rest never does.
    private func cut() {
        let candidates = orderedLinks.filter {
            guard $0.isOpen else { return false }
            if case .guest(let index) = $0.end { return guests[index].you != nil }
            return host.room != nil
        }
        guard let link = candidates.randomElement(using: &random) else { return }
        cut(link)
    }

    private func cut(_ link: Link) {
        link.isOpen = false
        link.toRelay = Array(link.toRelay.prefix(Int.random(in: 0...link.toRelay.count, using: &random)))
        link.toPeer = Array(link.toPeer.prefix(Int.random(in: 0...link.toPeer.count, using: &random)))
    }

    func cutHost() {
        if let id = currentHost, let link = links[id] { cut(link) }
        finishClosing()
    }

    func advanceTime(by seconds: TimeInterval) {
        now += seconds
        route(record(.tick, 0, relay.tick(at: now)))
        route(host.tick(at: now))
        for index in guests.indices { route(guests[index].tick(at: now), from: index) }
        finishClosing()
    }

    /// Tells each side of a dropped connection, once what's still on its way to it has arrived.
    private func finishClosing() {
        for link in orderedLinks where !link.isOpen {
            if !link.relayKnows && link.toRelay.isEmpty {
                link.relayKnows = true
                route(record(.closed, link.id, relay.closed(link.id, at: now)))
            }
            if !link.peerKnows && link.toPeer.isEmpty {
                link.peerKnows = true
                catchingUp[link.id] = nil
                switch link.end {
                case .host where currentHost == link.id:
                    currentHost = nil
                    route(host.disconnected())
                case .guest(let index) where currentGuest[index] == link.id:
                    currentGuest[index] = nil
                    route(guests[index].disconnected(), from: index)
                default:
                    break
                }
            }
            if link.relayKnows && link.peerKnows { links[link.id] = nil }
        }
    }

    // MARK: Effects

    private func route(_ effects: [RelayCore.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let id, let bytes):
                guard let link = links[id], link.isOpen else { continue }
                link.toPeer.append(bytes)
            case .close(let id):
                guard let link = links[id], !link.relayKnows else { continue }
                trace.append("t\(Int(now.timeIntervalSinceReferenceDate)) relay closes L\(id) \(link.end)")
                if link.end == .host { counts.hostDropped += 1 } else { counts.laggingGuestsDropped += 1 }
                // Closed by the relay: nothing more reaches it, and the other side hears the rest, then the close.
                link.isOpen = false
                link.relayKnows = true
                link.toRelay = []
            }
        }
    }

    private func route(_ effects: [RelayHostCore.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let bytes):
                guard let id = currentHost, let link = links[id], link.isOpen else { continue }
                link.toRelay.append(bytes)
            case .apply(let ops):
                _ = hostModel.apply(ops)
            case .shared(let welcome):
                guests = (0..<guestCount + viewers).map { index in
                    let isViewer = index >= guestCount
                    return RelayGuestCore(room: welcome.room, secret: isViewer ? welcome.viewSecret : welcome.guestSecret,
                                          key: host.key, name: "Guest \(index)", canEdit: !isViewer)
                }
                shown = Array(repeating: Replica(), count: guests.count)
                made = Array(repeating: 0, count: guests.count)
                settled = Array(repeating: [], count: guests.count)
                waiting = Set(guests.indices)
            case .reconnect:
                if let id = currentHost, let link = links[id] {
                    link.isOpen = false
                    link.peerKnows = true
                    link.toPeer = []
                }
                currentHost = nil
                hostWaiting = true
            case .ended(let reason):
                problems.append("host ended: \(reason)")
            }
        }
    }

    private func route(_ effects: [RelayGuestCore.Effect], from index: Int) {
        for effect in effects {
            switch effect {
            case .send(let bytes):
                guard let id = currentGuest[index], let link = links[id], link.isOpen else { continue }
                link.toRelay.append(bytes)
            case .show(let replica):
                shown[index] = replica
            case .reconnect:
                trace.append("t\(Int(now.timeIntervalSinceReferenceDate)) g\(index) resyncs/reconnects (at \(guests[index].seq))")
                if let id = currentGuest[index], let link = links[id] {
                    link.isOpen = false
                    link.peerKnows = true
                    link.toPeer = []
                    catchingUp[id] = nil
                }
                currentGuest[index] = nil
                waiting.insert(index)
            case .welcomed, .refused:
                break
            case .ended(let reason):
                problems.append("guest \(index) ended: \(reason)")
            }
        }
    }

    // MARK: Checks

    /// Always: each guest's copy is the host's document as of the decision it's up to, with its digest; what it shows
    /// is that with its pending changes on top; and the host's open model is its core's document.
    func checkInvariant() throws {
        #expect(problems.isEmpty, "\(problems)")
        #expect(hostModel == host.document.replica, "the host's model isn't its core's document")
        #expect(host.document.digest == Digest(host.document.replica.entities.values))
        for (index, guest) in guests.enumerated() where guest.hasCopy {
            let expected = try #require(history[guest.seq], "guest \(index) at unknown decision \(guest.seq)")
            #expect(guest.confirmed.replica == expected, "guest \(index) at decision \(guest.seq)")
            #expect(guest.confirmed.digest == Digest(expected.entities.values))
            if guest.state == .connected { #expect(shown[index] == guest.shown, "guest \(index) shows something else") }
        }
    }

    /// Delivers everything on its way, as long as there's anything.
    func deliverAll() {
        while let link = orderedLinks.first(where: { (!$0.toRelay.isEmpty && !$0.relayKnows) || (!$0.toPeer.isEmpty && !$0.peerKnows) }) {
            if !link.toRelay.isEmpty && !link.relayKnows {
                route(relayReceived(link.toRelay.removeFirst(), on: link.id))
            } else {
                deliver(link)
            }
            finishClosing()
        }
        finishClosing()
    }

    /// Lets the network settle: everyone reconnects, everything on its way arrives, and pings check nothing's missing.
    func settle() {
        for _ in 0..<200 {
            if hostWaiting { connectHost() }
            for index in waiting.sorted() { connect(index) }
            deliverAll()
            let isQuiet = !hostWaiting && waiting.isEmpty && host.state == .connected
                && guests.allSatisfy { $0.state == .connected && $0.pending.isEmpty && $0.hasCopy && $0.seq == host.seq }
            advanceTime(by: RelayGuestCore.pingInterval)
            deliverAll()
            if isQuiet && !hostWaiting && waiting.isEmpty { return }
        }
    }

    var isSettled: Bool {
        guests.allSatisfy { $0.state == .connected && $0.pending.isEmpty && $0.seq == host.seq }
    }

    func checkSettled() throws {
        try checkInvariant()
        #expect(following == host.document.replica)
        for (index, guest) in guests.enumerated() {
            #expect(guest.state == .connected, "guest \(index) is \(guest.state)")
            #expect(guest.pending.isEmpty, "guest \(index) still has \(guest.pending.count) to send")
            #expect(guest.seq == host.seq, "guest \(index) at \(guest.seq), host at \(host.seq)")
            #expect(guest.confirmed.replica == host.document.replica, "guest \(index)'s copy isn't the host's")
            #expect(shown[index] == host.document.replica, "guest \(index) shows something else")
            // Every change it made, decided once: made or turned down, none lost, none twice.
            #expect(settled[index].sorted() == (0..<UInt64(made[index])).map { $0 + 1 }, "guest \(index): made \(made[index]), decided \(settled[index].sorted())")
        }
    }
}

/// Edits a simulated person makes.
enum Simulation {
    static func randomEdit(_ model: inout DataModel, _ random: inout some RandomNumberGenerator) {
        guard let table = model.tables.randomElement(using: &random) else { _ = model.addTable(at: .zero); return }
        let column = table.columns.randomElement(using: &random)
        let other = model.tables.randomElement(using: &random)!
        let index = model.tables.firstIndex { $0.id == table.id }!
        switch Int.random(in: 0..<12, using: &random) {
        case 0: model.tables[index].name += "x"
        case 1: _ = model.addColumn(to: table.id, after: column?.id)
        case 2: if let column { model.removeColumn(column.id) }
        case 3: if model.tables.count > 3 { model.removeTable(table.id) }
        case 4: model.move(tables: [table.id], ties: [], by: CGPoint(x: 13, y: -7))
        case 5: if let column, let target = other.columns.first { _ = model.connect(column.id, to: target.id) }
        case 6: if let wire = model.relationships.randomElement(using: &random) { model.removeRelationships { $0.id == wire.id } }
        case 7: if let column { model.moveColumn(column.id, in: table.id, to: 0) }
        case 8: _ = model.group([table.id, other.id])
        case 9: _ = model.addTable(at: CGPoint(x: 700, y: 700))
        case 10: model.tables[index].color = .allCases.randomElement(using: &random)!
        default: if let column { model.tables[index].setSample(0, column.id, to: "v") }
        }
    }
}
