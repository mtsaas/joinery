import CoreGraphics
import Foundation
import Testing
@testable import Joinery

/// The session protocol, run as a simulation: a real `HostCore` and real `ClientCore`s, with a network between them
/// that delivers in any order across connections (each in order, as TCP does), cuts connections partway, and, beyond
/// what TCP would ever do, loses, repeats, swaps and garbles messages, while everyone edits at random. After every step,
/// every client's confirmed copy must be the host's document exactly as it was at some change; at the end, with the
/// network let settle, every copy must be the host's, and every change made by every client must have been taken, made
/// or turned down, exactly once.
@MainActor
struct SessionSimulation {
    @Test(arguments: 1...120 as ClosedRange<UInt64>)
    func everyCopyComesBackToTheHosts(seed: UInt64) throws {
        let simulation = try Simulation(seed: seed, clients: 3)
        for _ in 0..<250 { simulation.step(); try simulation.checkInvariant() }
        simulation.settle()
        try simulation.checkSettled()
    }

    /// The same without the faults TCP rules out: nothing lost, repeated or garbled except by cutting a connection.
    @Test(arguments: 1...60 as ClosedRange<UInt64>)
    func everyCopyComesBackWithOnlyDroppedConnections(seed: UInt64) throws {
        let simulation = try Simulation(seed: seed &+ 10_000, clients: 4, faults: false)
        for _ in 0..<300 { simulation.step(); try simulation.checkInvariant() }
        simulation.settle()
        try simulation.checkSettled()
    }
}

extension SessionSimulation {
    /// Found by the simulation: a change turned down, with the answer lost on its way, was waited for forever, as
    /// nothing else that comes after it says it's missing. The next ping finds it taken, and the client starts afresh.
    @Test func aChangeWhoseAnswerIsLostIsntWaitedForForever() throws {
        let example = try #require(Bundle.main.urls(forResourcesWithExtension: "joinery", subdirectory: nil)?.first { $0.lastPathComponent == "Storefront.joinery" })
        let document = Simulation.Document(Replica(try DataModel(contentsOf: example)))
        let host = HostCore(document: document, token: "t", name: "Host")
        let client = ClientCore(token: "t", name: "Guest")
        var now = Date(timeIntervalSinceReferenceDate: 0)
        func sent(_ effects: [ClientCore.Effect]) -> [String] { effects.compactMap { if case .send(let m) = $0 { m.text } else { nil } } }
        func sent(_ effects: [HostCore.Effect]) -> [String] { effects.compactMap { if case .send(_, let m) = $0 { m.text } else { nil } } }
        func join(on link: Int) {
            host.opened(link, at: now)
            for text in sent(host.received(sent(client.connected(at: now))[0], on: link, at: now)) {
                for resent in sent(client.received(text, at: now)) { _ = host.received(resent, on: link, at: now) }
            }
        }
        join(on: 1)
        #expect(client.state == .connected)
        // A change the host turns down; its answer never arrives.
        let doomed = sent(client.changedHere([.set(id: UUID().uuidString, field: "name", value: .string("x"))]))
        #expect(sent(host.received(doomed[0], on: 1, at: now)).first.flatMap(Message.init(text:))?.type == "reject")
        #expect(client.pending.count == 1)
        // The next ping finds it taken, with no answer still to come: start afresh, and it's gone.
        now += ClientCore.pingInterval
        let pong = sent(host.received(sent(client.tick(at: now))[0], on: 1, at: now))
        guard case .reconnect? = client.received(pong[0], at: now).first else { Issue.record("waited forever"); return }
        _ = host.closed(1)
        join(on: 2)
        #expect(client.pending.isEmpty && client.state == .connected && client.confirmed.replica == document.replica)
    }

    /// Joining a host that can't be reached gives up, saying so, after a few tries, sooner at first.
    @Test func joiningGivesUpOnAHostThatIsntThere() {
        let client = ClientCore(token: "t", name: "Guest")
        var delays: [TimeInterval] = []
        for _ in 0..<3 {
            _ = client.connected(at: .now)
            if case .reconnect(let delay)? = client.disconnected().first { delays.append(delay) }
        }
        #expect(delays == [0.25, 0.5, 1] && client.state == .connecting)
        _ = client.connected(at: .now)
        guard case .ended(let reason)? = client.disconnected().first else { Issue.record("didn't give up"); return }
        #expect(reason.hasPrefix("Couldn't join") && client.state == .ended)
    }

    /// Once joined, it keeps trying, backing off to ten seconds, and starts over once back in.
    @Test func aJoinedClientKeepsReconnecting() throws {
        let client = ClientCore(token: "t", name: "Guest")
        _ = client.connected(at: .now)
        var welcome = Message("welcome")
        welcome.you = "p"
        welcome.seq = 0
        welcome.entities = []
        welcome.hash = Digest().description
        _ = client.received(welcome.text, at: .now)
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            if case .reconnect(let delay)? = client.disconnected().first { delays.append(delay) }
        }
        #expect(delays == [0.25, 0.5, 1, 2, 4, 8, 10, 10] && client.state == .reconnecting)
    }
}

@MainActor
fileprivate final class Simulation {
    final class Document: SharedDocument {
        let title = "Simulated"
        var replica: Replica
        init(_ replica: Replica) { self.replica = replica }
        func receive(_ ops: [Replica.Op]) throws -> [Replica.Op] { try replica.receive(ops) }
    }

    final class Link {
        let id: Int, client: Int
        var toHost: [String] = [], toClient: [String] = []
        /// Each side, once it's been told the connection's gone.
        var isOpen = true, hostKnows = false, clientKnows = false
        init(id: Int, client: Int) { self.id = id; self.client = client }
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
    let document: Document
    let host: HostCore
    var clients: [ClientCore]
    /// What each client shows.
    var shown: [Replica]
    var links: [Int: Link] = [:]
    var current: [Int: Int] = [:]
    var waiting: Set<Int> = []
    var nextLink = 1
    var now = Date(timeIntervalSinceReferenceDate: 0)
    /// The host's document after each numbered change, followed from what it publishes.
    var history: [Int: Replica]
    var following: Replica
    /// Each client's changes made, and those the host has taken (made or turned down), by number.
    var made: [Int]
    var settled: [[Int]]
    var problems: [String] = []

    init(seed: UInt64, clients count: Int, faults: Bool = true) throws {
        random = Seeded(state: seed)
        self.faults = faults
        let example = try #require(Bundle.main.urls(forResourcesWithExtension: "joinery", subdirectory: nil)?.first { $0.lastPathComponent == "Storefront.joinery" })
        let start = Replica(try DataModel(contentsOf: example))
        document = Document(start)
        host = HostCore(document: document, token: "t", name: "Host")
        clients = (0..<count).map { _ in ClientCore(token: "t", name: "Guest") }
        shown = Array(repeating: Replica(), count: count)
        history = [0: start]
        following = start
        made = Array(repeating: 0, count: count)
        settled = Array(repeating: [], count: count)
        waiting = Set(0..<count)
        host.onPublish = { [unowned self] message in
            _ = self.following.apply(message.ops ?? [])
            self.history[message.seq ?? -1] = self.following
            if let author = message.author, let cseq = message.cseq, let client = self.clients.firstIndex(where: { $0.you == author }) {
                self.settled[client].append(cseq)
            }
        }
    }

    /// In a fixed order, so a seed always plays out the same: a dictionary's order changes from run to run.
    var orderedLinks: [Link] { links.keys.sorted().map { links[$0]! } }

    // MARK: Steps

    func step() {
        let roll = Int.random(in: 0..<100, using: &random)
        switch roll {
        case 0..<28: deliverToHost()
        case 28..<56: deliverToClient()
        case 56..<68: clientEdits()
        case 68..<73: hostEdits()
        case 73..<79: connectOne()
        case 79..<83: cut()
        case 83..<90: advanceTime(by: .random(in: 1...12, using: &random))
        case 90..<93: share()
        default:
            if faults { fault() } else { deliverToClient() }
        }
        finishClosing()
    }

    private func deliverToHost() {
        guard let link = orderedLinks.filter({ !$0.toHost.isEmpty && !$0.hostKnows }).randomElement(using: &random) else { return }
        let text = link.toHost.removeFirst()
        route(host.received(text, on: link.id, at: now))
    }

    private func deliverToClient() {
        guard let link = orderedLinks.filter({ !$0.toClient.isEmpty && !$0.clientKnows }).randomElement(using: &random) else { return }
        let text = link.toClient.removeFirst()
        route(clients[link.client].received(text, at: now), from: link.client)
    }

    private func clientEdits() {
        let index = Int.random(in: 0..<clients.count, using: &random)
        let client = clients[index]
        // Only once it's been let in, with something to show: before, the model isn't open.
        guard client.you != nil, client.state != .ended else { return }
        let before = shown[index]
        let model = before.model
        var edited = model
        Self.randomEdit(&edited, &random)
        let ops = before.ops(to: Replica(edited, keeping: before, was: model))
        guard !ops.isEmpty else { return }
        // As the app does: shown at once, then handed on.
        _ = shown[index].apply(ops)
        made[index] += 1
        route(client.changedHere(ops), from: index)
    }

    private func hostEdits() {
        let model = document.replica.model
        var edited = model
        Self.randomEdit(&edited, &random)
        let ops = document.replica.ops(to: Replica(edited, keeping: document.replica, was: model))
        guard !ops.isEmpty else { return }
        _ = document.replica.apply(ops)
        route(host.changedHere(ops))
    }

    private func connectOne() {
        guard let index = waiting.sorted().randomElement(using: &random) else { return }
        connect(index)
    }

    private func connect(_ index: Int) {
        waiting.remove(index)
        let link = Link(id: nextLink, client: index)
        nextLink += 1
        links[link.id] = link
        current[index] = link.id
        host.opened(link.id, at: now)
        route(clients[index].connected(at: now), from: index)
    }

    /// The network drops a connection: each way, some of what was on its way still arrives, the rest never does.
    private func cut() {
        // Joining for the first time gives up after a few failures, which is tested on its own; here, it's joined first.
        guard let link = orderedLinks.filter({ $0.isOpen && clients[$0.client].you != nil }).randomElement(using: &random) else { return }
        link.isOpen = false
        link.toHost = Array(link.toHost.prefix(Int.random(in: 0...link.toHost.count, using: &random)))
        link.toClient = Array(link.toClient.prefix(Int.random(in: 0...link.toClient.count, using: &random)))
    }

    /// What TCP never does: a message lost, repeated, swapped with the next, or garbled, on a connection that stays up.
    private func fault() {
        guard let link = orderedLinks.filter({ $0.isOpen && clients[$0.client].you != nil && (!$0.toHost.isEmpty || !$0.toClient.isEmpty) })
            .randomElement(using: &random) else { return }
        let toHost = !link.toHost.isEmpty && (link.toClient.isEmpty || Bool.random(using: &random))
        var queue = toHost ? link.toHost : link.toClient
        let index = Int.random(in: 0..<queue.count, using: &random)
        switch Int.random(in: 0..<4, using: &random) {
        case 0: queue.remove(at: index)
        case 1: queue.insert(queue[index], at: index)
        case 2: if index + 1 < queue.count { queue.swapAt(index, index + 1) }
        default: queue[index] = String(queue[index].dropLast(3))
        }
        if toHost { link.toHost = queue } else { link.toClient = queue }
    }

    private func share() {
        let index = Int.random(in: 0..<clients.count, using: &random)
        route(clients[index].share(cursor: CGPoint(x: 1, y: 2), selection: []), from: index)
    }

    private func advanceTime(by seconds: TimeInterval) {
        now += seconds
        route(host.tick(at: now))
        for index in clients.indices { route(clients[index].tick(at: now), from: index) }
    }

    /// Tells each side of a dropped connection, once what's still on its way to it has arrived.
    private func finishClosing() {
        for link in orderedLinks where !link.isOpen {
            if !link.hostKnows && link.toHost.isEmpty {
                link.hostKnows = true
                route(host.closed(link.id))
            }
            if !link.clientKnows && link.toClient.isEmpty {
                link.clientKnows = true
                if current[link.client] == link.id {
                    current[link.client] = nil
                    route(clients[link.client].disconnected(), from: link.client)
                }
            }
            if link.hostKnows && link.clientKnows { links[link.id] = nil }
        }
    }

    // MARK: Effects

    private func route(_ effects: [HostCore.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let id, let message):
                guard let link = links[id] else { continue }
                // Turned down is taken, whether or not the client hears so.
                if message.type == "reject", let cseq = message.cseq { settled[link.client].append(cseq) }
                guard link.isOpen else { continue }
                link.toClient.append(message.text)
            case .close(let id):
                guard let link = links[id], !link.hostKnows else { continue }
                // Closed by the host: nothing more reaches it, and the client hears the rest, then the close.
                link.isOpen = false
                link.hostKnows = true
                link.toHost = []
                route(host.closed(id))
            }
        }
    }

    private func route(_ effects: [ClientCore.Effect], from index: Int) {
        for effect in effects {
            switch effect {
            case .send(let message):
                guard let id = current[index], let link = links[id], link.isOpen else { continue }
                link.toHost.append(message.text)
            case .show(let replica):
                shown[index] = replica
            case .reconnect:
                // Dropped by the client: it hears nothing more on it, and the host hears what was sent, then the close.
                if let id = current[index], let link = links[id] {
                    link.isOpen = false
                    link.clientKnows = true
                    link.toClient = []
                }
                current[index] = nil
                waiting.insert(index)
            case .welcomed, .refused:
                break
            case .ended(let reason):
                problems.append("client \(index) ended: \(reason)")
            }
        }
    }

    // MARK: Checks

    /// Always: each client's confirmed copy is the host's document as of the change it's up to, with its digest; what
    /// it shows is that with its pending changes on top; and the host's copy of what it's sent is its document.
    func checkInvariant() throws {
        #expect(problems.isEmpty, "\(problems)")
        #expect(host.sent.replica == document.replica)
        #expect(host.sent.digest == Digest(document.replica.entities.values))
        for (index, client) in clients.enumerated() where client.you != nil {
            let expected = try #require(history[client.seq], "client \(index) at unknown change \(client.seq)")
            #expect(client.confirmed.replica == expected, "client \(index) at change \(client.seq)")
            #expect(client.confirmed.digest == Digest(expected.entities.values))
            if client.state == .connected { #expect(shown[index] == client.shown, "client \(index) shows something else") }
        }
    }

    /// Lets the network settle: everyone reconnects, everything on its way arrives, and pings check nothing's missing.
    func settle() {
        for _ in 0..<200 {
            for index in waiting.sorted() { connect(index) }
            while let link = orderedLinks.first(where: { (!$0.toHost.isEmpty && !$0.hostKnows) || (!$0.toClient.isEmpty && !$0.clientKnows) }) {
                if !link.toHost.isEmpty && !link.hostKnows {
                    route(host.received(link.toHost.removeFirst(), on: link.id, at: now))
                } else {
                    route(clients[link.client].received(link.toClient.removeFirst(), at: now), from: link.client)
                }
                finishClosing()
            }
            finishClosing()
            let isQuiet = waiting.isEmpty && clients.allSatisfy { $0.state == .connected && $0.pending.isEmpty && $0.seq == host.seq }
            // Past the ping interval, so each client checks with the host, but well inside the host's timeout.
            if isQuiet && now.timeIntervalSinceReferenceDate > 0 { advanceTime(by: ClientCore.pingInterval); if waiting.isEmpty && links.values.allSatisfy({ $0.toHost.isEmpty && $0.toClient.isEmpty }) { return } }
            advanceTime(by: ClientCore.pingInterval)
        }
    }

    func checkSettled() throws {
        try checkInvariant()
        #expect(following == document.replica)
        for (index, client) in clients.enumerated() {
            #expect(client.state == .connected, "client \(index) is \(client.state)")
            #expect(client.pending.isEmpty, "client \(index) still has \(client.pending.count) to send")
            #expect(client.seq == host.seq)
            #expect(client.confirmed.replica == document.replica, "client \(index)'s copy isn't the host's")
            #expect(shown[index] == document.replica, "client \(index) shows something else")
            // Every change it made, taken once: made or turned down, none lost, none twice.
            #expect(settled[index].sorted() == Array(1...max(made[index], 1)).prefix(made[index]).map { $0 }, "client \(index): made \(made[index]), settled \(settled[index].sorted())")
        }
    }

    // MARK: Edits

    static func randomEdit(_ model: inout DataModel, _ random: inout Seeded) {
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
