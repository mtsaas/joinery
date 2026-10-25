import CoreGraphics
import Testing
@testable import Joinery

@MainActor
struct JoineryTests {
    /// `users` on the left; `orders` and `reviews` to its right, each with a `user_id` referencing it.
    private func storefront() -> Schema {
        var schema = Schema()
        for (name, position, color) in [("users", CGPoint(x: 0, y: 0), TableColor.blue),
                                        ("orders", CGPoint(x: 500, y: -100), .orange),
                                        ("reviews", CGPoint(x: 500, y: 200), .pink)] {
            let id = schema.addTable(at: position)
            let index = schema.tables.firstIndex { $0.id == id }!
            schema.tables[index].name = name
            schema.tables[index].color = color
            if name != "users" { schema.tables[index].columns.append(Column(name: "user_id", type: .uuid)) }
        }
        let usersID = schema.tables[0].columns[0].id
        schema.connect(schema.tables[1].columns[1].id, to: usersID)
        schema.connect(schema.tables[2].columns[1].id, to: usersID)
        return schema
    }

    /// Runs the simulation until it stops, or for `limit` seconds.
    /// - Returns: How long that took.
    private func settle(_ simulation: WireSimulation, on routing: Routing, limit: Double = 10) -> Double {
        var time = 0.0
        while simulation.advance(toward: routing.routes, to: time), time < limit { time += 1.0 / 60 }
        return time
    }

    @Test func wiresSpringBackOntoTheirRoutes() {
        var schema = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(schema: schema))

        schema.tables[1].position.y += 120
        let routing = Routing(schema: schema)
        let time = settle(simulation, on: routing)

        #expect(time > 0.2, "should visibly swing, not snap")
        #expect(time < 5)
        for (id, route) in routing.routes { #expect(simulation.wires[id]?.points == route.points) }
    }

    @Test func zipTieHoldsCrossedWiresSideBySide() throws {
        var schema = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(schema: schema))

        let tied = schema.zipTie(simulation, from: CGPoint(x: 374, y: -200), to: CGPoint(x: 374, y: 300))
        let tieID = try #require(tied)
        #expect(schema.relationships.allSatisfy { $0.zipTies == [tieID] })

        let routing = Routing(schema: schema)
        let slots = schema.relationships.map { routing.routes[$0.id]!.points[Routing.samplesPerSegment] }
        #expect(abs(slots[0].distance(to: slots[1]) - Metrics.tieSpacing) < 0.001)
        // `orders` is above `reviews`, so its wire takes the upper slot.
        #expect(slots[0].y < slots[1].y)
    }

    /// Tying close to a socket the wires share once made them whip into a knot while settling.
    @Test func tyingNearASocketNeverFoldsAWire() throws {
        var schema = storefront()
        let simulation = WireSimulation()
        var time = settle(simulation, on: Routing(schema: schema))
        let socket = Metrics.socket(row: 0, side: .trailing, in: Metrics.frame(of: schema.tables[0]))
        let x = socket.x + 28
        let tied = schema.zipTie(simulation, from: CGPoint(x: x, y: -200), to: CGPoint(x: x, y: 300))
        try #require(tied != nil)

        let routes = Routing(schema: schema).routes
        var sharpest = 0.0
        repeat {
            time += 1.0 / 60
            for wire in simulation.wires.values {
                for (a, b, c) in zip(zip(wire.points, wire.points.dropFirst()), wire.points.dropFirst(2)).map({ ($0.0, $0.1, $1) }) {
                    guard let u = (b - a).normalized, let v = (c - b).normalized else { continue }
                    sharpest = max(sharpest, Double(acos(min(1, max(-1, u.dot(v))))) * 180 / .pi)
                }
            }
        } while simulation.advance(toward: routes, to: time)

        #expect(sharpest < 45, "a wire bent \(Int(sharpest))° while settling")
    }

    @Test func wiresCanBendAroundTablesInTheirWay() throws {
        var schema = storefront()
        // A table squarely across the wire from orders to users, with room around it.
        schema.tables[1].position.x = 700
        let blockerID = schema.addTable(at: CGPoint(x: 350, y: -60))
        let blocker = try #require(schema.table(blockerID))
        schema.tables[schema.tables.count - 1].columns += (1...4).map { Column(name: "c\($0)", type: .text) }
        let wire = schema.relationships[0].id
        let frame = Metrics.frame(of: try #require(schema.table(blocker.id)))

        let straight = try #require(Routing(schema: schema).routes[wire])
        #expect(straight.points.contains { frame.contains($0) }, "the setup should put the table in the wire's way")

        let avoiding = try #require(Routing(schema: schema, avoidingTables: true).routes[wire])
        #expect(!avoiding.points.contains { frame.contains($0) })
        #expect(avoiding.points.first == straight.points.first)
        #expect(avoiding.points.last == straight.points.last)
    }

    @Test func strokeAcrossOneWireTiesNothing() {
        var schema = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(schema: schema))
        #expect(schema.zipTie(simulation, from: CGPoint(x: 374, y: -200), to: CGPoint(x: 374, y: 10)) == nil)
        #expect(schema.zipTies.isEmpty)
    }

    @Test func deletingAWireLeavesTheOtherBentThroughTheTie() throws {
        var schema = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(schema: schema))
        let tie = schema.zipTie(simulation, from: CGPoint(x: 374, y: -200), to: CGPoint(x: 374, y: 300))
        let tieID = try #require(tie)

        schema.removeTable(schema.tables[2].id)

        #expect(schema.zipTies.map(\.relationships.count) == [1])
        #expect(schema.relationships.count == 1)
        #expect(schema.relationships[0].zipTies == [tieID])
    }

    @Test func bendPointRoutesItsWireThroughIt() throws {
        var schema = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(schema: schema))
        let wire = schema.relationships[0].id
        let bend = schema.addBendPoint(on: wire, at: CGPoint(x: 360, y: 120), direction: CGPoint(x: 1, y: 0), segment: 0)
        let bendID = try #require(bend)

        let routing = Routing(schema: schema)
        let route = try #require(routing.routes[wire]), direction = try #require(routing.ties[bendID]?.direction)
        let n = Routing.samplesPerSegment
        #expect(route.points[n] == CGPoint(x: 360, y: 120))
        // Passes through square to the bend point: along its direction on both sides.
        for way in [route.points[n] - route.points[n - 1], route.points[n + 1] - route.points[n]] {
            #expect(abs(try #require(way.normalized).dot(direction)) > 0.99)
        }

        schema.removeZipTie(bendID)
        #expect(schema.relationships[0].zipTies.isEmpty)
    }

    @Test(arguments: [("int", DataType.integer, false), ("text?", .text, true), ("ts", .timestamp, false),
                      ("TIMESTAMPTZ", .timestamp, false), ("bool?", .boolean, true), ("var", .varchar, false),
                      ("jsonb", .json, false), ("u", .uuid, false)])
    func typingATypeReadsIt(input: String, type: DataType, isNullable: Bool) throws {
        let parsed = try #require(DataType.parse(input))
        #expect(parsed.type == type)
        #expect(parsed.isNullable == isNullable)
    }

    @Test func paletteMatchesLettersInOrderAndRanksWordStarts() throws {
        #expect(PaletteCommand.score("nt", in: "New Table") != nil)
        #expect(PaletteCommand.score("tn", in: "New Table") == nil)
        let titles = ["New Table", "Zoom In", "orders", "order_items", "Wires Avoid Tables"]
        let ranked = titles.compactMap { title in PaletteCommand.score("ord", in: title).map { (title, $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
        #expect(ranked.prefix(2).sorted() == ["order_items", "orders"])
        let tables = try #require(PaletteCommand.score("nt", in: "New Table"))
        // Both match, but "New Table" has both letters starting words.
        let rename = try #require(PaletteCommand.score("nt", in: "Rename Table"))
        #expect(tables > rename)
    }

    @Test func droppingOnATableAddsAColumnForTheForeignKey() throws {
        var schema = storefront()
        let users = schema.tables[0], orders = schema.tables[1]
        let connected = schema.connect(dragging: users.columns[0].id, onto: .table(orders.id))
        let id = try #require(connected)

        let added = try #require(schema.table(orders.id)?.columns.last)
        #expect(added.name == "user_id_2", "orders already has a user_id")
        #expect(added.type == .uuid)
        let relationship = try #require(schema.relationships.first { $0.id == id })
        #expect(relationship.from == added.id)
        #expect(relationship.to == users.columns[0].id)
    }

    @Test func aForeignKeyPointsAtThePrimaryKeyWhicheverWayItsDragged() throws {
        var schema = storefront()
        schema.relationships = []
        let usersID = schema.tables[0].columns[0].id, userID = schema.tables[1].columns[1].id
        let connected = schema.connect(dragging: usersID, onto: .column(userID))
        let id = try #require(connected)
        let relationship = try #require(schema.relationships.first { $0.id == id })
        #expect(relationship.from == userID)
        #expect(relationship.to == usersID)
    }

    @Test(arguments: [("users", "user"), ("categories", "category"), ("addresses", "address"), ("statuses", "status"),
                      ("boxes", "box"), ("batches", "batch"), ("order_items", "order_item"), ("access", "access")])
    func tableNamesMadeSingular(plural: String, singular: String) {
        #expect(Schema.singular(plural) == singular)
    }

    @Test func aligningAndDistributingTables() throws {
        var schema = Schema()
        let ids = [CGPoint(x: 0, y: 10), CGPoint(x: 400, y: 90), CGPoint(x: 1000, y: 40)].map { schema.addTable(at: $0) }
        schema.align(Set(ids), .top)
        #expect(schema.tables.allSatisfy { $0.position.y == 10 })

        schema.distribute(Set(ids), horizontally: true)
        let xs = schema.tables.map(\.position.x)
        #expect(xs[0] == 0 && xs[2] == 1000, "the outermost stay put")
        #expect(abs((xs[1] - xs[0]) - (xs[2] - xs[1])) < 0.001)

        schema.align(Set(ids), .right)
        #expect(schema.tables.allSatisfy { $0.position.x == 1000 })
    }

    @Test func typingNonsenseKeepsNothing() {
        #expect(DataType.parse("zzz") == nil)
        #expect(DataType.parse("?") == nil)
    }

    @Test func repairDropsDanglingReferences() {
        var schema = storefront()
        let tie = ZipTie(position: .zero, direction: CGPoint(x: 0, y: 3), relationships: schema.relationships.map(\.id))
        schema.zipTies.append(tie)
        schema.relationships[0].zipTies = [tie.id, tie.id]
        schema.relationships[1].zipTies = [tie.id]
        schema.relationships.append(Relationship(from: .init(), to: schema.tables[0].columns[0].id))

        schema.repair()

        #expect(schema.relationships.count == 2)
        #expect(schema.relationships.allSatisfy { $0.zipTies == [tie.id] })
        #expect(schema.zipTies.first?.direction == CGPoint(x: 0, y: 1))
    }

    @Test func crossingFindsWhereSegmentsMeet() {
        #expect(crossing(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 5, y: -5), CGPoint(x: 5, y: 5)) == 0.5)
        #expect(crossing(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 11, y: -5), CGPoint(x: 11, y: 5)) == nil)
    }
}
