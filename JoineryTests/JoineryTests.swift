import CryptoKit
import CoreGraphics
import Foundation
import struct SwiftUI.Binding
import Testing
@testable import Joinery

@MainActor
struct JoineryTests {
    /// `users` on the left; `orders` and `reviews` to its right, each with a `user_id` referencing it.
    private func storefront() -> DataModel {
        var model = DataModel()
        for (name, position, color) in [("users", CGPoint(x: 0, y: 0), TableColor.blue),
                                        ("orders", CGPoint(x: 500, y: -100), .orange),
                                        ("reviews", CGPoint(x: 500, y: 200), .pink)] {
            let id = model.addTable(at: position)
            let index = model.tables.firstIndex { $0.id == id }!
            model.tables[index].name = name
            model.tables[index].color = color
            if name != "users" { model.tables[index].columns.append(Column(name: "user_id", type: .uuid)) }
        }
        let usersID = model.tables[0].columns[0].id
        model.connect(model.tables[1].columns[1].id, to: usersID)
        model.connect(model.tables[2].columns[1].id, to: usersID)
        return model
    }

    /// Runs the simulation until it stops, or for `limit` seconds.
    /// - Returns: How long that took.
    private func settle(_ simulation: WireSimulation, on routing: Routing, limit: Double = 10) -> Double {
        var time = 0.0
        while simulation.advance(toward: routing.routes, to: time), time < limit { time += 1.0 / 60 }
        return time
    }

    @Test func wiresSpringBackOntoTheirRoutes() {
        var model = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(model: model))

        model.tables[1].position.y += 120
        let routing = Routing(model: model)
        let time = settle(simulation, on: routing)

        #expect(time > 0.2, "should visibly swing, not snap")
        #expect(time < 5)
        for (id, route) in routing.routes { #expect(simulation.wires[id]?.points == route.points) }
    }

    @Test func zipTieHoldsCrossedWiresSideBySide() throws {
        var model = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(model: model))

        let tied = model.zipTie(simulation, from: CGPoint(x: 374, y: -200), to: CGPoint(x: 374, y: 300))
        let tieID = try #require(tied)
        #expect(model.relationships.allSatisfy { $0.zipTies == [tieID] })

        let routing = Routing(model: model)
        let slots = model.relationships.map { routing.routes[$0.id]!.points[Routing.samplesPerSegment] }
        #expect(abs(slots[0].distance(to: slots[1]) - Metrics.tieSpacing) < 0.001)
        // `orders` is above `reviews`, so its wire takes the upper slot.
        #expect(slots[0].y < slots[1].y)
    }

    /// Tying close to a socket the wires share once made them whip into a knot while settling.
    @Test func tyingNearASocketNeverFoldsAWire() throws {
        var model = storefront()
        let simulation = WireSimulation()
        var time = settle(simulation, on: Routing(model: model))
        let socket = Metrics.socket(row: 0, side: .trailing, in: Metrics.frame(of: model.tables[0]))
        let x = socket.x + 28
        let tied = model.zipTie(simulation, from: CGPoint(x: x, y: -200), to: CGPoint(x: x, y: 300))
        try #require(tied != nil)

        let routes = Routing(model: model).routes
        var sharpest = 0.0
        repeat {
            time += 1.0 / 60
            for wire in simulation.wires.values {
                // At a scale you'd see: near a socket the samples are a point or two apart, where sub-pixel jiggle reads
                // as a large angle. The wire is walked in steps of at least 4 points.
                var visible = [wire.points[0]]
                for point in wire.points.dropFirst() where point.distance(to: visible[visible.count - 1]) >= 4 { visible.append(point) }
                for (a, b, c) in zip(zip(visible, visible.dropFirst()), visible.dropFirst(2)).map({ ($0.0, $0.1, $1) }) {
                    guard let u = (b - a).normalized, let v = (c - b).normalized else { continue }
                    sharpest = max(sharpest, Double(acos(min(1, max(-1, u.dot(v))))) * 180 / .pi)
                }
            }
        } while simulation.advance(toward: routes, to: time)

        #expect(sharpest < 45, "a wire bent \(Int(sharpest))° while settling")
    }

    @Test func wiresCanBendAroundTablesInTheirWay() throws {
        var model = storefront()
        // A table squarely across the wire from orders to users, a couple of hundred points from each socket. (Closer
        // than that, a wire can't swerve fully clear without kinking, so near a socket it may pass partly under.)
        model.tables[1].position.x = 900
        let blockerID = model.addTable(at: CGPoint(x: 450, y: -60))
        let blocker = try #require(model.table(blockerID))
        model.tables[model.tables.count - 1].columns += (1...4).map { Column(name: "c\($0)", type: .text) }
        let wire = model.relationships[0].id
        let frame = Metrics.frame(of: try #require(model.table(blocker.id)))

        let straight = try #require(Routing(model: model).routes[wire])
        #expect(straight.points.contains { frame.contains($0) }, "the setup should put the table in the wire's way")

        let avoiding = try #require(Routing(model: model, avoidingTables: true).routes[wire])
        #expect(!avoiding.points.contains { frame.contains($0) })
        #expect(avoiding.points.first == straight.points.first)
        #expect(avoiding.points.last == straight.points.last)
    }

    /// A table close to the socket a wire leaves once stayed under it there: the push fades in near sockets, so the
    /// wire was only lifted in the middle, to a peak.
    @Test func wiresWrapTablesCloseToTheirSockets() throws {
        var model = DataModel()
        let products = model.addTable(at: .zero), reviews = model.addTable(at: CGPoint(x: 370, y: -20))
        let orders = model.addTable(at: CGPoint(x: 760, y: 40))
        for (id, count) in [(products, 4), (reviews, 5), (orders, 3)] {
            let index = model.tables.firstIndex { $0.id == id }!
            model.tables[index].columns += (1...count).map { Column(name: "c\($0)", type: .uuid) }
        }
        let key = try #require(model.table(products)?.columns[0].id), foreign = try #require(model.table(orders)?.columns[2].id)
        let connected = model.connect(foreign, to: key)
        let wire = try #require(connected)
        let frame = Metrics.frame(of: try #require(model.table(reviews)))

        let straight = try #require(Routing(model: model).routes[wire])
        #expect(straight.points.contains { frame.contains($0) }, "the setup should put the table in the wire's way")
        let route = try #require(Routing(model: model, avoidingTables: true).routes[wire])
        // Clear of it all along, points and the stretches between, with room to spare.
        let clear = frame.insetBy(dx: -Routing.avoidanceClearance / 2, dy: -Routing.avoidanceClearance / 2)
        for (a, b) in zip(route.points, route.points.dropFirst()) {
            #expect(!clear.contains(a) && !clear.contains((a + b) / 2))
        }
    }

    /// Each side of a tie is its own cable: shaking one side reaches the tie, not past it.
    @Test func forcesDoNotCrossAZipTie() throws {
        var model = storefront()
        let simulation = WireSimulation()
        var time = settle(simulation, on: Routing(model: model))
        let tied = model.zipTie(simulation, from: CGPoint(x: 374, y: -200), to: CGPoint(x: 374, y: 300))
        try #require(tied != nil)
        time += settle(simulation, on: Routing(model: model))

        // Yank the stretch between the foreign key's socket and the tie; leave the tie and beyond where they are.
        var routes = Routing(model: model).routes
        let wire = model.relationships[0].id, n = Routing.samplesPerSegment
        for i in 1..<n { routes[wire]?.points[i].y += 40 }
        let rest = try #require(routes[wire]?.points)
        var moved = 0.0
        repeat {
            time += 1.0 / 60
            let points = try #require(simulation.wires[wire]?.points)
            for i in n..<points.count { moved = max(moved, Double(points[i].distance(to: rest[i]))) }
        } while simulation.advance(toward: routes, to: time)

        #expect(moved < 0.01, "the tie and the cable past it moved \(moved) pt")
    }

    @Test func strokeAcrossOneWireTiesNothing() {
        var model = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(model: model))
        #expect(model.zipTie(simulation, from: CGPoint(x: 374, y: -200), to: CGPoint(x: 374, y: 10)) == nil)
        #expect(model.zipTies.isEmpty)
    }

    @Test func deletingAWireLeavesTheOtherBentThroughTheTie() throws {
        var model = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(model: model))
        let tie = model.zipTie(simulation, from: CGPoint(x: 374, y: -200), to: CGPoint(x: 374, y: 300))
        let tieID = try #require(tie)

        model.removeTable(model.tables[2].id)

        #expect(model.zipTies.map(\.relationships.count) == [1])
        #expect(model.relationships.count == 1)
        #expect(model.relationships[0].zipTies == [tieID])
    }

    @Test func bendPointRoutesItsWireThroughIt() throws {
        var model = storefront()
        let simulation = WireSimulation()
        _ = settle(simulation, on: Routing(model: model))
        let wire = model.relationships[0].id
        let bend = model.addBendPoint(on: wire, at: CGPoint(x: 360, y: 120), direction: CGPoint(x: 1, y: 0), segment: 0)
        let bendID = try #require(bend)

        let routing = Routing(model: model)
        let route = try #require(routing.routes[wire]), direction = try #require(routing.ties[bendID]?.direction)
        let n = Routing.samplesPerSegment
        #expect(route.points[n] == CGPoint(x: 360, y: 120))
        // Passes through square to the bend point. Its tangent there is the bend point's direction exactly; the chord
        // to the next sample along curves away a little, so allow 12°.
        for way in [route.points[n] - route.points[n - 1], route.points[n + 1] - route.points[n]] {
            #expect(abs(try #require(way.normalized).dot(direction)) > cos(12 * .pi / 180))
        }

        model.removeZipTie(bendID)
        #expect(model.relationships[0].zipTies.isEmpty)
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
        var model = storefront()
        let users = model.tables[0], orders = model.tables[1]
        let connected = model.connect(dragging: users.columns[0].id, onto: .table(orders.id))
        let id = try #require(connected)

        let added = try #require(model.table(orders.id)?.columns.last)
        #expect(added.name == "user_id_2", "orders already has a user_id")
        #expect(added.type == .uuid)
        let relationship = try #require(model.relationships.first { $0.id == id })
        #expect(relationship.from == added.id)
        #expect(relationship.to == users.columns[0].id)
    }

    @Test func aForeignKeyPointsAtThePrimaryKeyWhicheverWayItsDragged() throws {
        var model = storefront()
        model.relationships = []
        let usersID = model.tables[0].columns[0].id, userID = model.tables[1].columns[1].id
        let connected = model.connect(dragging: usersID, onto: .column(userID))
        let id = try #require(connected)
        let relationship = try #require(model.relationships.first { $0.id == id })
        #expect(relationship.from == userID)
        #expect(relationship.to == usersID)
    }

    @Test(arguments: [("users", "user"), ("categories", "category"), ("addresses", "address"), ("statuses", "status"),
                      ("boxes", "box"), ("batches", "batch"), ("order_items", "order_item"), ("access", "access")])
    func tableNamesMadeSingular(plural: String, singular: String) {
        #expect(DataModel.singular(plural) == singular)
    }

    @Test func aligningAndDistributingTables() throws {
        var model = DataModel()
        let ids = [CGPoint(x: 0, y: 10), CGPoint(x: 400, y: 90), CGPoint(x: 1000, y: 40)].map { model.addTable(at: $0) }
        model.align(Set(ids), .top)
        #expect(model.tables.allSatisfy { $0.position.y == 10 })

        model.distribute(Set(ids), horizontally: true)
        let xs = model.tables.map(\.position.x)
        #expect(xs[0] == 0 && xs[2] == 1000, "the outermost stay put")
        #expect(abs((xs[1] - xs[0]) - (xs[2] - xs[1])) < 0.001)

        model.align(Set(ids), .right)
        #expect(model.tables.allSatisfy { $0.position.x == 1000 })
    }

    @Test func aligningTiesLinesThemUpAndHoldsThemSquare() throws {
        var model = storefront()
        let wires = model.relationships.map(\.id)
        let first = model.addBendPoint(on: wires[0], at: CGPoint(x: 380, y: -40), direction: CGPoint(x: 1, y: -0.3), segment: 0)
        let second = model.addBendPoint(on: wires[1], at: CGPoint(x: 410, y: 160), direction: CGPoint(x: 1, y: 0.4), segment: 0)
        let a = try #require(first), b = try #require(second)
        model.align([], ties: [a, b], .center)
        let ties = model.zipTies
        #expect(ties.allSatisfy { $0.position.x == 395 }, "on the line through the middle of them")
        #expect(ties.allSatisfy { $0.heldDirection == CGPoint(x: 1, y: 0) }, "wires run square across the line")
        // Held as tables move, rather than turning with their wires.
        model.tables[1].position.y -= 300
        let routing = Routing(model: model)
        #expect(routing.ties[a]?.direction == CGPoint(x: 1, y: 0))
    }

    @Test func boxSelectionPrefersTablesThenTiesThenWires() {
        let table = UUID(), tie = UUID(), wire = UUID()
        typealias Item = CanvasController.Item
        #expect(CanvasController.boxSelection(tables: [table], ties: [tie], wires: [wire])
            == [Item.table(table), .zipTie(tie), .relationship(wire)])
        #expect(CanvasController.boxSelection(tables: [], ties: [tie], wires: [wire]) == [Item.zipTie(tie)])
        #expect(CanvasController.boxSelection(tables: [], ties: [], wires: [wire]) == [Item.relationship(wire)])
        #expect(CanvasController.boxSelection(tables: [], ties: [], wires: []).isEmpty)
    }

    @Test func adjacentPrimaryKeyColumnsMakeOneCompoundKey() {
        func table(_ keys: [Bool]) -> Table {
            Table(name: "t", position: .zero, color: .blue,
                  columns: keys.enumerated().map { Column(name: "c\($0.offset)", type: .integer, isPrimaryKey: $0.element) })
        }
        #expect(table([true, true, false]).compoundPrimaryKeyRuns == [0...1])
        #expect(table([false, true, true, true]).compoundPrimaryKeyRuns == [1...3])
        #expect(table([true, false, true]).compoundPrimaryKeyRuns.isEmpty, "apart, each shows its own PK")
        #expect(table([true]).compoundPrimaryKeyRuns.isEmpty)
    }

    @Test func typingNonsenseKeepsNothing() {
        #expect(DataType.parse("zzz") == nil)
        #expect(DataType.parse("?") == nil)
    }

    @Test func repairDropsDanglingReferences() {
        var model = storefront()
        let tie = ZipTie(position: .zero, direction: CGPoint(x: 0, y: 3), relationships: model.relationships.map(\.id))
        model.zipTies.append(tie)
        model.relationships[0].zipTies = [tie.id, tie.id]
        model.relationships[1].zipTies = [tie.id]
        model.relationships.append(Relationship(from: .init(), to: model.tables[0].columns[0].id))

        model.repair()

        #expect(model.relationships.count == 2)
        #expect(model.relationships.allSatisfy { $0.zipTies == [tie.id] })
        #expect(model.zipTies.first?.direction == CGPoint(x: 0, y: 1))
    }

    @Test func crossingFindsWhereSegmentsMeet() {
        #expect(crossing(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 5, y: -5), CGPoint(x: 5, y: 5)) == 0.5)
        #expect(crossing(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 11, y: -5), CGPoint(x: 11, y: 5)) == nil)
    }

    @Test func gridCursorMovesLikeASpreadsheet() {
        let orders = storefront().tables[1]  // id, user_id
        let (id, userID) = (orders.columns[0].id, orders.columns[1].id)
        func cell(_ row: CanvasController.Cell.Row, _ part: Metrics.GridColumn) -> CanvasController.Cell {
            CanvasController.Cell(table: orders.id, row: row, part: part)
        }
        func after(_ from: CanvasController.Cell, _ move: CanvasController.CellMove) -> CanvasController.Cell? {
            CanvasController.cell(after: from, move, in: orders)
        }
        let header = CanvasController.Cell.name(of: orders.id)
        #expect(after(header, .down) == cell(.column(id), .name))
        #expect(after(header, .up) == header)
        #expect(after(header, .right) == header)
        #expect(after(cell(.column(id), .type), .up) == header)
        #expect(after(cell(.column(id), .type), .down) == cell(.column(userID), .type))
        #expect(after(cell(.column(userID), .type), .down) == cell(.column(userID), .type), "clamps at the bottom")
        #expect(after(cell(.column(userID), .name), .downOrNew) == nil, "past the end, a new column")
        #expect(after(cell(.column(id), .key), .left) == cell(.column(id), .key))
        #expect(after(cell(.column(id), .name), .right) == cell(.column(id), .type))
        // Tab goes along a row, then to the next row's name; Shift-Tab back, to the header at the top.
        #expect(after(header, .next) == cell(.column(id), .name))
        #expect(after(cell(.column(id), .type), .next) == cell(.column(userID), .name))
        #expect(after(cell(.column(userID), .type), .next) == nil)
        #expect(after(cell(.column(userID), .key), .previous) == cell(.column(id), .type))
        #expect(after(cell(.column(id), .key), .previous) == header)
    }

    @Test func commandWheelPicksByDirection() {
        #expect(CommandWheel.direction(of: CGPoint(x: 5, y: 3)) == nil, "the middle picks nothing")
        #expect(CommandWheel.direction(of: CGPoint(x: -80, y: 10)) == .west)
        #expect(CommandWheel.direction(of: CGPoint(x: 0, y: -30)) == .north, "y runs down")
        #expect(CommandWheel.direction(of: CGPoint(x: 40, y: 38)) == .southEast)
        #expect(CommandWheel.direction(of: CGPoint(x: 50, y: -1)) == .east)
        #expect(CommandWheel.direction(of: CGPoint(x: -50, y: -1)) == .west, "either side of ±180°")
    }

    @Test func assistantToolsBuildASchemaInOneCall() throws {
        var model = DataModel()
        let result = try ModelTools.call("create_tables", ["tables": [
            ["name": "users", "columns": [["name": "id", "type": "uuid", "primary_key": true]]],
            ["name": "posts", "columns": [["name": "id", "type": "bigserial", "primary_key": true],
                                          ["name": "author_id", "type": "UUID", "references": "users"],
                                          ["name": "price", "type": "decimal(10, 2)"],
                                          ["name": "body", "type": "text?"]]],
        ]], on: &model)
        #expect(result == "Created users, posts with 1 foreign key.")
        let posts = try #require(model.tables.first { $0.name == "posts" })
        #expect(posts.columns.map(\.type) == [.bigint, .uuid, .numeric, .text])
        #expect(posts.columns[3].isNullable)
        #expect(model.qualifiedName(of: model.relationships[0].to) == "users.id", "a bare table name means its primary key")
        #expect(!Metrics.frame(of: model.tables[0]).intersects(Metrics.frame(of: posts)), "placed clear of each other")

        // A failing call changes nothing, even after parts of it would have worked.
        let before = model
        #expect(throws: ModelTools.Failure.self) {
            try ModelTools.call("create_tables", ["tables": [
                ["name": "tags", "columns": [["name": "id", "type": "int"]]],
                ["name": "post_tags", "columns": [["name": "tag_id", "references": "nope"]]],
            ]], on: &model)
        }
        #expect(model == before)

        _ = try ModelTools.call("alter_table", ["table": "POSTS", "change_columns": [["name": "author_id", "references": ""]]],
                                 on: &model)
        #expect(model.relationships.isEmpty, "an empty reference drops the foreign key")
    }

    @Test func columnsReadFromOlderFilesAreNotUnique() throws {
        let json = #"{"id": "6A2D0F0E-3B8B-4C47-9E5A-1F2E3D4C5B6A", "name": "email", "type": "text"}"#
        let column = try JSONDecoder().decode(Column.self, from: Data(json.utf8))
        #expect(!column.isUnique && !column.isNullable && !column.isPrimaryKey)

        var model = DataModel()
        _ = try ModelTools.call("create_tables", ["tables": [
            ["name": "users", "columns": [["name": "email", "type": "text", "unique": true, "required": false]]],
        ]], on: &model)
        let email = model.tables[0].columns[0]
        #expect(email.isUnique && email.isNullable)
        #expect(try ModelTools.describe(model).contains("\"unique\" : true"))
    }

    @Test func reroutingReusesRoutesThatDidNotChange() {
        let model = DataModel.synthetic(tables: 30, foreignKeys: 45)
        for avoiding in [false, true] {
            // From a routing with avoidance the other way, too, as when it's switched.
            let first = Routing(model: model, avoidingTables: avoiding)
            let switched = Routing(model: model, avoidingTables: avoiding, reusing: Routing(model: model, avoidingTables: !avoiding))
            for (id, route) in first.routes { #expect(switched.routes[id]?.points == route.points, "switched to avoiding: \(avoiding)") }
            let moved = model.tables[15].id
            let offsets = [moved: CGPoint(x: 37, y: -21)]
            let fresh = Routing(model: model, tableOffsets: offsets, avoidingTables: avoiding)
            let reused = Routing(model: model, tableOffsets: offsets, avoidingTables: avoiding, reusing: first)
            // Exactly the same as working everything out again.
            for (id, route) in fresh.routes { #expect(reused.routes[id]?.points == route.points, "avoiding: \(avoiding)") }
            #expect(reused.routes.count == fresh.routes.count)
        }
    }

    @Test func aligningTablesLeavesTiesCaughtWithThemAlone() {
        let canvas = CanvasController()
        let tables = [UUID(), UUID()], ties = [UUID(), UUID()]
        canvas.selection = Set(tables.map { .table($0) } + ties.map { .zipTie($0) })
        #expect(canvas.alignable?.tables == Set(tables))
        #expect(canvas.alignable?.ties.isEmpty == true)
        canvas.selection = Set(ties.map { .zipTie($0) })
        #expect(canvas.alignable?.ties == Set(ties), "ties on their own line up")
        canvas.selection = [.table(tables[0]), .zipTie(ties[0])]
        #expect(canvas.alignable == nil, "one table is nothing to line up")
    }

    @Test func overlappingTablesAreDrawnInLayers() {
        let frames = [CGRect(x: 0, y: 0, width: 236, height: 300), CGRect(x: 600, y: 0, width: 236, height: 100),
                      CGRect(x: 100, y: 150, width: 236, height: 100), CGRect(x: 150, y: 200, width: 236, height: 100)]
        let tables = frames.map { (table: Table(name: "t", position: $0.origin, color: .blue), frame: $0) }
        // Apart, one layer; on top of another, the next one up.
        #expect(TableLayer.layered(tables).map { $0.map(\.frame) } == [[frames[0], frames[1]], [frames[2]], [frames[3]]])
    }

    @Test func shiftHoldsAMoveToOneAxis() {
        #expect(CanvasController.moveOffset(CGPoint(x: 40, y: -12), isAxisLocked: true) == CGPoint(x: 40, y: 0))
        #expect(CanvasController.moveOffset(CGPoint(x: -5, y: 30), isAxisLocked: true) == CGPoint(x: 0, y: 30))
        #expect(CanvasController.moveOffset(CGPoint(x: 7, y: 9), isAxisLocked: false) == CGPoint(x: 7, y: 9))
    }

    @Test func draggedTablesSnapIntoLineAndShowGuides() {
        let other = CGRect(x: 100, y: 300, width: 236, height: 120)
        let moving = CGRect(x: 0, y: 0, width: 236, height: 80)
        // Left edges 4 apart: snaps across, and shows the line from one table to the other.
        let near = CanvasController.snap([moving], by: CGPoint(x: 96, y: 40), to: [other], tolerance: 6)
        #expect(near.offset == CGPoint(x: 100, y: 40))
        #expect(near.guides.contains(CanvasController.Guide(isVertical: true, position: 100, start: 40, end: 420)))
        // Too far to snap: left alone, no guides.
        let far = CanvasController.snap([moving], by: CGPoint(x: 80, y: 40), to: [other], tolerance: 6)
        #expect(far.offset == CGPoint(x: 80, y: 40) && far.guides.isEmpty)
        // Held to moving down, it doesn't snap across.
        let locked = CanvasController.snap([moving], by: CGPoint(x: 0, y: 297), to: [CGRect(x: 3, y: 0, width: 50, height: 300)],
                                           tolerance: 6, across: false)
        #expect(locked.offset.x == 0 && locked.offset.y == 300, "its top meets the other's bottom")
    }

    @Test func groupsHoldTheirTablesTakeInWhatsDroppedOnThemAndTheirTies() throws {
        // A file from before groups.
        let old = #"{"tables": [{"id": "6A2D0F0E-3B8B-4C47-9E5A-1F2E3D4C5B6A", "name": "t", "position": [0, 0], "color": "blue", "columns": []}], "relationships": [], "zipTies": []}"#
        let loaded = try JSONDecoder().decode(DataModel.self, from: Data(old.utf8))
        #expect(loaded.groups.isEmpty && loaded.tables[0].group == nil)

        var model = storefront()
        let users = model.tables[0].id, orders = model.tables[1].id, reviews = model.tables[2].id
        let group = model.group([orders, reviews], named: "sales")
        #expect(model.members(of: group).map(\.id) == [orders, reviews])

        // users dropped in the middle of sales joins it.
        let frame = try #require(model.frame(of: group))
        model.tables[0].position = CGPoint(x: frame.midX - Metrics.tableWidth / 2, y: frame.midY - 20)
        model.regroup([users])
        #expect(model.tables[0].group == group)
        // Anywhere in its boundary as drawn counts, its name's band too.
        model.removeFromGroups([users])
        let height = Metrics.size(of: model.tables[0]).height
        model.tables[0].position = CGPoint(x: frame.midX - Metrics.tableWidth / 2, y: frame.minY + 4 - height / 2)
        model.regroup([users])
        #expect(model.tables[0].group == group)

        // Moved with its whole group, a table stays in it, wherever the group goes.
        model.move(tables: [users, orders, reviews], ties: [], by: CGPoint(x: 5000, y: 0))
        model.regroup([users, orders, reviews])
        #expect(model.members(of: group).count == 3)

        // A tie inside the boundary is the group's, and comes with it when it's selected.
        model.zipTies.append(ZipTie(position: CGPoint(x: frame.midX + 5000, y: frame.midY), direction: CGPoint(x: 1, y: 0),
                                    relationships: [model.relationships[0].id]))
        let canvas = CanvasController()
        canvas.selectGroup(group, in: model, extending: false)
        #expect(canvas.selectedTies == [model.zipTies[0].id])
        #expect(canvas.selectedTables == [users, orders, reviews])

        // Emptied, it goes.
        model.removeFromGroups([users, orders, reviews])
        #expect(model.groups.isEmpty)
    }

    @Test func assistantToolsWorkInSchemas() throws {
        var model = DataModel()
        _ = try ModelTools.call("create_tables", ["tables": [
            ["name": "users", "schema": "auth", "columns": [["name": "id", "type": "uuid", "primary_key": true]]],
            ["name": "sessions", "schema": "auth", "columns": [["name": "user_id", "type": "uuid", "references": "users"]]],
            ["name": "orders", "schema": "sales", "columns": [["name": "user_id", "type": "uuid", "references": "users"]]],
        ]], on: &model)
        #expect(model.groups.map(\.name) == ["auth", "sales"])
        let auth = model.groups[0].id
        #expect(model.members(of: auth).map(\.name) == ["users", "sessions"])
        #expect(try ModelTools.describe(model).contains("\"schema\" : \"auth\""))

        _ = try ModelTools.call("set_schema", ["schema": "sales", "tables": ["sessions"], "rename_to": "commerce"], on: &model)
        #expect(model.groups.first { $0.name == "commerce" }.map { model.members(of: $0.id).map(\.name) } == ["sessions", "orders"])
        _ = try ModelTools.call("drop_schema", ["schema": "auth"], on: &model)
        #expect(model.groups.map(\.name) == ["commerce"])
        #expect(model.tables.first { $0.name == "users" }?.group == nil)
    }

    @Test func layoutsLeaveNoTablesOverlappingAndKeepGroupsTogether() {
        var model = DataModel.synthetic(tables: 60, foreignKeys: 90, groups: 4)
        model.zipTies.append(ZipTie(position: .zero, direction: CGPoint(x: 1, y: 0), relationships: [model.relationships[0].id]))
        model.relationships[0].zipTies = [model.zipTies[0].id]
        // Everything piled up, as an import might leave it.
        for index in model.tables.indices { model.tables[index].position = CGPoint(x: CGFloat(index), y: 0) }
        for layout in DataModel.Layout.allCases {
            var arranged = model
            arranged.arrange(layout)
            #expect(arranged.zipTies.isEmpty && arranged.relationships.allSatisfy(\.zipTies.isEmpty), "ties placed for the old layout go")
            let frames = arranged.tables.map(Metrics.frame)
            for (i, a) in frames.enumerated() {
                for b in frames[(i + 1)...] { #expect(!a.intersects(b), "\(layout.title)") }
            }
            guard layout == .orthogonalGroups else { continue }
            // Groups' boundaries don't overlap either.
            let boundaries = arranged.groups.compactMap { arranged.frame(of: $0.id) }
            for (i, a) in boundaries.enumerated() {
                for b in boundaries[(i + 1)...] { #expect(!a.intersects(b)) }
            }
        }
    }

    @Test func copyingCanOfferTheTablesTheSelectionIsJoinedTo() throws {
        var model = storefront()
        let users = model.tables[0].id, orders = model.tables[1].id, reviews = model.tables[2].id
        let sales = model.group([orders, reviews], named: "sales")
        // payments references orders.
        let payments = model.addTable(at: CGPoint(x: 900, y: 0))
        let index = try #require(model.tables.firstIndex { $0.id == payments })
        model.tables[index].columns.append(Column(name: "order_id", type: .uuid))
        model.connect(model.tables[index].columns[1].id, to: model.tables[1].columns[0].id)

        // How far each table is from orders, either way along keys: users and payments one key, reviews two.
        let distances = model.joinedTables(to: [orders])
        #expect(distances == [users: 1, payments: 1, reviews: 2])
        #expect(model.joinedTables(to: [orders, users]) == [payments: 1, reviews: 1])

        // Copying orders and a table chosen from those: its group comes, holding only the tables copied.
        let clip = model.clip(tables: [orders, payments])
        #expect(Set(clip.tables.map(\.id)) == [orders, payments])
        #expect(clip.groups.map(\.id) == [sales] && clip.members(of: sales).map(\.id) == [orders])
    }

    @Test func selectedTablesCopyAsMarkdownWithTheirSQLAndNotes() {
        var model = storefront()
        let orders = model.tables[1].id
        model.group([orders], named: "sales")
        model.tables[1].notes = "One per checkout."
        model.tables[0].name = "User Accounts"

        let markdown = model.markdown(of: [orders], title: "Shop")
        #expect(markdown.hasPrefix("# Shop\n\n1 of the 3 tables"))
        #expect(markdown.contains("### orders\nSchema: `sales`"))
        #expect(markdown.contains("| user_id | uuid | FK | yes | User Accounts.id |"))
        // Names that aren't plain identifiers are quoted; a schema is made before its tables.
        #expect(markdown.contains("CREATE SCHEMA IF NOT EXISTS sales;"))
        #expect(markdown.contains("CREATE TABLE sales.orders (\n  id uuid PRIMARY KEY,\n  user_id uuid NOT NULL REFERENCES \"User Accounts\" (id)\n);"))
        #expect(markdown.contains("## Notes\n\n### orders\n\nOne per checkout."))
        // Every table, with no selection; no notes section when none have notes.
        model.tables[1].notes = ""
        let all = model.markdown(of: nil, title: "Shop")
        #expect(!all.contains("of the") && !all.contains("## Notes") && all.contains("Referenced by: orders.user_id, reviews.user_id"))
    }

    @Test func copiedTablesPasteWithTheirKeysTiesAndSchema() throws {
        var model = storefront()
        let orders = model.tables[1], reviews = model.tables[2]
        model.group([orders.id, reviews.id], named: "sales")
        model.zipTies.append(ZipTie(position: CGPoint(x: 400, y: 0), direction: CGPoint(x: 1, y: 0), relationships: model.relationships.map(\.id)))
        for index in model.relationships.indices { model.relationships[index].zipTies = [model.zipTies[0].id] }

        // Into the same model: new names, the same schema, still referencing users, the tie copied too.
        let clip = model.clip(tables: [orders.id, reviews.id])
        var same = model
        let pasted = same.paste(clip, offset: CGPoint(x: 32, y: 32))
        #expect(same.tables.map(\.name) == ["users", "orders", "reviews", "orders_2", "reviews_2"])
        #expect(same.groups.count == 1 && same.members(of: same.groups[0].id).count == 4)
        #expect(same.relationships.count == 4)
        #expect(pasted.ties.count == 1 && same.zipTies.count == 2)
        let copiedWires = same.relationships.suffix(2)
        #expect(copiedWires.allSatisfy { $0.zipTies == pasted.ties })

        // Into another: users isn't there, so the keys to it go; the tables and schema come.
        var other = DataModel()
        _ = other.paste(clip, offset: .zero)
        #expect(other.tables.map(\.name) == ["orders", "reviews"])
        #expect(other.relationships.isEmpty && other.zipTies.isEmpty)
        #expect(other.groups.map(\.name) == ["sales"])
    }

    @Test func aKeysTypeChangeGoesToTheKeysJoinedToIt() {
        let model = storefront()
        var changed = model
        // users.id, referenced by orders.user_id and reviews.user_id.
        changed.tables[0].columns[0].type = .bigint
        changed.carryTypes(from: model)
        let userIDs = changed.relationships.filter { $0.to == model.tables[0].columns[0].id }.map(\.from)
        #expect(!userIDs.isEmpty)
        #expect(userIDs.allSatisfy { changed.columnLocations[$0].map { $0.table.columns[$0.row].type } == .bigint })
        // Unjoined columns keep theirs; nothing changed, nothing moves.
        #expect(changed.tables[1].columns[0].type == model.tables[1].columns[0].type)
        var same = model
        same.carryTypes(from: model)
        #expect(same == model)
    }

    @Test func openSpotIsTheNearestClearPlaceInTheArea() throws {
        var model = DataModel()
        let size = CGSize(width: Metrics.tableWidth, height: 100)
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // Nothing there: where asked.
        #expect(model.openSpot(for: size, near: CGPoint(x: 100, y: 100), in: area) == CGPoint(x: 100, y: 100))
        // A table there: somewhere near, clear of it, still in the area.
        _ = model.addTable(at: CGPoint(x: 100, y: 100))
        let spot = try #require(model.openSpot(for: size, near: CGPoint(x: 100, y: 100), in: area))
        #expect(!Metrics.frame(of: model.tables[0]).insetBy(dx: -24, dy: -24).intersects(CGRect(origin: spot, size: size)))
        #expect(area.contains(CGRect(origin: spot, size: size)))
        #expect(spot.distance(to: CGPoint(x: 100, y: 100)) < 200)
        // No room at all: nil.
        #expect(model.openSpot(for: size, near: .zero, in: CGRect(x: 100, y: 100, width: 236, height: 52)) == nil)
    }

    @Test func pastedTableTakesTheGroupItLandsIn() throws {
        var model = storefront()
        let orders = model.tables[1], reviews = model.tables[2]
        model.group([orders.id, reviews.id], named: "sales")
        let clip = model.clip(tables: [orders.id])
        model.tables.removeAll { $0.id == orders.id }

        // Cut from the group and pasted far from it: in no group.
        var away = model
        let far = away.paste(clip, offset: CGPoint(x: 5000, y: 5000)).tables
        #expect(away.table(far[0])?.group == nil && away.groups.count == 1)

        // Pasted over the group: in it.
        var back = model
        let near = back.paste(clip, offset: reviews.position - orders.position).tables
        #expect(back.table(near[0])?.group == back.table(reviews.id)?.group)
    }

    @Test func untanglingCrossesFewerWiresTheSameWayEveryTime() {
        var model = DataModel.synthetic(tables: 24, foreignKeys: 36)
        // Scrambled: each table swapped with one across the grid, so wires criss-cross.
        let positions = model.tables.map(\.position)
        for index in model.tables.indices { model.tables[index].position = positions[(index * 7) % positions.count] }
        let moving = Set(model.tables.map(\.id))
        func run() -> Untangler {
            var untangler = Untangler(model: model, moving: moving)
            while !untangler.isDone { untangler.step() }
            return untangler
        }
        let first = run(), second = run()
        #expect(first.best.crossings < first.startingCrossings, "from \(first.startingCrossings) to \(first.best.crossings)")
        #expect(first.bestOffsets == second.bestOffsets, "nothing random")
        var untangled = model
        for index in untangled.tables.indices { untangled.tables[index].position += first.bestOffsets[untangled.tables[index].id] ?? .zero }
        let frames = untangled.tables.map(Metrics.frame)
        for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { #expect(!a.intersects(b)) } }
    }

    @Test func untanglingDeletesTheSelectionsTiesInOneChange() async throws {
        var model = storefront()
        let wire = model.relationships[0]
        let bend = model.addBendPoint(on: wire.id, at: CGPoint(x: 360, y: 120), direction: CGPoint(x: 1, y: 0), segment: 0)
        let tie = try #require(bend)
        let table = try #require(model.columnLocations[wire.from]?.table.id)
        // One table alone, so there may be nothing better to move to: the tie goes all the same.
        let canvas = CanvasController()
        canvas.selection = [.table(table)]
        var changes: [DataModel] = []
        let binding = Binding { model } set: { model = $0; changes.append($0) }
        canvas.untangleSelection(of: binding)
        #expect(canvas.shown(model).zipTies.isEmpty, "hidden while it runs")
        while canvas.isUntangling { try await Task.sleep(for: .milliseconds(20)) }
        #expect(changes.count == 1, "one undo")
        #expect(model.zipTies.isEmpty && model.relationships[0].zipTies.isEmpty)
        #expect(!canvas.selection.contains(.zipTie(tie)))
    }

    @Test func aGroupsPortBundlesItsWiresToAColumnIntoOneBus() throws {
        var model = storefront()
        let users = model.tables[0], usersID = users.columns[0].id
        let wires = model.relationships.map(\.id)
        model.addBendPoint(on: wires[0], at: CGPoint(x: 400, y: 0), direction: CGPoint(x: 1, y: 0), segment: 0)
        // Orders and reviews, both referencing users, grouped; users left of them, outside.
        let group = model.group([model.tables[1].id, model.tables[2].id], named: "shop")
        #expect(model.bundleSharedWires(in: group, minimum: 2) == 1)
        #expect(model.zipTies.isEmpty, "ties placed for the old wires go")

        let (id, port) = try #require(model.portPlacements().first)
        let frame = try #require(model.frame(of: group))
        #expect(port.label == "users.id" && Set(port.wires) == Set(wires))
        #expect(port.normal == CGPoint(x: -1, y: 0) && port.point.x == frame.minX, "on the side facing users")

        // Each wire ends at the port; one bus runs from it to the users socket facing it.
        let routing = Routing(model: model)
        // Side by side across its inside end, not all into one point; which widens for them, from a pill's.
        let ends = Set(wires.compactMap { routing.routes[$0]?.points.last })
        #expect(ends == [port.insideSlot(0, of: 2), port.insideSlot(1, of: 2)])
        #expect(port.insideSlot(0, of: 2).distance(to: port.insideSlot(1, of: 2)) == Metrics.portSlotSpacing)
        let pill = PortShape(label: "users.id", wires: 1, isOnLeftOrRight: true)
        #expect(pill.inner == pill.outer && pill.outer == Metrics.portHeight / 2)
        let fan = PortShape(label: "users.id", wires: 20, isOnLeftOrRight: true)
        #expect(fan.inner > fan.outer * 3 && fan.outer == pill.outer && fan.length >= pill.length)
        // Its wires plug in along the flat of its inside end, never on the rounding of its corners.
        for wires in [2, 5, 20, 40] {
            let shape = PortShape(label: "entity.entity_id", wires: wires, isOnLeftOrRight: true)
            let outermost = CGFloat(wires - 1) * Metrics.portSlotSpacing / 2
            #expect(outermost + Metrics.wireWidth / 2 <= shape.flat + 0.01, "\(wires) wires")
        }
        // Its outline keeps within it, on any side: on the top or bottom it's only a pill's height long.
        for isOnLeftOrRight in [true, false] {
            for wires in [0, 1, 3, 20] {
                let shape = PortShape(label: "entity.entity_id", wires: wires, isOnLeftOrRight: isOnLeftOrRight)
                let bounds = CanvasView.portOutline(shape).boundingRect
                #expect(bounds.width <= shape.length + 0.01 && bounds.height <= max(shape.inner, shape.outer) * 2 + 0.01,
                        "\(isOnLeftOrRight ? "side" : "top"), \(wires) wires: \(bounds)")
            }
        }
        let bus = try #require(routing.routes[id])
        #expect(bus.points.first == port.outside)
        #expect(bus.points.last == Metrics.socket(row: 0, side: .trailing, in: Metrics.frame(of: users)))

        // Dropping a socket on the port references its column.
        let orders = model.tables[1].id
        let index = try #require(model.tables.firstIndex { $0.id == orders })
        let column = Column(name: "buyer_id", type: .uuid)
        model.tables[index].columns.append(column)
        #expect(model.dropTarget(at: port.point) == .port(id))
        let connected = model.connect(dragging: column.id, onto: .port(id))
        let wire = try #require(connected)
        #expect(model.relationships.first { $0.id == wire }?.to == usersID)
        #expect(model.portPlacements()[id]?.wires.count == 3)

        // Dragged near the group's bottom edge, it goes there, and stays as far along it however the group grows;
        // put back, it faces its column again.
        let spot = try #require(model.portSpot(nearest: CGPoint(x: frame.midX, y: frame.maxY + 30), on: group))
        #expect(spot.side == .bottom && abs(spot.along - 0.5) < 0.01)
        model.movePort(id, to: spot)
        let moved = try #require(model.portPlacements()[id])
        #expect(moved.normal == CGPoint(x: 0, y: 1) && moved.point == CGPoint(x: frame.midX, y: frame.maxY))
        #expect(Routing(model: model).routes[wires[0]]?.points.last.map { $0.distance(to: moved.inside) <= Metrics.portSlotSpacing } == true,
                "the wires follow it")
        let saved = try JSONDecoder().decode(DataModel.self, from: model.fileData)
        #expect(saved.portPlacements()[id] == moved, "and it's kept where it was put")
        model.movePort(id, to: nil)
        #expect(model.portPlacements()[id]?.normal == CGPoint(x: -1, y: 0))

        // A port for a column none of the group's tables reference yet still runs its bus there, plugged in, to tie into.
        let reviews = model.tables[2].id
        let lone = model.group([reviews], named: "feedback")
        let reviewColumns = Set(model.tables[2].columns.map(\.id))
        model.removeRelationships { reviewColumns.contains($0.from) }
        let added = model.addPort(to: lone, for: usersID)
        let empty = try #require(added)
        let emptyRouting = Routing(model: model)
        #expect(emptyRouting.ports[empty]?.wires.isEmpty == true)
        #expect(emptyRouting.routes[empty]?.points.first == emptyRouting.ports[empty]?.outside)
        #expect(emptyRouting.sockets[empty]?.to.column == usersID)

        // Once users joins the group, there's nothing outside to stand for: the port's left unplugged, where it was.
        model.tables[0].group = group
        model.repair()
        #expect(model.groups.first { $0.id == group }?.ports.allSatisfy { $0.column == nil } == true)
    }

    @Test func assistantsTablesLandInOpenSpaceBesideTheirCompany() throws {
        var model = DataModel()
        let table = { (name: String, schema: String, references: String?) -> [String: Any] in
            var columns: [[String: Any]] = [["name": "id", "type": "uuid", "primary_key": true]]
            if let references { columns.append(["name": references + "_id", "type": "uuid", "references": references]) }
            return ["name": name, "schema": schema, "columns": columns]
        }
        _ = try ModelTools.call("create_tables", ["tables": [
            table("users", "auth", nil), table("sessions", "auth", "users"), table("tokens", "auth", "users"),
        ]], on: &model)
        // A new schema's tables, referencing users, then one more for auth.
        _ = try ModelTools.call("create_tables", ["tables": [
            table("orders", "shop", "users"), table("items", "shop", "orders"), table("carts", "shop", "users"),
        ]], on: &model)
        _ = try ModelTools.call("create_tables", ["tables": [table("devices", "auth", "users")]], on: &model)

        func isClear() -> Bool {
            let frames = model.tables.map(Metrics.frame)
            let tablesApart = frames.indices.allSatisfy { i in frames.indices.allSatisfy { $0 == i || !frames[i].intersects(frames[$0]) } }
            return tablesApart && model.groups.allSatisfy { !model.isCrowded($0.id) }
        }
        #expect(isClear(), "no table on another, no schema over anything not in it")
        let auth = try #require(model.groups.first { $0.name == "auth" }), shop = try #require(model.groups.first { $0.name == "shop" })
        let authFrame = try #require(model.frame(of: auth.id)), shopFrame = try #require(model.frame(of: shop.id))
        #expect(shopFrame.minX - authFrame.maxX < 400 || shopFrame.minY - authFrame.maxY < 400, "beside what it references")

        // Moving tables beside another puts them in the open next to it; the layout is there to read.
        _ = try ModelTools.call("set_schema", ["schema": "shop", "tables": ["devices"]], on: &model)
        #expect(isClear(), "a table joining a schema from across the canvas is brought beside it")
        _ = try ModelTools.call("move_tables", ["tables": ["carts"], "near": "users"], on: &model)
        #expect(isClear())
        let description = try ModelTools.call("get_model", [:], on: &model)
        #expect(description.contains("\"frame\"") && description.contains("\"bounds\""))
    }

    @Test func aPortMadeOnAGroupsEdgeIsNamedForWhatItsPluggedIntoAndItsBusIsACable() throws {
        var model = storefront()
        let usersID = model.tables[0].columns[0].id
        let group = model.group([model.tables[1].id, model.tables[2].id], named: "shop")
        // The + clicked on the left edge: a nameless port, sockets either side, no bus yet.
        let added = model.addPort(to: group, at: (.left, 0.5))
        let id = try #require(added)
        var port = try #require(model.portPlacements()[id])
        #expect(port.label.isEmpty && port.column == nil && Routing(model: model).routes[id] == nil)
        #expect(port.inside.x > port.point.x && port.outside.x < port.point.x, "one socket in the group, one out")
        #expect(model.dropTarget(at: port.point) == .port(id))

        // Its outside plugged into users.id, it's named for it, and bundles the group's wires to it.
        model.plug(id, into: usersID)
        port = try #require(model.portPlacements()[id])
        #expect(port.label == "users.id" && port.wires.count == 2)
        // Only one: plugged into another, that's what it stands for.
        model.plug(id, into: model.tables[0].columns[0].id)
        #expect(model.groups[0].ports.count == 1)

        // Its bus takes bend points and ties as a wire does, and is routed through them.
        let bus = try #require(Routing(model: model).routes[id])
        let middle = bus.points[bus.points.count / 2]
        let bent = model.addBendPoint(on: id, at: middle, direction: CGPoint(x: -1, y: 0), segment: 0)
        let bend = try #require(bent)
        model.repair()
        #expect(model.zipTies(onCable: id) == [bend], "kept by repair")
        #expect(Routing(model: model).routes[id]?.points.contains(middle) == true)
        model.removeZipTie(bend)
        #expect(model.zipTies(onCable: id)?.isEmpty == true)

        // Deleting the bus deletes the port; its wires run all the way again.
        let canvas = CanvasController()
        canvas.selection = [.relationship(id)]
        canvas.deleteSelection(in: &model)
        #expect(model.groups[0].ports.isEmpty && model.relationships.count == 2)
    }

    @Test func aLayoutOfSomeTablesLeavesTheRestAlone() throws {
        var model = DataModel.synthetic(tables: 24, foreignKeys: 36)
        let picked = Set(model.tables.prefix(8).map(\.id))
        // A bend point on a wire between two tables not picked, which should stay.
        let columns = Set(model.tables.filter { picked.contains($0.id) }.flatMap(\.columns).map(\.id))
        let elsewhere = try #require(model.relationships.first { !columns.contains($0.from) && !columns.contains($0.to) })
        let bent = model.addBendPoint(on: elsewhere.id, at: CGPoint(x: -500, y: -500), direction: CGPoint(x: 1, y: 0), segment: 0)
        let bend = try #require(bent)
        let before = model

        for layout in DataModel.Layout.allCases {
            model = before
            model.arrange(layout, only: picked)
            for table in model.tables where !picked.contains(table.id) {
                #expect(table.position == before.table(table.id)?.position, "\(layout): \(table.name) stays put")
            }
            #expect(model.tables.contains { picked.contains($0.id) && $0.position != before.table($0.id)?.position })
            #expect(model.zipTies.contains { $0.id == bend }, "\(layout): ties elsewhere stay")
            let frames = model.tables.map(Metrics.frame)
            for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { #expect(!a.intersects(b), "\(layout): no overlaps") } }
        }
    }

    @Test func columnsMoveWithinTheirTableAndTheirWiresFollow() throws {
        var model = storefront()
        let orders = model.tables[1].id
        let index = try #require(model.tables.firstIndex { $0.id == orders })
        model.tables[index].columns += [Column(name: "total", type: .numeric), Column(name: "placed_at", type: .timestamp)]
        let names = { model.tables[index].columns.map(\.name) }
        #expect(names() == ["id", "user_id", "total", "placed_at"])
        let userID = model.tables[index].columns[1].id

        // Dropped before the column at 3: down, past total.
        model.moveColumn(userID, in: orders, to: 3)
        #expect(names() == ["id", "total", "user_id", "placed_at"])
        // Up, to the top; and past the end, last.
        model.moveColumn(userID, in: orders, to: 0)
        #expect(names() == ["user_id", "id", "total", "placed_at"])
        model.moveColumn(userID, in: orders, to: 99)
        #expect(names() == ["id", "total", "placed_at", "user_id"])

        // Its wire leaves from its new row.
        let wire = try #require(model.relationships.first { $0.from == userID })
        let start = try #require(Routing(model: model).routes[wire.id]?.points.first)
        let frame = Metrics.frame(of: model.tables[index])
        #expect(abs(start.y - (frame.minY + Metrics.headerHeight + 3.5 * Metrics.rowHeight)) < 0.5)
    }

    @Test func aBendPointDroppedOnAZipTieJoinsItsCableToIt() throws {
        var model = storefront()
        // A third wire, to reviews from a new column in orders.
        let orders = try #require(model.tables.firstIndex { $0.name == "orders" })
        let column = Column(name: "review_id", type: .uuid)
        model.tables[orders].columns.append(column)
        let reviewsKey = try #require(model.tables.first { $0.name == "reviews" }?.columns.first?.id)
        let connected = model.connect(column.id, to: reviewsKey)
        let third = try #require(connected)
        // The two to users tied together, running across; a bend point on the third, just below them.
        let wires = model.relationships.filter { $0.id != third }.map(\.id)
        let tie = ZipTie(position: CGPoint(x: 250, y: 0), direction: CGPoint(x: 1, y: 0), relationships: wires)
        model.zipTies.append(tie)
        for wire in wires { model.setZipTies(onCable: wire, [tie.id]) }
        let placed = model.addBendPoint(on: third, at: CGPoint(x: 250, y: 30), direction: CGPoint(x: 1, y: 0), segment: 0)
        let bend = try #require(placed)

        model.merge(bend, into: tie.id, along: CGPoint(x: 1, y: 0))
        #expect(!model.zipTies.contains { $0.id == bend }, "the bend point goes")
        #expect(model.zipTies.first { $0.id == tie.id }?.relationships == wires + [third], "in the slot on its side")
        #expect(model.zipTies(onCable: third) == [tie.id])
        model.repair()
        #expect(model.zipTies.first { $0.id == tie.id }?.relationships.count == 3, "and it holds")
    }

    @Test func layoutsCrossFewerWiresOnceRefinedTheSameWayEveryTime() {
        let model = DataModel.synthetic(tables: 60, foreignKeys: 90, groups: 3)
        func crossings(_ model: DataModel) -> Int {
            let owner = model.columnLocations
            let middle = { (id: Table.ID) in model.table(id).map { CGPoint(x: Metrics.frame(of: $0).midX, y: Metrics.frame(of: $0).midY) } }
            return Untangler.crossings(model.relationships.compactMap { wire in
                guard let a = owner[wire.from].flatMap({ middle($0.table.id) }), let b = owner[wire.to].flatMap({ middle($0.table.id) }) else { return nil }
                return (a, b)
            })
        }
        DataModel.refinementRounds = 0
        var plain = model
        plain.arrange(.orthogonalGroups)
        DataModel.refinementRounds = 6
        var refined = model, again = model
        refined.arrange(.orthogonalGroups)
        again.arrange(.orthogonalGroups)
        #expect(crossings(refined) < crossings(plain) * 3 / 4, "\(crossings(plain)) to \(crossings(refined))")
        #expect(refined == again, "nothing random")
        let frames = refined.tables.map(Metrics.frame)
        for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { #expect(!a.intersects(b)) } }
    }

    @Test func cablesComeOutOfTiesAndGoIntoThem() throws {
        var model = storefront()
        let wires = model.relationships.map(\.id)
        let tie = ZipTie(position: CGPoint(x: 250, y: 0), direction: CGPoint(x: 1, y: 0), relationships: wires)
        model.zipTies.append(tie)
        for wire in wires { model.setZipTies(onCable: wire, [tie.id]) }

        // Tugged out: the tie keeps the other; out of that too, it goes.
        model.untie(wires[0], from: tie.id)
        #expect(model.zipTies.first { $0.id == tie.id }?.relationships == [wires[1]] && model.zipTies(onCable: wires[0]) == [])
        model.untie(wires[1], from: tie.id)
        #expect(model.zipTies.isEmpty && model.zipTies(onCable: wires[1]) == [])

        // Dropped on a tie: in, on the side it came from, as the tie's first along it.
        let other = ZipTie(position: CGPoint(x: 250, y: 0), direction: CGPoint(x: 1, y: 0), relationships: [wires[1]])
        model.zipTies.append(other)
        model.setZipTies(onCable: wires[1], [other.id])
        model.tie(wires[0], into: other.id, at: 0, from: CGPoint(x: 250, y: -20), along: CGPoint(x: 1, y: 0))
        #expect(model.zipTies.first { $0.id == other.id }?.relationships == [wires[0], wires[1]], "above it, so first across")
        #expect(model.zipTies(onCable: wires[0]) == [other.id])
        model.repair()
        #expect(model.zipTies.first { $0.id == other.id }?.relationships.count == 2)
    }

    @Test func zipTiesDroppedOnOthersCombine() throws {
        var model = DataModel.synthetic(tables: 6, foreignKeys: 5)
        let wires = model.relationships.map(\.id)
        func tie(_ cables: [UUID], at point: CGPoint) -> ZipTie.ID {
            let tie = ZipTie(position: point, direction: CGPoint(x: 1, y: 0), relationships: cables)
            model.zipTies.append(tie)
            for cable in cables { model.setZipTies(onCable: cable, (model.zipTies(onCable: cable) ?? []) + [tie.id]) }
            return tie.id
        }
        // One tie of the first two wires below another of the next two and the second again.
        let target = tie([wires[2], wires[1], wires[3]], at: CGPoint(x: 300, y: 300))
        let dragged = tie([wires[0], wires[1]], at: CGPoint(x: 300, y: 340))
        model.merge(dragged, into: target, along: CGPoint(x: 1, y: 0))
        #expect(!model.zipTies.contains { $0.id == dragged })
        let combined = try #require(model.zipTies.first { $0.id == target })
        #expect(Set(combined.relationships) == Set(wires.prefix(4)) && combined.relationships.count == 4, "no wire twice")
        #expect(combined.relationships.last == wires[0], "coming from below, the bottom slot")
        for wire in wires.prefix(4) { #expect(model.zipTies(onCable: wire) == [target]) }
        model.repair()
        #expect(model.zipTies.first { $0.id == target }?.relationships.count == 4)
    }

    @Test func aBusTakesItsOwnWidthInAZipTie() throws {
        let wire = Routing.Tie(center: .zero, direction: CGPoint(x: 1, y: 0), relationships: [UUID(), UUID(), UUID()])
        #expect(wire.slot(1) == .zero && wire.slot(2).y == Metrics.tieSpacing, "wires alone, a tie's spacing apart as ever")
        #expect(wire.halfLength == Metrics.tieHalfLength(holding: 3))
        // A bus between two wires: its edges as far from theirs as wires' are from each other.
        let gap = Metrics.tieSpacing - Metrics.wireWidth
        let mixed = Routing.Tie(center: .zero, direction: CGPoint(x: 1, y: 0), relationships: [UUID(), UUID(), UUID()],
                                widths: [Metrics.wireWidth, Metrics.busWidth, Metrics.wireWidth])
        let (a, b, c) = (mixed.slot(0).y, mixed.slot(1).y, mixed.slot(2).y)
        #expect(abs((b - Metrics.busWidth / 2) - (a + Metrics.wireWidth / 2) - gap) < 0.001)
        #expect(abs((c - Metrics.wireWidth / 2) - (b + Metrics.busWidth / 2) - gap) < 0.001)
        #expect(abs(a + c) < 0.001 && mixed.halfLength > wire.halfLength, "centered, and longer for the bus")
    }

    @Test func tablesKeepSampleRowsAndNotes() throws {
        var model = storefront()
        let users = model.tables[0].id
        let index = try #require(model.tables.firstIndex { $0.id == users })
        let id = model.tables[index].columns[0].id
        model.tables[index].setSample(1, id, to: "u_2")
        #expect(model.tables[index].samples.count == 2 && model.tables[index].sample(1, id) == "u_2" && model.tables[index].sample(0, id) == "")
        model.tables[index].notes = "Everyone who can sign in."

        // Kept through a column's rename or move, saved, and pasted (under its column's new ID).
        model.tables[index].columns[0].name = "user_id"
        let saved = try JSONDecoder().decode(DataModel.self, from: model.fileData)
        #expect(saved.table(users)?.sample(1, id) == "u_2" && saved.table(users)?.notes == "Everyone who can sign in.")
        var other = DataModel()
        let pasted = other.paste(model.clip(tables: [users]), offset: .zero).tables
        let first = try #require(pasted.first)
        let copy = try #require(other.table(first))
        #expect(copy.sample(1, copy.columns[0].id) == "u_2" && copy.notes == "Everyone who can sign in.")

        // A file from before tables had them reads with none.
        let old = #"{"tables":[{"id":"\#(UUID().uuidString)","name":"t","position":[0,0],"color":"blue","columns":[]}]}"#
        let decoded = try JSONDecoder().decode(DataModel.self, from: Data(old.utf8))
        #expect(decoded.tables.first?.samples.isEmpty == true && decoded.tables.first?.notes == "")
    }

    @Test func assistantsSetSampleDataAndNotes() throws {
        var model = DataModel()
        _ = try ModelTools.call("create_tables", ["tables": [
            ["name": "orders", "notes": "One per checkout.",
             "columns": [["name": "id", "type": "uuid", "primary_key": true], ["name": "total", "type": "numeric"], ["name": "paid", "type": "boolean"]],
             "sample_rows": [["id": "a1", "total": 129.95, "paid": true]]],
        ]], on: &model)
        _ = try ModelTools.call("set_sample_data", ["table": "orders", "rows": [["id": "b2", "Total": 18.5]], "append": true], on: &model)
        let orders = try #require(model.tables.first)
        let total = try #require(orders.columns.first { $0.name == "total" }?.id)
        #expect(orders.samples.count == 2 && orders.sample(0, total) == "129.95" && orders.sample(1, total) == "18.5")
        #expect(orders.sample(0, try #require(orders.columns.last?.id)) == "true" && orders.notes == "One per checkout.")
        #expect(throws: ModelTools.Failure.self) { try ModelTools.call("set_sample_data", ["table": "orders", "rows": [["nope": 1]]], on: &model) }

        _ = try ModelTools.call("alter_table", ["table": "orders", "notes": "Totals include tax."], on: &model)
        let described = try ModelTools.call("get_model", [:], on: &model)
        #expect(described.contains("Totals include tax.") && described.contains("\"sample_rows\"") && described.contains("b2"))
    }

    @Test func comparingVersionsMarksWhatChanged() throws {
        var before = DataModel()
        _ = try ModelTools.call("create_tables", ["tables": [
            ["name": "users", "columns": [["name": "id", "type": "uuid", "primary_key": true]]],
            ["name": "coupons", "columns": [["name": "id", "type": "uuid", "primary_key": true]]],
            ["name": "orders", "columns": [["name": "id", "type": "uuid", "primary_key": true], ["name": "user_id", "type": "uuid", "references": "users"],
                                           ["name": "coupon_id", "type": "uuid", "references": "coupons"], ["name": "total", "type": "integer"],
                                           ["name": "note", "type": "text"]]],
        ]], on: &before)
        var after = before
        _ = try ModelTools.call("drop_tables", ["tables": ["coupons"]], on: &after)
        _ = try ModelTools.call("alter_table", ["table": "orders", "drop_columns": ["note"], "add_columns": [["name": "currency", "type": "varchar"]],
                                                "change_columns": [["name": "total", "type": "numeric", "rename_to": "amount"]]], on: &after)
        _ = try ModelTools.call("create_tables", ["tables": [["name": "refunds", "columns": [["name": "order_id", "type": "uuid", "references": "orders"]]]]], on: &after)
        // Moving a table isn't a change.
        after.tables[0].position.x += 500

        let diff = SchemaDiff(from: before, to: after)
        let id = { (name: String) in try #require(diff.model.tables.first { $0.name == name }?.id) }
        #expect(diff.tables == [try id("coupons"): .removed, try id("orders"): .modified, try id("refunds"): .added])
        // Orders as a line diff: the removed column back after the one it followed, the changed one as it was, then as it is.
        let orders = try #require(diff.model.table(try id("orders")))
        #expect(orders.columns.map(\.name) == ["id", "user_id", "coupon_id", "total", "amount", "note", "currency"])
        #expect(orders.columns.map { diff.columns[$0.id] } == [nil, nil, nil, .removed, .modified, .removed, .added])
        #expect(diff.formerly == [orders.columns[3].id])
        #expect(diff.relationships.values.sorted { "\($0)" < "\($1)" } == [.added, .removed])
        #expect(diff.summary == "1 table added, 1 removed, 3 columns changed, 1 key added, 1 removed")
        #expect(SchemaDiff(from: before, to: before).summary == "No changes")
        // The same comparison draws the same model.
        #expect(SchemaDiff(from: before, to: after) == diff)
    }

    /// The whole server minus the socket, as any platform's app drives it: request bytes in, response bytes out.
    @Test func theMCPServerAnswersHTTPWithoutTheApp() async throws {
        final class Host: MCPHost {
            var model = DataModel()
            func callLibraryTool(_ name: String, _ arguments: [String: Any]) async throws -> String { "library: \(name)" }
            func edit(_ change: (inout DataModel) throws -> String) async throws -> String { try change(&model) }
            func withVersions(_ body: (inout VersionState) throws -> String) async throws -> String {
                var state = VersionState(model: model, named: NamedVersions())
                defer { model = state.model }
                return try body(&state)
            }
        }
        let host = Host()
        func post(_ json: String, origin: String? = nil) async throws -> String {
            let head = "POST /mcp HTTP/1.1\r\nContent-Length: \(json.utf8.count)\r\n" + (origin.map { "Origin: \($0)\r\n" } ?? "")
            let request = try #require(MCP.Request(Data((head + "\r\n" + json).utf8)))
            return String(decoding: await MCP.response(to: request, host: host), as: UTF8.self)
        }
        // Not whole yet: the body is still to come.
        #expect(MCP.Request(Data("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8)) == nil)
        let created = try await post(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_tables","arguments":{"tables":[{"name":"users","columns":[{"name":"id","type":"uuid","primary_key":true}]}]}}}"#)
        #expect(created.hasPrefix("HTTP/1.1 200 OK"))
        #expect(host.model.tables.map(\.name) == ["users"])
        #expect(try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_models"}}"#).contains("library: list_models"))
        #expect(try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).hasPrefix("HTTP/1.1 202"))
        #expect(try await post("{}", origin: "https://evil.example").hasPrefix("HTTP/1.1 403"))
    }

    @Test func assistantsAreToldHowToReviewSchemaChanges() async throws {
        func result(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
            let reply = try #require(await MCP.reply(to: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params], host: MCPServer.shared))
            return try #require(reply["result"] as? [String: Any])
        }
        let initialized = try await result("initialize")
        #expect((initialized["capabilities"] as? [String: Any])?["prompts"] != nil)
        #expect((initialized["instructions"] as? String)?.contains("save_version") == true)
        let tools = try #require(try await result("tools/list")["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        #expect(Set(VersionTools.names).isSubset(of: names))
        #expect(!names.contains("mark_baseline") && !names.contains("get_changes"))
        #expect((tools.first { $0["name"] as? String == "start_review" }?["description"] as? String)?.contains("save_version") == true)
        let prompts = try #require(try await result("prompts/list")["prompts"] as? [[String: Any]])
        #expect(prompts.map { $0["name"] as? String } == ["review_schema_changes"])
        let prompt = try await result("prompts/get", ["name": "review_schema_changes", "arguments": ["change": "PR 482"]])
        let messages = try #require(prompt["messages"] as? [[String: Any]])
        let text = try #require((messages.first?["content"] as? [String: Any])?["text"] as? String)
        // Every step, in order.
        let steps = ["PR 482", "start_review", "create_tables", "arrange", "save_version", "alter_table", "compare", "list_versions"]
        let positions = steps.map { text.range(of: $0)?.lowerBound }
        #expect(!positions.contains(nil) && positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
    }

    @Test func aReviewReportsItsChangesInWords() throws {
        var before = DataModel()
        _ = try ModelTools.call("create_tables", ["tables": [
            ["name": "orders", "columns": [["name": "id", "type": "uuid", "primary_key": true], ["name": "total", "type": "integer"]]],
        ]], on: &before)
        var after = before
        _ = try ModelTools.call("alter_table", ["table": "orders", "change_columns": [["name": "total", "type": "numeric", "rename_to": "amount"]],
                                                "add_columns": [["name": "note", "type": "text?"]]], on: &after)
        _ = try ModelTools.call("create_tables", ["tables": [["name": "refunds", "columns": [["name": "order_id", "type": "uuid", "references": "orders"]]]]], on: &after)
        let report = SchemaDiff(from: before, to: after).report(from: "main", to: "current")
        #expect(report.hasPrefix("main → current: "))
        #expect(report.contains("- refunds: order_id uuid"))
        #expect(report.contains("  ~ total integer → amount numeric"))
        #expect(report.contains("  + note text nullable"))
        #expect(report.contains("- refunds.order_id → orders.id"))
        #expect(SchemaDiff(from: before, to: before).report(from: "main", to: "current") == "No changes from main to current.")
    }

    /// A pull request reviewed, then updated: main, the first draft and now, each compared with the others.
    @Test func namedVersionsCompareAnyTwo() throws {
        var state = VersionState(model: DataModel(), named: NamedVersions())
        func call(_ name: String, _ arguments: [String: Any] = [:]) throws -> String { try VersionTools.call(name, arguments, on: &state) }
        func edit(_ name: String, _ arguments: [String: Any]) throws { _ = try ModelTools.call(name, arguments, on: &state.model) }

        #expect(throws: ModelTools.Failure.self) { try call("save_version", ["name": "main"]) }  // Nothing to save yet.
        try edit("create_tables", ["tables": [
            ["name": "orders", "columns": [["name": "id", "type": "uuid", "primary_key": true], ["name": "total", "type": "integer"]]],
        ]])
        _ = try call("save_version", ["name": "main"])
        try edit("alter_table", ["table": "orders", "change_columns": [["name": "total", "rename_to": "amount"]]])
        _ = try call("save_version", ["name": "Draft 1"])
        try edit("create_tables", ["tables": [["name": "refunds", "columns": [["name": "order_id", "type": "uuid", "references": "orders"]]]]])

        // Across a draft, the rename is still a rename, not a column dropped and another added.
        let whole = try call("compare", ["from": "MAIN", "to": "current"])
        #expect(whole.hasPrefix("main → current: 1 table added, 1 column changed"))
        #expect(whole.contains("~ total integer → amount integer"))
        #expect(state.named.comparison == .init(from: "main", to: "current"))
        #expect(try call("compare", ["from": "main", "to": "draft 1"]).hasPrefix("main → Draft 1: 1 column changed"))
        #expect(try call("compare", ["from": "draft 1", "to": "current"]).hasPrefix("Draft 1 → current: 1 table added, 1 key added"))

        let listed = try call("list_versions")
        #expect(listed.contains("- main: saved"))
        #expect(listed.contains("- Draft 1: saved") && listed.contains("from main: 1 column changed"))
        #expect(listed.contains("since Draft 1, 1 table added"))

        // Mistakes say what there is.
        let unknown = #expect(throws: ModelTools.Failure.self) { try call("compare", ["from": "draft 2", "to": "current"]) }
        #expect(unknown?.message == "There's no version called “draft 2”. Versions, oldest first: main, Draft 1.")
        #expect(throws: ModelTools.Failure.self) { try call("save_version", ["name": "main"]) }
        #expect(throws: ModelTools.Failure.self) { try call("save_version", ["name": "Current"]) }

        // Restoring would lose refunds, saved in no version, unless told to.
        #expect(throws: ModelTools.Failure.self) { try call("restore_version", ["name": "main"]) }
        _ = try call("save_version", ["name": "draft 2"])
        #expect(try call("list_versions").contains("current (the data model as it is now): the same as draft 2."))
        _ = try call("restore_version", ["name": "main"])
        #expect(state.model.tables.map(\.name) == ["orders"])
        #expect(try call("get_model", ["version": "draft 2"]).contains("refunds"))

        _ = try call("compare", ["from": "main", "to": "current"])
        _ = try call("delete_version", ["name": "main"])
        #expect(state.named.names == ["Draft 1", "draft 2"])
        #expect(state.named.comparison == nil, "it compared with main")
    }

    // MARK: Replication and undo

    private func exampleModels() throws -> [DataModel] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "joinery", subdirectory: nil) ?? []
        #expect(urls.count >= 5)
        return try urls.map { try DataModel(contentsOf: $0) }
    }

    @Test func everyExampleSurvivesBeingMadeEntitiesAndBack() throws {
        for model in try exampleModels() {
            #expect(Replica(model).model == model)
            // Its ops, as sent: through JSON and back.
            let ops = Replica().ops(to: Replica(model))
            let decoded = try JSONDecoder().decode([Replica.Op].self, from: JSONEncoder().encode(ops))
            var copy = Replica()
            _ = copy.apply(decoded)
            #expect(copy.model == model)
        }
    }

    @Test func orderKeysAlwaysFitBetween() {
        var keys = ["", "a", "a1", "az", "b", "zz", "zzz"]
        for (low, high) in zip(keys, keys.dropFirst()) {
            let key = OrderKey.between(low, high)
            #expect(low < key && key < high && OrderKey.isValid(key))
        }
        #expect(OrderKey.between("zzz", nil) > "zzz")
        // Inserting at the same place over and over stays in order.
        keys = ["a", "b"]
        for _ in 0..<200 { keys.insert(OrderKey.between(keys[0], keys[1]), at: 1) }
        #expect(keys == keys.sorted() && Set(keys).count == keys.count)
        let spread = OrderKey.spread(1000, after: "", before: nil)
        #expect(spread == spread.sorted() && Set(spread).count == 1000 && spread.allSatisfy { $0.count <= 3 })
    }

    @Test func reorderingMovesOnlyWhatMoved() throws {
        var model = try #require(try exampleModels().first { $0.tables.count > 5 })
        let before = Replica(model)
        let moved = model.tables.remove(at: 0)
        model.tables.insert(moved, at: 3)
        let ops = before.ops(to: Replica(model, keeping: before))
        #expect(ops == [.set(id: moved.id.uuidString, field: "order", value: Replica(model, keeping: before).entities[moved.id.uuidString]!["order"]!)])
    }

    @Test func undoingOneChangeLeavesSomeoneElsesAlone() throws {
        var model = try #require(try exampleModels().first)
        var replica = Replica(model)
        let table = model.tables[0].id
        // Mine: renamed.
        model.tables[0].name = "renamed"
        let mine = replica.apply(replica.ops(to: Replica(model, keeping: replica)))
        // Theirs, after: moved, and a column added.
        model.tables[0].position.x += 100
        _ = model.addColumn(to: table, after: nil)
        _ = replica.apply(replica.ops(to: Replica(model, keeping: replica)))
        // Undoing mine puts the name back and nothing else.
        _ = replica.apply(mine)
        let table0 = try #require(replica.model.table(table))
        let original = try #require(try exampleModels().first?.table(table))
        #expect(table0.name == original.name && table0.position.x == original.position.x + 100 && table0.columns.count == original.columns.count + 1)
    }

    /// Repeatable random numbers, so a failure can be replayed.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state ^ (state >> 33)
        }
    }

    /// A random edit, of the kinds the canvas, designer and assistants make.
    private func randomEdit(_ model: inout DataModel, _ random: inout Seeded) {
        guard let table = model.tables.randomElement(using: &random) else { _ = model.addTable(at: .zero); return }
        let column = table.columns.randomElement(using: &random)
        let other = model.tables.randomElement(using: &random)!
        switch Int.random(in: 0..<15, using: &random) {
        case 0: model.tables[model.tables.firstIndex { $0.id == table.id }!].name += "_x"
        case 1: _ = model.addColumn(to: table.id, after: column?.id)
        case 2: if let column { model.removeColumn(column.id) }
        case 3: model.removeTable(table.id)
        case 4: model.move(tables: [table.id, other.id], ties: [], by: CGPoint(x: 40, y: -12))
        case 5: if let column, let target = other.columns.first { _ = model.connect(column.id, to: target.id) }
        case 6: if let wire = model.relationships.randomElement(using: &random) { model.removeRelationships { $0.id == wire.id } }
        case 7: if let column { model.moveColumn(column.id, in: table.id, to: 0) }
        case 8: _ = model.group([table.id, other.id])
        case 9: model.recolor(tables: [table.id], groups: [], .allCases.randomElement(using: &random)!)
        case 10: _ = model.addTable(at: CGPoint(x: 900, y: 900))
        case 11:
            if let column, let index = model.tables.firstIndex(where: { $0.id == table.id }), let row = model.tables[index].columns.firstIndex(where: { $0.id == column.id }) {
                model.tables[index].columns[row].type = .allCases.randomElement(using: &random)!
                model.tables[index].columns[row].isNullable.toggle()
            }
        case 12: model.arrange(.hierarchical)
        case 13:
            if let wire = model.relationships.randomElement(using: &random) {
                _ = model.addBendPoint(on: wire.id, at: CGPoint(x: 300, y: 300), direction: CGPoint(x: 1, y: 0), segment: 0)
            }
        default:
            let index = model.tables.firstIndex { $0.id == table.id }!
            model.tables[index].notes += "note "
            if let column { model.tables[index].setSample(0, column.id, to: "v") }
        }
    }

    @Test(arguments: [1, 2, 3, 4, 5] as [UInt64])
    func undoAndRedoGoBackExactly(seed: UInt64) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let example = try #require(Bundle.main.urls(forResourcesWithExtension: "joinery", subdirectory: nil)?.first { $0.lastPathComponent == "Storefront.joinery" })
        let url = folder.appending(path: "Storefront.joinery")
        try FileManager.default.copyItem(at: example, to: url)
        let open = try OpenModel(url: url)
        let undo = open.undoManager
        undo.groupsByEvent = false

        var random = Seeded(state: seed)
        var states = [open.model]
        for _ in 0..<150 {
            var model = open.model
            randomEdit(&model, &random)
            // An edit that changes nothing leaves nothing to undo, as in the app.
            guard model != open.model else { continue }
            // As made, with any type changed carried along its foreign keys.
            var expected = model
            expected.carryTypes(from: open.model)
            undo.beginUndoGrouping()
            open.change(to: model)
            undo.endUndoGrouping()
            #expect(open.model == expected)
            states.append(open.model)
        }
        // Back through every state, then forward through them all again.
        for state in states.reversed().dropFirst() {
            undo.undo()
            #expect(open.model == state)
        }
        #expect(!undo.canUndo)
        for state in states.dropFirst() {
            undo.redo()
            #expect(open.model == state)
        }
        #expect(!undo.canRedo)
    }

    // MARK: Sessions

    /// A model file of Storefront in a folder of its own, opened.
    private func openStorefront() throws -> OpenModel {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let example = try #require(Bundle.main.urls(forResourcesWithExtension: "joinery", subdirectory: nil)?.first { $0.lastPathComponent == "Storefront.joinery" })
        let url = folder.appending(path: "Storefront.joinery")
        try FileManager.default.copyItem(at: example, to: url)
        return try OpenModel(url: url)
    }

    /// Waits up to a few seconds for `condition`.
    private func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    /// Storefront, or `model`, shared through a relay of its own.
    private func hosting(_ model: DataModel? = nil) async throws -> (model: OpenModel, host: SessionHost, relay: TestRelay) {
        let relay = try await TestRelay.started()
        let open = try openStorefront()
        if let model { open.change(to: model) }
        let host = SessionHost(model: open, relay: relay.address)
        open.session = host
        try await until { host.links != nil }
        return (open, host, relay)
    }

    /// A guest joined to `host` with its edit link (or `link`), with an undo manager of its own (which the model holds
    /// weakly, as the window's).
    private func joining(_ host: SessionHost, link: String? = nil) async throws -> (client: SessionClient, model: OpenModel, undo: UndoManager) {
        var opened: OpenModel?
        let client = try #require(SessionClient(link: link ?? host.links?.edit ?? "") { _, _ in opened = try? self.openStorefront() })
        try await until { opened != nil }
        let model = try #require(opened)
        let undo = model.undoManager
        undo.groupsByEvent = false
        client.attach(to: model)
        return (client, model, undo)
    }

    /// A change made as the canvas makes one: undoable on its own.
    private func edit(_ open: OpenModel, _ change: (inout DataModel) -> Void) {
        var model = open.model
        change(&model)
        open.undoManager.beginUndoGrouping()
        open.change(to: model)
        open.undoManager.endUndoGrouping()
    }

    @Test func aJoinedCopyStaysTheSameAsTheHosts() async throws {
        let (hosted, host, relay) = try await hosting()
        defer { host.close(); relay.stop() }
        let links = try #require(host.links)

        // A link with the wrong secret is turned away.
        var link = try #require(Relay.Link(links.edit))
        link.secret = "wrong"
        var strangerJoined = false
        let stranger = try #require(SessionClient(link: link.text) { _, _ in strangerJoined = true })
        try await until { stranger.status.contains("link") }
        #expect(!strangerJoined && host.peers.isEmpty)

        // The window redraws as people come and go: who's here is observed, through any session.
        final class Flag: @unchecked Sendable { var isSet = false }
        let noticed = Flag()
        withObservationTracking { _ = (host as any Session).peers } onChange: { noticed.isSet = true }

        var title = ""
        var joined: OpenModel?
        let client = try #require(SessionClient(link: links.edit) { name, _ in
            title = name
            // Joining makes a file of the host's copy and opens it; any file will do, as it takes the host's copy on.
            joined = try? self.openStorefront()
        })
        try await until { joined != nil }
        let guest = try #require(joined)
        client.attach(to: guest)
        #expect(title == "Storefront" && guest.model == hosted.model)
        try await until { host.peers.count == 1 }
        #expect(noticed.isSet)

        // The guest's change reaches the host, and the host's the guest.
        var model = guest.model
        model.tables[0].name = "from_guest"
        _ = model.addColumn(to: model.tables[1].id, after: nil)
        guest.change(to: model)
        try await until { hosted.model == guest.model }
        model = hosted.model
        model.tables[2].position.x += 200
        model.removeTable(model.tables[3].id)
        hosted.change(to: model)
        try await until { guest.model == hosted.model }
        #expect(guest.model.tables.contains { $0.name == "from_guest" } && guest.model.tables.count == hosted.model.tables.count)

        // Presence reaches the host.
        client.share(Relay.Presence(cursor: CGPoint(x: 12, y: 34), selection: [hosted.model.tables[0].id], drag: nil))
        try await until { host.peers.values.first?.cursor == [12, 34] }
        client.close()
        try await until { host.peers.isEmpty }
    }

    @Test func aViewLinkWatchesAndCantEdit() async throws {
        let (hosted, host, relay) = try await hosting()
        defer { host.close(); relay.stop() }
        let (client, viewer, _) = try await joining(host, link: host.links?.view)
        #expect(!client.canEdit)
        var refusal: String?
        client.onRefusal = { refusal = $0 }
        let name = hosted.model.tables[0].name
        edit(viewer) { $0.tables[0].name = "not allowed" }
        // Taken back at once, and never sent.
        try await until { viewer.model.tables[0].name == name && refusal != nil }
        edit(hosted) { $0.tables[0].name = "from_host" }
        try await until { viewer.model == hosted.model }
    }

    /// The host checks every change whole: one bad op turns it all down, and the document's untouched.
    @Test func aChangeWithAnyBadOpIsTurnedDownWhole() throws {
        let start = Replica(try openStorefront().model)
        let host = RelayHostCore(start, title: "t", name: "Host")
        _ = host.connected(at: .now)
        let welcome = Relay.Welcome(peer: 1, room: "r", limits: Relay.Limits(), latest: 0, version: 1, title: [], peers: [:])
        _ = host.received(welcome.frame.bytes, at: .now)
        let table = try #require(start.entities.values.first { $0["kind"] == .string("table") }?["id"]?.string)
        let rename = Replica.Op.set(id: table, field: "name", value: .string("renamed"))
        let bad: [Replica.Op] = [
            .set(id: UUID().uuidString, field: "name", value: .string("x")),  // not there
            .set(id: table, field: "kind", value: .string("column")),  // can't change kind
            .set(id: table, field: "position", value: .string("here")),  // unreadable
            .set(id: table, field: "order", value: .string("0")),  // a bad order key
            .put(["id": .string(UUID().uuidString), "kind": .string("nonsense")]),
            .put(["id": .string(UUID().uuidString), "kind": .string("column"), "table": .string(UUID().uuidString), "name": .string("c"), "type": .string("text")]),
            .delete(id: UUID().uuidString),
        ]
        func change(_ cseq: Int, _ ops: [Replica.Op]) throws -> Wire.Frame {
            let frame = Wire.stamp(Wire.Frame(.change, seq: UInt64(cseq), sealing: Wire.encode(ops), with: host.key).bytes, peer: 2)
            let sent = host.received(frame, at: .now).compactMap { effect -> Wire.Frame? in
                if case .send(let bytes) = effect { try? Wire.Frame(bytes) } else { nil }
            }
            return try #require(sent.first)
        }
        for (index, op) in bad.enumerated() {
            let answer = try change(index + 1, [rename, op])
            #expect(answer.header.kind == .reject, "\(op)")
            #expect(try Relay.Decision(try answer.opened(with: host.key)).cseq == UInt64(index + 1))
            #expect(host.document.replica == start, "\(op)")
        }
        // A good one goes through, numbered, back to its author too.
        let made = try change(bad.count + 1, [rename])
        let decision = try Relay.Decision(try made.opened(with: host.key))
        #expect(made.header.kind == .ops && decision.author == 2 && decision.cseq == UInt64(bad.count + 1))
    }

    @Test func everyoneEndsUpTheSameWhateverTheyDoAtOnce() async throws {
        let (hosted, host, relay) = try await hosting()
        defer { host.close(); relay.stop() }
        let (_, a, _) = try await joining(host)
        let (_, b, _) = try await joining(host)
        let table = hosted.model.tables[0].id
        // Both add a column at the end of one table, and both rename another, at once.
        edit(a) { _ = $0.addColumn(to: table, after: $0.table(table)?.columns.last?.id) }
        edit(b) { _ = $0.addColumn(to: table, after: $0.table(table)?.columns.last?.id) }
        edit(a) { $0.tables[1].name = "from_a" }
        edit(b) { $0.tables[1].name = "from_b" }
        edit(hosted) { $0.tables[2].position.y += 50 }
        // The entities, not only the model drawn from them: order keys too.
        try await until { a.replica == hosted.replica && b.replica == hosted.replica }
        let columns = try #require(hosted.model.table(table)).columns.count
        #expect(columns == (try openStorefront().model.table(table)?.columns.count ?? 0) + 2)
        #expect(["from_a", "from_b"].contains(hosted.model.tables[1].name))
    }

    @Test func aTurnedDownChangeIsTakenBackAndLaterOnesStay() async throws {
        let (hosted, host, relay) = try await hosting()
        defer { host.close(); relay.stop() }
        let (_, guest, _) = try await joining(host)
        let doomed = hosted.model.tables[0].id, other = hosted.model.tables[1].id
        edit(hosted) { $0.removeTable(doomed) }
        // Sent before the guest hears of it: a rename of the table now gone, then a move of another.
        edit(guest) { $0.tables[$0.tables.firstIndex { $0.id == doomed }!].name = "gone" }
        edit(guest) { $0.tables[$0.tables.firstIndex { $0.id == other }!].position.x += 77 }
        try await until { guest.model == hosted.model }
        #expect(guest.model.table(doomed) == nil)
        #expect(hosted.model.table(other)?.position.x == (try openStorefront().model.table(other)?.position.x ?? 0) + 77)
    }

    @Test func undoInASessionUndoesOnlyYourOwn() async throws {
        let (hosted, host, relay) = try await hosting()
        defer { host.close(); relay.stop() }
        let (_, guest, undo) = try await joining(host)
        let id = hosted.model.tables[0].id
        let original = try #require(hosted.model.table(id))
        edit(guest) { $0.tables[0].name = "guest_name" }
        try await until { hosted.model.table(id)?.name == "guest_name" }
        edit(hosted) { $0.tables[0].position.x += 100 }
        try await until { guest.model.table(id)?.position.x == original.position.x + 100 }
        undo.undo()
        try await until { hosted.model.table(id)?.name == original.name }
        #expect(hosted.model.table(id)?.position.x == original.position.x + 100)
        try await until { guest.model == hosted.model }
        undo.redo()
        try await until { hosted.model.table(id)?.name == "guest_name" && guest.model == hosted.model }
    }

    @Test func presenceShowsWhoIsHereAndWhere() async throws {
        let (hosted, host, relay) = try await hosting()
        defer { host.close(); relay.stop() }
        let (a, _, _) = try await joining(host)
        let (b, _, _) = try await joining(host)
        let hostID = String(Relay.hostPeer)
        // B was told of the host and A on joining; A hears of B.
        #expect(b.peers.count == 2 && b.peers[hostID] != nil)
        try await until { a.peers.count == 2 }
        // Everyone's color is their own, and the same to everyone.
        #expect(Set(b.peers.values.map(\.color)).count == 2 && a.peers[hostID]?.color == "blue")
        let table = hosted.model.tables[0].id
        a.share(Relay.Presence(cursor: CGPoint(x: 10, y: 20), selection: [table], drag: nil))
        try await until { b.peers.values.contains { $0.cursor == [10, 20] && $0.selection == [table.uuidString] } }
        #expect(host.peers.values.contains { $0.cursor == [10, 20] })
        // The host's own pointer too.
        host.share(Relay.Presence(cursor: CGPoint(x: 5, y: 6), selection: [], drag: nil))
        try await until { a.peers[hostID]?.cursor == [5, 6] && b.peers[hostID]?.cursor == [5, 6] }
        // Dragging: how far, before it's a change.
        a.share(Relay.Presence(cursor: CGPoint(x: 30, y: 40), selection: [table], drag: CGPoint(x: 20, y: 20)))
        try await until { b.peers.values.contains { $0.drag == [20, 20] } }
        // Selecting with a rectangle: the rectangle.
        a.share(Relay.Presence(cursor: CGPoint(x: 30, y: 40), selection: [], marquee: CGRect(x: 1, y: 2, width: 29, height: 38)))
        try await until { b.peers.values.contains { $0.marquee == [1, 2, 29, 38] } }
        // Off the canvas: no pointer.
        a.share(Relay.Presence(cursor: nil, selection: [], drag: nil))
        try await until { b.peers.values.contains { $0.id != hostID && $0.cursor == nil && $0.selection == [] && $0.drag == nil } }
        // Leaving: gone for everyone.
        a.close()
        try await until { host.peers.count == 1 && b.peers.count == 1 }
    }

    /// Others' drags move tables as a drag here does, and one let go of keeps showing until its change lands.
    @Test func othersDragsShowAsTheyreMade() {
        let canvas = CanvasController()
        let table = UUID()
        var peer = Peer(id: "2", name: "Ann", color: "purple", selection: [table.uuidString], drag: [30, 40])
        canvas.showDrags(of: [peer])
        #expect(canvas.tableOffsets[table] == CGPoint(x: 30, y: 40))
        peer.drag = nil
        canvas.showDrags(of: [peer])
        #expect(canvas.tableOffsets[table] == CGPoint(x: 30, y: 40))
        canvas.dragsLanded()
        #expect(canvas.tableOffsets[table] == nil)
    }

    @Test func whenTheHostStopsGuestsKeepTheirCopy() async throws {
        let (hosted, host, relay) = try await hosting()
        defer { relay.stop() }
        let (client, guest, _) = try await joining(host)
        edit(hosted) { $0.tables[0].name = "last" }
        try await until { guest.model == hosted.model }
        host.close()
        try await until { guest.session == nil }
        #expect(client.status.contains("stopped") && guest.model.tables[0].name == "last")
        // Theirs to edit, alone.
        edit(guest) { $0.tables[0].name = "mine" }
        #expect(guest.model.tables[0].name == "mine" && hosted.model.tables[0].name == "last")
    }

    @Test func bigModelsTravelWhole() async throws {
        let big = DataModel.synthetic(tables: 400, foreignKeys: 600, groups: 10)
        let (hosted, host, relay) = try await hosting(big)
        defer { host.close(); relay.stop() }
        let (_, guest, _) = try await joining(host)
        #expect(guest.model == hosted.model && guest.model.tables.count == 400)
        edit(hosted) { $0.arrange(.hierarchical) }
        try await until { guest.model == hosted.model }
    }

    @Test func linksSayWhereAndWithWhat() throws {
        let key = SymmetricKey(size: .bits256)
        for canEdit in [true, false] {
            let link = Relay.Link(relay: URL(string: "https://relay.example.com")!, room: "abc", key: key, secret: "s3cret", canEdit: canEdit)
            #expect(link.text.hasPrefix("https://relay.example.com/r/abc#key="))
            #expect(link.text.hasSuffix(canEdit ? "&token=s3cret" : "&view=s3cret"))
            #expect(Relay.Link(link.text) == link && Relay.Link("  \(link.text)\n") == link)
            #expect(link.socket.absoluteString == "wss://relay.example.com/")
        }
        let local = Relay.Link(relay: URL(string: "http://localhost:8787/")!, room: "r", key: key, secret: "s", canEdit: true)
        #expect(local.text.hasPrefix("http://localhost:8787/r/r#") && local.socket.absoluteString == "ws://localhost:8787/")
        let good = local.text
        for bad in [
            "not a link", "ftp://x/r/r#key=k&token=t", good.replacingOccurrences(of: "/r/r", with: "/x/r"),
            good.replacingOccurrences(of: "token=s", with: "token="), String(good.prefix { $0 != "#" }),
            good.replacingOccurrences(of: "key=", with: "key=AAAA"),
        ] {
            #expect(Relay.Link(bad) == nil, "\(bad)")
        }
    }

    /// Digests are only comparable if every language writes an entity's JSON alike: these are what JavaScript's
    /// JSON.stringify writes.
    @Test func canonicalJSONIsWhatJavaScriptWrites() {
        let numbers: [(Double, String)] = [
            (0, "0"), (-0.0, "0"), (24, "24"), (-3, "-3"), (1.5, "1.5"), (0.1, "0.1"), (0.30000000000000004, "0.30000000000000004"),
            (123.456, "123.456"), (0.000001, "0.000001"), (0.0000001, "1e-7"), (1e20, "100000000000000000000"), (1e21, "1e+21"),
            (123456789012, "123456789012"), (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"), (-2.5e-8, "-2.5e-8"),
            (.nan, "null"), (.infinity, "null"),
        ]
        for (number, written) in numbers { #expect(JSON.number(number).canonical == written, "\(number)") }
        #expect(JSON.string("a\"b\\c\n\t\u{1}é/😀").canonical == #""a\"b\\c\n\t\u0001é/😀""#)
        let object = JSON.object(["b": .array([.bool(true), .null]), "a": .number(1), "B": .string("x")])
        #expect(object.canonical == #"{"B":"x","a":1,"b":[true,null]}"#)
        // The digest of a document is the same however it's put together, and an op swaps only what it changes.
        var replica = CheckedReplica(Replica())
        let table: Replica.Entity = ["id": .string("T"), "kind": .string("table"), "name": .string("t")]
        replica.apply([.put(table), .set(id: "T", field: "name", value: .string("u"))])
        #expect(replica.digest == Digest(replica.replica.entities.values))
        replica.apply([.delete(id: "T")])
        #expect(replica.digest == Digest() && replica.digest.description == "0000000000000000")
    }
}


// MARK: Indexes

extension JoineryTests {
    /// `orders` from `storefront()`, with three more columns to index.
    private func indexedOrders() -> DataModel {
        var model = storefront()
        model.tables[1].columns += [Column(name: "status", type: .text), Column(name: "total", type: .numeric),
                                    Column(name: "placed_at", type: .timestamp)]
        return model
    }

    @Test func indexesKeepTwoOrMoreColumnsAndGoWithTheirColumns() throws {
        var model = indexedOrders()
        let columns = model.tables[1].columns.map(\.id)  // id, user_id, status, total, placed_at
        model.tables[1].addIndex(on: [columns[1], columns[4]])
        let triple = model.tables[1].addIndex(on: [columns[1], columns[2]], isUnique: false)
        model.tables[1].add(columns[4], toIndex: triple)
        model.tables[1].add(columns[4], toIndex: triple)  // Already in it: not twice.
        #expect(model.tables[1].indexes.first { $0.id == triple }?.columns == [columns[1], columns[2], columns[4]])
        // Each in a color of its own.
        #expect(Set(model.tables[1].indexes.map(\.color)).count == 2)
        #expect(model.tables[1].name(of: model.tables[1].indexes[0]) == "orders_user_id_placed_at_key")
        #expect(model.tables[1].name(of: model.tables[1].indexes[1]) == "orders_user_id_status_placed_at_idx")

        // Dropping placed_at leaves the pair on user_id alone, and the triple with its other two; dropping user_id
        // leaves the pair with none, so it goes.
        model.removeColumn(columns[4])
        #expect(model.tables[1].indexes.map(\.columns) == [[columns[1]], [columns[1], columns[2]]])
        model.removeColumn(columns[1])
        #expect(model.tables[1].indexes.map(\.id) == [triple] && model.tables[1].indexes[0].columns == [columns[2]])

        // A file from before indexes reads as having none; one with them reads them back.
        let older = try JSONDecoder().decode(Table.self, from: Data(#"{"id": "6A2D0F0E-3B8B-4C47-9E5A-1F2E3D4C5B6A", "name": "t", "position": [0, 0], "color": "blue"}"#.utf8))
        #expect(older.indexes.isEmpty)
        let again = try JSONDecoder().decode(Table.self, from: JSONEncoder().encode(model.tables[1]))
        #expect(again.indexes == model.tables[1].indexes)
    }

    @Test func indexCablesNestShortestNearestAndFanOutAtSharedSockets() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let y: [Column.ID: CGFloat] = [a: 0, b: 30, c: 60, d: 90]
        let long = TableIndex(columns: [a, d], color: .blue), short = TableIndex(columns: [b, c], color: .red),
            middle = TableIndex(columns: [a, c], color: .green)
        let layout = CableLayout(indexes: [long, short, middle], socketY: y)
        #expect(layout.lanes == [short.id: 0, middle.id: 1, long.id: 2])
        // Lanes step out to the left of the sockets.
        #expect(CableLayout.laneX(1, socketX: 100) < CableLayout.laneX(0, socketX: 100))
        // Two cables meet a: apart, centered on it, the nearer lane above.
        let offsets = layout.offsets([long, short, middle])
        #expect(offsets[middle.id]?[a] == -CableLayout.fan / 2 && offsets[long.id]?[a] == CableLayout.fan / 2)
        #expect(offsets[short.id]?[b] == 0)
        // A cable reaches from its lane to its sockets' edges, its turns rounded rather than square.
        let path = CableLayout.path(through: [CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 45), CGPoint(x: 100, y: 90)], laneX: 70)
        let bounds = path.boundingRect
        #expect(bounds.minX == 70 && bounds.maxX == 100 - CableLayout.socketDiameter / 2)
        #expect(bounds.minY == 0 && bounds.maxY == 90)
        #expect(!path.contains(CGPoint(x: 70, y: 0.5)), "the top corner is rounded off")
    }

    @Test func indexesExportAsSQLAndComeFromAssistants() throws {
        var model = indexedOrders()
        _ = try ModelTools.call("alter_table", ["table": "orders", "add_indexes": [
            ["columns": ["user_id", "placed_at"]],
            ["columns": ["status", "total"], "unique": false, "name": "orders_by_status"],
        ]], on: &model)
        #expect(model.tables[1].indexes.count == 2)
        #expect(throws: ModelTools.Failure.self) {
            try ModelTools.call("alter_table", ["table": "orders", "add_indexes": [["columns": ["status", "status"]]]], on: &model)
        }
        // On one column, too.
        _ = try ModelTools.call("alter_table", ["table": "orders", "add_indexes": [["columns": ["placed_at"], "unique": false]]], on: &model)
        #expect(model.markdown(of: [model.tables[1].id], title: "Shop").contains("CREATE INDEX orders_placed_at_idx ON orders (placed_at);"))
        _ = try ModelTools.call("alter_table", ["table": "orders", "drop_indexes": ["orders_placed_at_idx"]], on: &model)
        #expect(throws: ModelTools.Failure.self) {
            try ModelTools.call("alter_table", ["table": "orders", "add_indexes": [["columns": []]]], on: &model)
        }
        let described = try ModelTools.describe(model)
        #expect(described.contains("orders_user_id_placed_at_key") && described.contains("orders_by_status"))

        let markdown = model.markdown(of: [model.tables[1].id], title: "Shop")
        #expect(markdown.contains("  CONSTRAINT orders_user_id_placed_at_key UNIQUE (user_id, placed_at)\n);"))
        #expect(markdown.contains("CREATE INDEX orders_by_status ON orders (status, total);"))

        _ = try ModelTools.call("alter_table", ["table": "orders", "drop_indexes": ["orders_by_status"]], on: &model)
        #expect(model.tables[1].indexes.count == 1)
    }
}


// MARK: Tab dragging

extension JoineryTests {
    @Test func aDraggedTabIsPulledBackPastTheGroupAndFindsItsSlot() {
        // Inside the group, as it is; past it, pulled back, more the further, never past the reach.
        #expect(TabDrag.rubberBand(50, in: 0...100, reach: 24) == 50)
        let near = TabDrag.rubberBand(110, in: 0...100, reach: 24), far = TabDrag.rubberBand(400, in: 0...100, reach: 24)
        #expect(near > 100 && near < 110)
        #expect(far > near && far < 124)
        #expect(TabDrag.rubberBand(-10, in: 0...100, reach: 24) == 100 - TabDrag.rubberBand(110, in: 0...100, reach: 24))
        // Up and down, held to the row.
        #expect(abs(TabDrag.rubberBand(1000, in: 0...0, reach: 12)) < 12)
        // Its slot is the one its middle is over, within the group.
        #expect(TabDrag.slot(forCenter: 50, width: 200, count: 3) == 0)
        #expect(TabDrag.slot(forCenter: 250, width: 200, count: 3) == 1)
        #expect(TabDrag.slot(forCenter: 900, width: 200, count: 3) == 2)
        #expect(TabDrag.slot(forCenter: -40, width: 200, count: 3) == 0)
    }
}
