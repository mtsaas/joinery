import CoreGraphics
import Foundation

extension Table {
    /// Runs of two or more primary key columns next to each other, by row: the parts of a compound key that can be
    /// shown as one.
    var compoundPrimaryKeyRuns: [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = [], start: Int?
        for (row, column) in columns.enumerated() {
            if column.isPrimaryKey {
                start = start ?? row
            } else if let first = start {
                if row - first > 1 { runs.append(first...(row - 1)) }
                start = nil
            }
        }
        if let first = start, columns.count - first > 1 { runs.append(first...(columns.count - 1)) }
        return runs
    }
}

extension DataModel {
    func table(_ id: Table.ID) -> Table? {
        tables.first { $0.id == id }
    }

    /// The table that owns each column, and the column's row in it.
    var columnLocations: [Column.ID: (table: Table, row: Int)] {
        var locations: [Column.ID: (table: Table, row: Int)] = [:]
        for table in tables {
            for (row, column) in table.columns.enumerated() { locations[column.id] = (table, row) }
        }
        return locations
    }

    /// "orders.user_id", or nil for a column that isn't in the model.
    func qualifiedName(of column: Column.ID) -> String? {
        columnLocations[column].map { "\($0.table.name).\($0.table.columns[$0.row].name)" }
    }

    /// The smallest rectangle around every table and group, or nil when there are none.
    var bounds: CGRect? {
        (tables.map(Metrics.frame) + groups.compactMap { frame(of: $0.id) }).reduce(nil) { $0?.union($1) ?? $1 }
    }

    /// Where a wire dragged out of a socket would land.
    enum DropTarget: Hashable {
        /// A row: connect to that column.
        case column(Column.ID)
        /// The table's header or empty space: give it a new column to connect.
        case table(Table.ID)
        /// A group's port: connect to the column it stands for.
        case port(GroupPort.ID)
        /// A group's empty space: give it a port for the dragged column, bundling its wires to it.
        case group(TableGroup.ID)
    }

    func dropTarget(at point: CGPoint) -> DropTarget? {
        for table in tables.reversed() {
            let frame = Metrics.frame(of: table).insetBy(dx: -Metrics.socketHitRadius, dy: 0)
            guard frame.contains(point) else { continue }
            let row = Int(((point.y - frame.minY - Metrics.headerHeight) / Metrics.rowHeight).rounded(.down))
            return point.y >= frame.minY + Metrics.headerHeight && table.columns.indices.contains(row)
                ? .column(table.columns[row].id) : .table(table.id)
        }
        for (id, port) in portPlacements() {
            let pill = CGRect(x: port.point.x - Metrics.portWidth / 2, y: port.point.y - Metrics.portHeight / 2,
                              width: Metrics.portWidth, height: Metrics.portHeight)
            if pill.contains(point) { return .port(id) }
        }
        return groups.reversed().first { frame(of: $0.id)?.contains(point) == true }.map { .group($0.id) }
    }

    /// What to call a new column in `table` that references `column`: its name, but `<table>_id` for an `id` column
    /// ("users.id" gives "user_id"), made unique in `table`.
    func newColumnName(referencing column: Column.ID, in table: Table.ID) -> String? {
        guard let (source, row) = columnLocations[column], let target = self.table(table) else { return nil }
        let name = source.columns[row].name
        let base = name.lowercased() == "id" ? Self.singular(source.name) + "_id" : name
        var candidate = base, number = 2
        while target.columns.contains(where: { $0.name == candidate }) {
            candidate = "\(base)_\(number)"
            number += 1
        }
        return candidate
    }

    /// A table name made singular, by the common English endings: categories → category, addresses → address.
    static func singular(_ name: String) -> String {
        for (plural, single) in [("ies", "y"), ("sses", "ss"), ("ches", "ch"), ("shes", "sh"), ("xes", "x"), ("uses", "us")]
        where name.hasSuffix(plural) {
            return name.dropLast(plural.count) + single
        }
        return name.hasSuffix("s") && !name.hasSuffix("ss") ? String(name.dropLast()) : name
    }

    /// Connects a wire dragged from `column` and dropped on `target`.
    ///
    /// On a column, whichever end alone is a primary key is the one referenced, so it doesn't matter which way the
    /// wire was dragged; otherwise the dragged column is the foreign key. On a table, a new column is added there,
    /// named for `column` and of its type, referencing it.
    @discardableResult
    mutating func connect(dragging column: Column.ID, onto target: DropTarget) -> Relationship.ID? {
        switch target {
        case .column(let other):
            let locations = columnLocations
            guard let dragged = locations[column], let dropped = locations[other] else { return nil }
            let draggedIsKey = dragged.table.columns[dragged.row].isPrimaryKey
            let droppedIsKey = dropped.table.columns[dropped.row].isPrimaryKey
            return draggedIsKey && !droppedIsKey ? connect(other, to: column) : connect(column, to: other)
        case .table(let id):
            guard let name = newColumnName(referencing: column, in: id), let (source, row) = columnLocations[column],
                  let index = tables.firstIndex(where: { $0.id == id }) else { return nil }
            let new = Column(name: name, type: source.columns[row].type)
            tables[index].columns.append(new)
            return connect(new.id, to: column)
        case .port(let id):
            guard let port = groups.lazy.flatMap(\.ports).first(where: { $0.id == id }) else { return nil }
            return connect(dragging: column, onto: .column(port.column))
        case .group(let id):
            addPort(to: id, for: column)
            return nil
        }
    }

    enum Alignment: CaseIterable {
        case left, center, right, top, middle, bottom

        var title: String {
            switch self {
            case .left: "Align Left Edges"
            case .center: "Align Centers"
            case .right: "Align Right Edges"
            case .top: "Align Top Edges"
            case .middle: "Align Middles"
            case .bottom: "Align Bottom Edges"
            }
        }

        var symbol: String {
            switch self {
            case .left: "align.horizontal.left"
            case .center: "align.horizontal.center"
            case .right: "align.horizontal.right"
            case .top: "align.vertical.top"
            case .middle: "align.vertical.center"
            case .bottom: "align.vertical.bottom"
            }
        }
    }

    /// Lines tables and ties up along an edge or center of the box around them all. Ties go on the line itself, and
    /// are held across it, so the wires through them run square to it and they stay that way as tables move.
    mutating func align(_ ids: Set<Table.ID>, ties tieIDs: Set<ZipTie.ID> = [], _ alignment: Alignment) {
        let indices = tables.indices.filter { ids.contains(tables[$0].id) }
        let ties = zipTies.indices.filter { tieIDs.contains(zipTies[$0].id) }
        let frames = indices.map { Metrics.frame(of: tables[$0]) } + ties.map { CGRect(origin: zipTies[$0].position, size: .zero) }
        guard let bounds = frames.reduce(nil, { $0?.union($1) ?? $1 }) else { return }
        for index in ties {
            let tie = zipTies[index]
            switch alignment {
            case .left, .center, .right:
                zipTies[index].position.x = alignment == .left ? bounds.minX : alignment == .center ? bounds.midX : bounds.maxX
                zipTies[index].heldDirection = CGPoint(x: tie.direction.x < 0 ? -1 : 1, y: 0)
            case .top, .middle, .bottom:
                zipTies[index].position.y = alignment == .top ? bounds.minY : alignment == .middle ? bounds.midY : bounds.maxY
                zipTies[index].heldDirection = CGPoint(x: 0, y: tie.direction.y < 0 ? -1 : 1)
            }
        }
        for index in indices {
            let size = Metrics.size(of: tables[index])
            switch alignment {
            case .left: tables[index].position.x = bounds.minX
            case .center: tables[index].position.x = bounds.midX - size.width / 2
            case .right: tables[index].position.x = bounds.maxX - size.width
            case .top: tables[index].position.y = bounds.minY
            case .middle: tables[index].position.y = bounds.midY - size.height / 2
            case .bottom: tables[index].position.y = bounds.maxY - size.height
            }
        }
    }

    /// Spaces tables evenly between the outermost two, which stay put.
    mutating func distribute(_ ids: Set<Table.ID>, horizontally: Bool) {
        let indices = tables.indices.filter { ids.contains(tables[$0].id) }
            .sorted { horizontally ? tables[$0].position.x < tables[$1].position.x : tables[$0].position.y < tables[$1].position.y }
        guard indices.count > 2 else { return }
        let lengths = indices.map { horizontally ? Metrics.size(of: tables[$0]).width : Metrics.size(of: tables[$0]).height }
        let starts = indices.map { horizontally ? tables[$0].position.x : tables[$0].position.y }
        let start = starts[0], end = starts[starts.count - 1] + lengths[lengths.count - 1]
        let gap = (end - start - lengths.reduce(0, +)) / CGFloat(indices.count - 1)
        var cursor = start
        for (index, length) in zip(indices, lengths) {
            if horizontally { tables[index].position.x = cursor } else { tables[index].position.y = cursor }
            cursor += length + gap
        }
    }

    @discardableResult
    mutating func addTable(at position: CGPoint) -> Table.ID {
        var number = tables.count + 1
        while tables.contains(where: { $0.name == "table_\(number)" }) { number += 1 }
        // The color used least so far, so neighbors tend to differ.
        let color = TableColor.allCases.min { a, b in tables.count { $0.color == a } < tables.count { $0.color == b } } ?? .blue
        let table = Table(name: "table_\(number)", position: position, color: color,
                          columns: [Column(name: "id", type: .uuid, isPrimaryKey: true)])
        tables.append(table)
        return table.id
    }

    mutating func removeTable(_ id: Table.ID) {
        guard let table = table(id) else { return }
        let columns = Set(table.columns.map(\.id))
        tables.removeAll { $0.id == id }
        removeRelationships { columns.contains($0.from) || columns.contains($0.to) }
        removeEmptyGroups()
    }

    mutating func removeColumn(_ id: Column.ID) {
        for index in tables.indices { tables[index].columns.removeAll { $0.id == id } }
        removeRelationships { $0.from == id || $0.to == id }
    }

    /// Adds a foreign key from `from` to `to`, unless it would be to itself or already exists.
    @discardableResult
    mutating func connect(_ from: Column.ID, to: Column.ID) -> Relationship.ID? {
        guard from != to, !relationships.contains(where: { $0.from == from && $0.to == to }) else { return nil }
        let relationship = Relationship(from: from, to: to)
        relationships.append(relationship)
        return relationship.id
    }

    mutating func removeRelationships(where shouldRemove: (Relationship) -> Bool) {
        let removed = Set(relationships.filter(shouldRemove).map(\.id))
        guard !removed.isEmpty else { return }
        relationships.removeAll { removed.contains($0.id) }
        for index in zipTies.indices { zipTies[index].relationships.removeAll(where: removed.contains) }
        zipTies.removeAll { $0.relationships.isEmpty }
    }

    /// Routes one wire through `point`, which lies on the wire's `segment`th stretch between sockets and ties.
    /// - Parameter direction: The way the wire runs there.
    @discardableResult
    mutating func addBendPoint(on relationship: Relationship.ID, at point: CGPoint, direction: CGPoint, segment: Int) -> ZipTie.ID? {
        guard let index = relationships.firstIndex(where: { $0.id == relationship }) else { return nil }
        let bend = ZipTie(position: point, direction: direction, relationships: [relationship])
        zipTies.append(bend)
        relationships[index].zipTies.insert(bend.id, at: min(max(segment, 0), relationships[index].zipTies.count))
        return bend.id
    }

    /// Moves tables and ties together, as when dragging a selection.
    mutating func move(tables: Set<Table.ID>, ties: Set<ZipTie.ID>, by delta: CGPoint) {
        for index in self.tables.indices where tables.contains(self.tables[index].id) { self.tables[index].position += delta }
        for index in zipTies.indices where ties.contains(zipTies[index].id) { zipTies[index].position += delta }
    }

    /// Adds an empty column after `column`, or first for nil, and returns it.
    @discardableResult
    mutating func addColumn(to table: Table.ID, after column: Column.ID?) -> Column.ID? {
        guard let index = tables.firstIndex(where: { $0.id == table }) else { return nil }
        let new = Column(name: "", type: .text)
        let position = column.flatMap { id in tables[index].columns.firstIndex { $0.id == id } }.map { $0 + 1 }
        tables[index].columns.insert(new, at: position ?? 0)
        return new.id
    }

    mutating func removeZipTie(_ id: ZipTie.ID) {
        zipTies.removeAll { $0.id == id }
        for index in relationships.indices { relationships[index].zipTies.removeAll { $0 == id } }
    }

    /// Drops references to anything that isn't there, so a hand-edited or damaged file can't make the canvas draw
    /// wires to nowhere. A wire and a tie stay joined only if each lists the other.
    // MARK: Focus

    /// `tables` and every table a foreign key joins them to, either way.
    func neighborhood(of tables: Set<Table.ID>) -> Set<Table.ID> {
        let owner = columnLocations.mapValues(\.table.id)
        var around = tables
        for relationship in relationships {
            guard let from = owner[relationship.from], let to = owner[relationship.to] else { continue }
            if tables.contains(from) { around.insert(to) }
            if tables.contains(to) { around.insert(from) }
        }
        return around
    }

    /// The wires with both ends among `tables`.
    func relationships(among tables: Set<Table.ID>) -> Set<Relationship.ID> {
        let owner = columnLocations.mapValues(\.table.id)
        return Set(relationships.filter { r in
            owner[r.from].map(tables.contains) == true && owner[r.to].map(tables.contains) == true
        }.map(\.id))
    }

    // MARK: Groups

    func members(of group: TableGroup.ID) -> [Table] {
        tables.filter { $0.group == group }
    }

    /// The boundary drawn around a group's tables, with room for its name above them; nil while it has none. Moves
    /// along with tables being dragged, by `offsets`.
    func frame(of group: TableGroup.ID, offsets: [Table.ID: CGPoint] = [:]) -> CGRect? {
        let frames = tables.filter { $0.group == group }.map { table in
            Metrics.frame(of: table).offsetBy(dx: offsets[table.id]?.x ?? 0, dy: offsets[table.id]?.y ?? 0)
        }
        guard let union = frames.reduce(nil, { $0?.union($1) ?? $1 }) else { return nil }
        let padding = Metrics.groupPadding
        return CGRect(x: union.minX - padding, y: union.minY - padding - Metrics.groupLabelHeight,
                      width: union.width + padding * 2, height: union.height + padding * 2 + Metrics.groupLabelHeight)
    }

    /// The zip ties and bend points inside a group's boundary: they belong to it, and go wherever it's moved.
    func ties(in group: TableGroup.ID) -> [ZipTie.ID] {
        guard let frame = frame(of: group) else { return [] }
        return zipTies.filter { frame.contains($0.position) }.map(\.id)
    }

    /// Puts `tables` in a new group, out of any they were in, and returns it.
    @discardableResult
    mutating func group(_ ids: Set<Table.ID>, named name: String? = nil) -> TableGroup.ID {
        // The color used least so far, as for tables.
        let color = TableColor.allCases.min { a, b in groups.count { $0.color == a } < groups.count { $0.color == b } } ?? .indigo
        var number = groups.count + 1
        while groups.contains(where: { $0.name == "schema_\(number)" }) { number += 1 }
        let group = TableGroup(name: name ?? "schema_\(number)", color: color)
        groups.append(group)
        for index in tables.indices where ids.contains(tables[index].id) { tables[index].group = group.id }
        removeEmptyGroups()
        return group.id
    }

    /// Takes the group away; its tables stay where they are.
    mutating func ungroup(_ id: TableGroup.ID) {
        for index in tables.indices where tables[index].group == id { tables[index].group = nil }
        groups.removeAll { $0.id == id }
    }

    /// Takes tables out of their groups, letting go of any group left empty.
    mutating func removeFromGroups(_ ids: Set<Table.ID>) {
        for index in tables.indices where ids.contains(tables[index].id) { tables[index].group = nil }
        removeEmptyGroups()
    }

    /// After `moved` tables are dropped, each that landed (by its middle) inside another group's boundary joins it.
    /// One moved along with the rest of its own group stays in it; leaving a group is done on purpose, not by dragging.
    mutating func regroup(_ moved: Set<Table.ID>) {
        // Boundaries around the tables that stayed put.
        let still = Dictionary(grouping: tables.filter { !moved.contains($0.id) && $0.group != nil }, by: { $0.group! })
        let boundaries = groups.compactMap { group -> (id: TableGroup.ID, frame: CGRect)? in
            guard let members = still[group.id] else { return nil }
            let union = members.map(Metrics.frame).reduce(members.map(Metrics.frame)[0]) { $0.union($1) }
            let padding = Metrics.groupPadding
            return (group.id, union.insetBy(dx: -padding, dy: -padding))
        }
        for index in tables.indices where moved.contains(tables[index].id) {
            let frame = Metrics.frame(of: tables[index])
            let middle = CGPoint(x: frame.midX, y: frame.midY)
            // The last drawn is on top.
            if let landing = boundaries.last(where: { $0.frame.contains(middle) }), landing.id != tables[index].group {
                tables[index].group = landing.id
            }
        }
        removeEmptyGroups()
    }

    mutating func removeEmptyGroups() {
        let used = Set(tables.compactMap(\.group))
        groups.removeAll { !used.contains($0.id) }
    }

    mutating func repair() {
        let columns = Set(tables.flatMap(\.columns).map(\.id))
        relationships.removeAll { !columns.contains($0.from) || !columns.contains($0.to) }
        let tiesOf = Dictionary(relationships.map { ($0.id, Set($0.zipTies)) }, uniquingKeysWith: { first, _ in first })
        let wiresOf = Dictionary(zipTies.map { ($0.id, Set($0.relationships)) }, uniquingKeysWith: { first, _ in first })
        for index in zipTies.indices {
            let tie = zipTies[index].id
            zipTies[index].relationships = zipTies[index].relationships.uniqued.filter { tiesOf[$0]?.contains(tie) == true }
            zipTies[index].direction = zipTies[index].direction.normalized ?? CGPoint(x: 1, y: 0)
        }
        for index in relationships.indices {
            let wire = relationships[index].id
            relationships[index].zipTies = relationships[index].zipTies.uniqued.filter { wiresOf[$0]?.contains(wire) == true }
        }
        for tie in zipTies where tie.relationships.isEmpty { removeZipTie(tie.id) }
        let groupIDs = Set(groups.map(\.id))
        for index in tables.indices where tables[index].group.map(groupIDs.contains) == false { tables[index].group = nil }
        // A port stands for a column outside its group.
        let owner = columnLocations
        for index in groups.indices {
            let group = groups[index].id
            groups[index].ports.removeAll { port in owner[port.column].map { $0.table.group == group } ?? true }
        }
        removeEmptyGroups()
    }
}

private extension Array where Element: Hashable {
    var uniqued: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
