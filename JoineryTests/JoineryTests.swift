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

    @Test func strokeAcrossOneWireTiesNothing() {
        var schema = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(schema: schema))
        #expect(schema.zipTie(simulation, from: CGPoint(x: 374, y: -200), to: CGPoint(x: 374, y: 10)) == nil)
        #expect(schema.zipTies.isEmpty)
    }

    @Test func deletingAWireCutsATieLeftHoldingOne() throws {
        var schema = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(schema: schema))
        let tie = schema.zipTie(simulation, from: CGPoint(x: 374, y: -200), to: CGPoint(x: 374, y: 300))
        try #require(tie != nil)

        schema.removeTable(schema.tables[2].id)

        #expect(schema.zipTies.isEmpty)
        #expect(schema.relationships.count == 1)
        #expect(schema.relationships[0].zipTies.isEmpty)
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
