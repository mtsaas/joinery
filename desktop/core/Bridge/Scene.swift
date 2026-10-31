import Foundation

/// What the canvas draws, worked out here so the desktop app draws what the Mac's does: `scene` when the model changes,
/// `frame` every animation frame while wires move.
final class Scene {
    private var routing: Routing?
    private var inputs: (model: DataModel, tables: [Table.ID: CGPoint], ties: [ZipTie.ID: CGPoint], avoiding: Bool)?
    private let simulation = WireSimulation()
    private let portShapes = PortShapes()

    /// The model as drawn. Comparing (a version picked in the history, or a review), it's the earlier model, the later
    /// one, or the later with what's been removed put back and the changes marked, as `App.side` says.
    static func drawn(_ workspace: Workspace) -> (model: DataModel, diff: SchemaDiff?) {
        let after = App.preview.map { $0.after ?? workspace.model } ?? workspace.model
        guard let before = App.preview?.before ?? workspace.baseline else { return (after, nil) }
        switch App.side {
        case "then": return (before, nil)
        case "now": return (after, nil)
        default:
            let diff = SchemaDiff(from: before, to: after)
            return (diff.model, diff)
        }
    }

    /// Tables, columns and groups, with their frames, colors and changes.
    static func scene(_ workspace: Workspace) -> [String: Any] {
        let (model, diff) = drawn(workspace)
        let locations = model.columnLocations
        // A foreign key's column shows the color of the table it references.
        var references: [Column.ID: String] = [:]
        for relationship in model.relationships { references[relationship.from] = locations[relationship.to]?.table.color.rawValue }
        let tables: [[String: Any]] = model.tables.map { table in
            let frame = Metrics.frame(of: table)
            return [
                "id": table.id.uuidString, "name": table.name, "color": table.color.rawValue,
                "frame": rect(frame), "group": table.group?.uuidString ?? NSNull(), "notes": table.notes,
                "change": diff?.tables[table.id].map(name) ?? NSNull(),
                "formerName": diff?.oldNames[table.id] ?? NSNull(),
                "samples": table.samples.count,
                "columns": table.columns.map { column in [
                    "id": column.id.uuidString, "name": column.name, "type": column.type.rawValue,
                    "primaryKey": column.isPrimaryKey, "nullable": column.isNullable, "unique": column.isUnique,
                    "references": references[column.id] ?? NSNull(),
                    "change": diff?.columns[column.id].map(name) ?? NSNull(),
                    "former": diff?.formerly.contains(column.id) == true,
                ] as [String: Any] },
            ]
        }
        let groups: [[String: Any]] = model.groups.compactMap { group in
            guard let frame = model.frame(of: group.id) else { return nil }
            return ["id": group.id.uuidString, "name": group.name, "color": group.color.rawValue, "frame": rect(frame)]
        }
        return [
            "tables": tables, "groups": groups, "reviewing": workspace.baseline != nil,
            // Comparing, the canvas is only there to look at.
            "comparing": App.isComparing, "side": App.side, "previewing": App.preview != nil,
            "summary": diff?.summary ?? NSNull(), "canUndo": workspace.canUndo, "canRedo": workspace.canRedo,
            "bounds": model.bounds.map(rect) ?? NSNull(),
            // Zip ties where they are, and each cable's ties in order along it, for dragging them and pulling cables.
            "ties": model.zipTies.map { tie in
                ["id": tie.id.uuidString, "position": xy(tie.position), "direction": xy(tie.direction),
                 "held": tie.heldDirection != nil, "wires": tie.relationships.map(\.uuidString)] as [String: Any]
            },
            "cables": Dictionary(model.relationships.map { ($0.id.uuidString, $0.zipTies.map(\.uuidString)) }
                + model.groups.flatMap(\.ports).map { ($0.id.uuidString, $0.zipTies.map(\.uuidString)) },
                uniquingKeysWith: { first, _ in first }),
            "wires": model.relationships.map { ["id": $0.id.uuidString, "from": $0.from.uuidString, "to": $0.to.uuidString] },
        ]
    }

    /// Wires as they spring toward their routes at `time`, in seconds, with tables and ties dragged by their offsets.
    func frame(_ workspace: Workspace, time: Double, tableOffsets: [Table.ID: CGPoint], tieOffsets: [ZipTie.ID: CGPoint],
               avoiding: Bool, preview: [String: Any] = [:]) -> [String: Any] {
        let (drawn, diff) = Self.drawn(workspace)
        let model = Self.previewing(drawn, preview, tieOffsets: tieOffsets)
        let routing: Routing
        if let current = self.routing, let inputs, inputs.model == model, inputs.tables == tableOffsets, inputs.ties == tieOffsets,
           inputs.avoiding == avoiding {
            routing = current
        } else {
            routing = Routing(model: model, tableOffsets: tableOffsets, tieOffsets: tieOffsets, avoidingTables: avoiding,
                              reusing: self.routing)
            self.routing = routing
            inputs = (model, tableOffsets, tieOffsets, avoiding)
        }
        let isMoving = simulation.advance(toward: routing.routes, to: time)
        portShapes.advance(toward: routing.ports.mapValues(\.shape), to: time)

        let locations = model.columnLocations
        var colors = Dictionary(model.relationships.compactMap { r in locations[r.to].map { (r.id, $0.table.color.rawValue) } },
                                uniquingKeysWith: { first, _ in first })
        for port in model.groups.flatMap(\.ports) { colors[port.id] = port.column.flatMap { locations[$0]?.table.color.rawValue } }
        var cableTies = Dictionary(model.relationships.map { ($0.id, $0.zipTies) }, uniquingKeysWith: { first, _ in first })
        for port in model.groups.flatMap(\.ports) { cableTies[port.id] = port.zipTies }

        let wires: [[String: Any]] = model.relationships.compactMap { relationship in
            guard let wire = simulation.wires[relationship.id] else { return nil }
            return ["id": relationship.id.uuidString, "color": colors[relationship.id] ?? NSNull(), "points": flat(wire.points),
                    "change": diff?.relationships[relationship.id].map(Self.name) ?? NSNull()]
        }
        let ports: [[String: Any]] = routing.ports.sorted { $0.key.uuidString < $1.key.uuidString }.map { id, port in
            let shape = portShapes[id] ?? port.shape
            return ["id": id.uuidString, "color": colors[id] ?? NSNull(), "label": port.label, "plugged": port.column != nil,
                    "group": port.group.uuidString, "column": port.column?.uuidString ?? NSNull(),
                    "point": xy(port.point), "normal": xy(port.normal),
                    "shape": [Double(shape.length), Double(shape.outer), Double(shape.inner)], "wires": port.wires.map(\.uuidString),
                    "bus": simulation.wires[id].map { flat($0.points) } ?? NSNull()]
        }
        let ties: [[String: Any]] = routing.ties.sorted { $0.key.uuidString < $1.key.uuidString }.compactMap { id, tie in
            // The pointer's stand-in on a cable being pulled isn't drawn.
            guard id != Self.grabID else { return nil }
            // Drawn where its wires actually are, so it rides along as they spring into place.
            let slots = tie.relationships.compactMap { wire -> CGPoint? in
                guard let points = simulation.wires[wire]?.points, let index = cableTies[wire]?.firstIndex(of: id) else { return nil }
                let sample = (index + 1) * Routing.samplesPerSegment
                return points.indices.contains(sample) ? points[sample] : nil
            }
            guard !slots.isEmpty else { return nil }
            let center = slots.reduce(.zero, +) / CGFloat(slots.count)
            return ["id": id.uuidString, "center": xy(center), "direction": xy(tie.direction),
                    "halfLength": Double(tie.halfLength), "count": tie.relationships.count,
                    "wires": tie.relationships.map(\.uuidString),
                    "color": tie.relationships.first.flatMap { colors[$0] } ?? NSNull()]
        }
        return ["moving": isMoving || portShapes.isEasing, "wires": wires, "ports": ports, "ties": ties]
    }

    /// The bend point that stands in for the pointer on a cable being pulled, while it's routed.
    static let grabID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11E")!

    /// The model as routed while something's dragged, as the Mac's `routedModel` has it: a port slid along its edge
    /// (`port`), a zip tie over another, shown combined (`merge`), or a cable pulled through the pointer, out of the ties
    /// it's been tugged out of (`pull`).
    static func previewing(_ model: DataModel, _ preview: [String: Any], tieOffsets: [ZipTie.ID: CGPoint]) -> DataModel {
        guard !preview.isEmpty else { return model }
        var routed = model
        if let port = preview["port"] as? [String: Any], let id = Edits.optionalUUID(port["port"]),
           let side = (port["side"] as? String).flatMap(Side4.init(rawValue:)) {
            routed.movePort(id, to: (side, CGFloat(port["along"] as? Double ?? 0.5)))
        }
        if let merge = preview["merge"] as? [String: Any], let tie = Edits.optionalUUID(merge["tie"]),
           let target = Edits.optionalUUID(merge["into"]) {
            routed.merge(tie, by: tieOffsets[tie] ?? .zero, into: target, along: Edits.point(merge["along"]))
        }
        if let pull = preview["pull"] as? [String: Any], let cable = Edits.optionalUUID(pull["cable"]) {
            for tie in Edits.ids(pull["popped"]) { routed.untie(cable, from: tie) }
            var grab = ZipTie(position: Edits.point(pull["point"]), direction: Edits.point(pull["direction"]), relationships: [cable])
            grab.id = grabID
            routed.zipTies.append(grab)
            var ties = routed.zipTies(onCable: cable) ?? []
            ties.insert(grab.id, at: min(max((pull["segment"] as? NSNumber)?.intValue ?? 0, 0), ties.count))
            routed.setZipTies(onCable: cable, ties)
        }
        return routed
    }

    /// Where on a group's edge a port nearest `point` would go, and that point, as the + by the edge shows it.
    static func portSpot(_ workspace: Workspace, group: UUID, near point: CGPoint, tableOffsets: [Table.ID: CGPoint]) -> [String: Any]? {
        let model = workspace.model
        guard let spot = model.portSpot(nearest: point, on: group, offsets: tableOffsets),
              let at = model.edgePoint(of: group, at: spot, offsets: tableOffsets) else { return nil }
        return ["side": spot.side.rawValue, "along": Double(spot.along), "point": xy(at)]
    }

    /// A port's socket within `reach` of `point`: its outside end, where its bus leaves, or its inside, where its wires
    /// come in.
    func portSocket(_ workspace: Workspace, at point: CGPoint, within reach: CGFloat) -> [String: Any]? {
        guard let socket = workspace.model.portSocket(at: point, within: reach, in: routing?.ports) else { return nil }
        return ["port": socket.port.uuidString, "isOutside": socket.isOutside, "center": xy(socket.center)]
    }

    /// The wire nearest `point`, within `tolerance`, for clicking and pulling one.
    func hit(near point: CGPoint, within tolerance: CGFloat) -> [String: Any]? {
        simulation.hit(near: point, within: tolerance).map { hit in
            ["id": hit.relationship.uuidString, "point": xy(hit.point), "tangent": xy(hit.tangent),
             "segment": hit.segment]
        }
    }

    /// Zip-ties the wires a stroke from `start` to `end` crosses.
    func zipTie(_ workspace: Workspace, from start: CGPoint, to end: CGPoint) -> ZipTie.ID? {
        var model = workspace.model
        guard let id = model.zipTie(simulation, from: start, to: end) else { return nil }
        workspace.change(to: model)
        return id
    }

    private static func name(_ change: SchemaDiff.Change) -> String {
        switch change {
        case .added: "added"
        case .removed: "removed"
        case .modified: "modified"
        }
    }
}

func rect(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }

/// A point for JSON: JSONSerialization can't write CGFloat off Apple platforms.
func xy(_ point: CGPoint) -> [Double] { [point.x, point.y] }

func flat(_ points: [CGPoint]) -> [Double] { points.flatMap { [$0.x, $0.y] } }
