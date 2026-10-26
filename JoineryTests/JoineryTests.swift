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
        for wire in wires { #expect(routing.routes[wire]?.points.last == port.point) }
        let bus = try #require(routing.routes[id])
        #expect(bus.points.first == port.point)
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

        // Once users joins the group, there's nothing outside to stand for.
        model.tables[0].group = group
        model.repair()
        #expect(model.groups[0].ports.isEmpty)
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
}
