#if canImport(CoreGraphics)
import CoreGraphics
#endif
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
        /// A group's port: from inside the group, connect to the column it stands for; from outside, plug it into the
        /// dragged column.
        case port(GroupPort.ID)
    }

    func dropTarget(at point: CGPoint) -> DropTarget? {
        for table in tables.reversed() {
            let frame = Metrics.frame(of: table).insetBy(dx: -Metrics.socketHitRadius, dy: 0)
            guard frame.contains(point) else { continue }
            let row = Int(((point.y - frame.minY - Metrics.headerHeight) / Metrics.rowHeight).rounded(.down))
            return point.y >= frame.minY + Metrics.headerHeight && table.columns.indices.contains(row)
                ? .column(table.columns[row].id) : .table(table.id)
        }
        return port(at: point).map { .port($0) }
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
    mutating func connect(dragging column: Column.ID, onto target: DropTarget, newColumn: Column.ID = UUID(),
                          relationship: Relationship.ID = UUID()) -> Relationship.ID? {
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
            let new = Column(id: newColumn, name: name, type: source.columns[row].type)
            tables[index].columns.append(new)
            return connect(new.id, to: column, id: relationship)
        case .port(let id):
            guard let group = group(ofPort: id), let port = groups.lazy.flatMap(\.ports).first(where: { $0.id == id }) else { return nil }
            guard columnLocations[column]?.table.group == group else {
                plug(id, into: column)
                return nil
            }
            return port.column.flatMap { connect(dragging: column, onto: .column($0)) }
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
    mutating func connect(_ from: Column.ID, to: Column.ID, id: Relationship.ID = UUID()) -> Relationship.ID? {
        guard from != to, !relationships.contains(where: { $0.from == from && $0.to == to }) else { return nil }
        let relationship = Relationship(id: id, from: from, to: to)
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
        guard var ties = zipTies(onCable: relationship) else { return nil }
        let bend = ZipTie(position: point, direction: direction, relationships: [relationship])
        zipTies.append(bend)
        ties.insert(bend.id, at: min(max(segment, 0), ties.count))
        setZipTies(onCable: relationship, ties)
        return bend.id
    }

    /// Combines the zip tie (or bend point) `tie`, moved by `offset`, into `target`: each of its cables goes into the
    /// target where it ran through `tie`, in the slot across the target nearest where it was, and `tie` goes. `direction`
    /// is the way the target runs, as routed.
    mutating func merge(_ tie: ZipTie.ID, by offset: CGPoint = .zero, into target: ZipTie.ID, along direction: CGPoint) {
        guard tie != target, let merged = zipTies.first(where: { $0.id == tie }) else { return }
        // Where each of its cables runs through it: a tie's spacing apart across it, either side of its middle.
        let across = (merged.heldDirection ?? merged.direction).perpendicular
        for (slot, cable) in merged.relationships.enumerated() {
            guard let place = zipTies(onCable: cable)?.firstIndex(of: tie) else { continue }
            let point = merged.position + offset + across * ((CGFloat(slot) - CGFloat(merged.relationships.count - 1) / 2) * Metrics.tieSpacing)
            untie(cable, from: tie)
            self.tie(cable, into: target, at: place, from: point, along: direction)
        }
        zipTies.removeAll { $0.id == tie }
    }

    /// Puts `cable` into the zip tie `tie`, as its `index`th tie along it, in the slot across the tie nearest `point`.
    /// `direction` is the way the tie runs, as routed. Nothing, if it's already in it.
    mutating func tie(_ cable: UUID, into tie: ZipTie.ID, at index: Int, from point: CGPoint, along direction: CGPoint) {
        guard let target = zipTies.firstIndex(where: { $0.id == tie }), !zipTies[target].relationships.contains(cable),
              var ties = zipTies(onCable: cable) else { return }
        // Where it is across the tie, in slots a tie's spacing apart either side of the middle.
        let count = zipTies[target].relationships.count
        let across = (point - zipTies[target].position).dot(direction.perpendicular) / Metrics.tieSpacing
        zipTies[target].relationships.insert(cable, at: min(max(Int((across + CGFloat(count) / 2).rounded()), 0), count))
        ties.insert(tie, at: min(max(index, 0), ties.count))
        setZipTies(onCable: cable, ties)
    }

    /// Takes `cable` out of the zip tie or bend point `tie`; a tie left holding nothing goes.
    mutating func untie(_ cable: UUID, from tie: ZipTie.ID) {
        if var ties = zipTies(onCable: cable) {
            ties.removeAll { $0 == tie }
            setZipTies(onCable: cable, ties)
        }
        guard let index = zipTies.firstIndex(where: { $0.id == tie }) else { return }
        zipTies[index].relationships.removeAll { $0 == cable }
        if zipTies[index].relationships.isEmpty { zipTies.remove(at: index) }
    }

    /// Moves a column to before the one at `insertion` in its table, or last if that's past them all.
    mutating func moveColumn(_ id: Column.ID, in table: Table.ID, to insertion: Int) {
        guard let index = tables.firstIndex(where: { $0.id == table }),
              let from = tables[index].columns.firstIndex(where: { $0.id == id }) else { return }
        let column = tables[index].columns.remove(at: from)
        let to = min(max(insertion > from ? insertion - 1 : insertion, 0), tables[index].columns.count)
        tables[index].columns.insert(column, at: to)
    }

    /// Gives `tables` and `groups` a color, as one change.
    mutating func recolor(tables ids: Set<Table.ID>, groups groupIDs: Set<TableGroup.ID>, _ color: TableColor) {
        for index in tables.indices where ids.contains(tables[index].id) { tables[index].color = color }
        for index in groups.indices where groupIDs.contains(groups[index].id) { groups[index].color = color }
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
        for group in groups.indices { for port in groups[group].ports.indices { groups[group].ports[port].zipTies.removeAll { $0 == id } } }
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
    /// along with tables being dragged, by `offsets`; without the `excluding` ones.
    func frame(of group: TableGroup.ID, offsets: [Table.ID: CGPoint] = [:], excluding: Set<Table.ID> = []) -> CGRect? {
        let frames = tables.filter { $0.group == group && !excluding.contains($0.id) }.map { table in
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
        // Boundaries, as drawn, around the tables that stayed put.
        let boundaries = groups.compactMap { group in frame(of: group.id, excluding: moved).map { (id: group.id, frame: $0) } }
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
        // A port stands for a column outside its group; one that's gone, or now in it, leaves the port unplugged.
        let owner = columnLocations
        for group in groups.indices {
            for port in groups[group].ports.indices {
                guard let column = groups[group].ports[port].column else { continue }
                if owner[column].map({ $0.table.group == groups[group].id }) ?? true { groups[group].ports[port].column = nil }
            }
        }
        let tiesOf = Dictionary(cableIDs.map { ($0, Set(zipTies(onCable: $0) ?? [])) }, uniquingKeysWith: { first, _ in first })
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
        for group in groups.indices {
            for port in groups[group].ports.indices {
                let bus = groups[group].ports[port].id
                groups[group].ports[port].zipTies = groups[group].ports[port].zipTies.uniqued.filter { wiresOf[$0]?.contains(bus) == true }
            }
        }
        for tie in zipTies where tie.relationships.isEmpty { removeZipTie(tie.id) }
        let groupIDs = Set(groups.map(\.id))
        for index in tables.indices where tables[index].group.map(groupIDs.contains) == false { tables[index].group = nil }

        removeEmptyGroups()
    }
}

private extension Array where Element: Hashable {
    var uniqued: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
