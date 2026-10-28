import Foundation

/// A data model as a replicated state machine, the form it's shared and undone in. Everything in it (each table,
/// column, foreign key, zip tie, group and group port) is an entity: a flat JSON object with its `id`, its `kind`, and
/// the fields it's saved with. A change is a list of ops on entities: put one, set one field of one, or delete one.
/// Applying an op gives back its inverse, so a change can be undone even after others' changes, undoing only its own.
///
/// What's nested in a `DataModel` is flat here: a column names its `table`, a port its `group`. What's in order there
/// (tables, columns, wires, ties, groups, ports) has an `order` key that sorts it among the rest of its kind (and
/// parent), so two people inserting at once both keep theirs. See `docs/collaboration.md`.
struct Replica: Equatable {
    typealias Entity = [String: JSON]

    enum Kind: String, CaseIterable {
        case table, column, relationship, zipTie, group, port
    }

    enum Op: Equatable {
        /// Adds an entity, or replaces the one with its ID.
        case put(Entity)
        case set(id: String, field: String, value: JSON)
        case delete(id: String)
    }

    private(set) var entities: [String: Entity] = [:]

    init() {}

    /// `model`, keeping the order keys of `previous` wherever they still sort as `model` has them, so the ops from one to
    /// the other only reorder what moved. Given the model `previous` holds, as `was`, what's the same in both is
    /// taken from `previous` instead of made again, which is most of the time a change takes.
    init(_ model: DataModel, keeping previous: Replica = Replica(), was old: DataModel? = nil) {
        // What hasn't changed, by ID: tables are compared without their columns, groups without their ports.
        var unchanged = Set<UUID>()
        if let old {
            func same<T: Identifiable & Equatable>(_ new: [T], _ old: [T], _ strip: (T) -> T = { $0 }) where T.ID == UUID {
                let before = Dictionary(old.map { ($0.id, strip($0)) }, uniquingKeysWith: { first, _ in first })
                for item in new where before[item.id] == strip(item) { unchanged.insert(item.id) }
            }
            same(model.tables, old.tables) { var table = $0; table.columns = []; return table }
            same(model.tables.flatMap(\.columns), old.tables.flatMap(\.columns))
            same(model.relationships, old.relationships)
            same(model.zipTies, old.zipTies)
            same(model.groups, old.groups) { var group = $0; group.ports = []; return group }
            same(model.groups.flatMap(\.ports), old.groups.flatMap(\.ports))
        }
        func add(_ value: some Encodable, _ id: UUID, _ kind: Kind, order: String, without nested: String? = nil,
                 in parent: (field: String, id: UUID)? = nil) {
            var entity = unchanged.contains(id) ? previous.entities[id.uuidString] ?? Self.fields(of: value) : Self.fields(of: value)
            if let nested { entity[nested] = nil }
            entity["kind"] = .string(kind.rawValue)
            entity["order"] = .string(order)
            if let parent { entity[parent.field] = .string(parent.id.uuidString) }
            entities[id.uuidString] = entity
        }
        func keys(_ ids: [UUID]) -> [String] { previous.orderKeys(ids.map(\.uuidString)) }

        for (table, order) in zip(model.tables, keys(model.tables.map(\.id))) {
            add(table, table.id, .table, order: order, without: "columns")
            for (column, order) in zip(table.columns, keys(table.columns.map(\.id))) {
                add(column, column.id, .column, order: order, in: ("table", table.id))
            }
        }
        for (relationship, order) in zip(model.relationships, keys(model.relationships.map(\.id))) {
            add(relationship, relationship.id, .relationship, order: order)
        }
        for (tie, order) in zip(model.zipTies, keys(model.zipTies.map(\.id))) { add(tie, tie.id, .zipTie, order: order) }
        for (group, order) in zip(model.groups, keys(model.groups.map(\.id))) {
            add(group, group.id, .group, order: order, without: "ports")
            for (port, order) in zip(group.ports, keys(group.ports.map(\.id))) { add(port, port.id, .port, order: order, in: ("group", group.id)) }
        }
    }

    /// The data model it holds. Entities it can't read, or whose table or group has gone, are left out.
    var model: DataModel {
        let byKind = Dictionary(grouping: entities.values) { $0["kind"]?.string.flatMap(Kind.init) }
        func sorted(_ entities: [Entity]?) -> [Entity] {
            (entities ?? []).sorted { ($0["order"]?.string ?? "", $0["id"]?.string ?? "") < ($1["order"]?.string ?? "", $1["id"]?.string ?? "") }
        }
        func read<T: Decodable>(_ entities: [Entity]?) -> [T] {
            sorted(entities).compactMap { try? JSONDecoder().decode(T.self, from: JSONEncoder().encode($0)) }
        }
        let columns = Dictionary(grouping: byKind[.column] ?? []) { $0["table"]?.string ?? "" }
        let ports = Dictionary(grouping: byKind[.port] ?? []) { $0["group"]?.string ?? "" }
        var model = DataModel()
        model.tables = read(byKind[.table]).map { (table: Table) in
            var table = table
            table.columns = read(columns[table.id.uuidString])
            return table
        }
        model.relationships = read(byKind[.relationship])
        model.zipTies = read(byKind[.zipTie])
        model.groups = read(byKind[.group]).map { (group: TableGroup) in
            var group = group
            group.ports = read(ports[group.id.uuidString])
            return group
        }
        return model
    }

    // MARK: Ops

    /// What turns this into `other`: whole entities put and deleted, and changed fields set, in a stable order.
    func ops(to other: Replica) -> [Op] {
        var ops: [Op] = []
        for id in other.entities.keys.sorted() {
            guard let new = other.entities[id] else { continue }
            guard let old = entities[id] else { ops.append(.put(new)); continue }
            for field in Set(old.keys).union(new.keys).sorted() where old[field] != new[field] {
                ops.append(.set(id: id, field: field, value: new[field] ?? .null))
            }
        }
        for id in entities.keys.sorted() where other.entities[id] == nil { ops.append(.delete(id: id)) }
        return ops
    }

    /// Applies `op`.
    /// - Returns: The op that undoes it, or nil if it did nothing: setting a field of, or deleting, an entity that
    ///   isn't there.
    @discardableResult
    mutating func apply(_ op: Op) -> Op? {
        switch op {
        case .put(let entity):
            guard let id = entity["id"]?.string else { return nil }
            let old = entities.updateValue(entity, forKey: id)
            return old.map(Op.put) ?? .delete(id: id)
        case .set(let id, let field, let value):
            guard entities[id] != nil, field != "id", field != "kind" else { return nil }
            let old = entities[id]?[field] ?? .null
            entities[id]?[field] = value == .null ? nil : value
            return .set(id: id, field: field, value: old)
        case .delete(let id):
            return entities.removeValue(forKey: id).map(Op.put)
        }
    }

    /// Applies `ops` in order.
    /// - Returns: What undoes them all, in the order to apply it.
    mutating func apply(_ ops: [Op]) -> [Op] {
        ops.compactMap { apply($0) }.reversed()
    }

    // MARK: Taking changes

    struct Refusal: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Takes another's change: every op of it, then the ops that tidy up after it (see `tidying`), or, if any op can't
    /// be made or leaves something that can't be read, none, as if it had never come.
    /// - Returns: The tidying ops it applied after the change's.
    mutating func receive(_ ops: [Op]) throws -> [Op] {
        var next = self
        for op in ops {
            guard next.apply(op) != nil else { throw Refusal(reason: "That's been deleted or changed since.") }
        }
        for id in Set(ops.map(\.id)) {
            if let entity = next.entities[id], let problem = next.problem(with: entity) { throw Refusal(reason: problem) }
        }
        let tidying = next.tidying()
        _ = next.apply(tidying)
        self = next
        return tidying
    }

    /// Ops that tidy it up after ops made elsewhere, or undone after others' changes: what's left dangling (a key to a
    /// column gone, say) repaired, and what can't be read, or whose table or group has gone, removed. None if it's tidy.
    func tidying() -> [Op] {
        let applied = model
        var repaired = applied
        repaired.repair()
        return ops(to: Replica(repaired, keeping: self, was: applied))
    }

    // MARK: Checking

    /// Why `entity` can't be in it, if it can't: an unknown kind, fields its kind can't be read from, a bad order key,
    /// or, for a column or port, a table or group that isn't there. Checked before taking another's change.
    func problem(with entity: Entity) -> String? {
        guard let kind = entity["kind"]?.string.flatMap(Kind.init) else { return "Unknown kind of thing." }
        if let order = entity["order"], order.string.map(OrderKey.isValid) != true { return "A bad order key." }
        func reads<T: Decodable>(_ type: T.Type) -> Bool {
            (try? JSONDecoder().decode(T.self, from: JSONEncoder().encode(entity))) != nil
        }
        func has(_ field: String, ofKind parent: Kind) -> Bool {
            entity[field]?.string.flatMap { entities[$0]?["kind"]?.string } == parent.rawValue
        }
        let isReadable = switch kind {
        case .table: reads(Table.self)
        case .column: reads(Column.self) && has("table", ofKind: .table)
        case .relationship: reads(Relationship.self)
        case .zipTie: reads(ZipTie.self)
        case .group: reads(TableGroup.self)
        case .port: reads(GroupPort.self) && has("group", ofKind: .group)
        }
        return isReadable ? nil : "A \(kind.rawValue) that can't be read, or isn't in anything."
    }

    // MARK: Order

    /// Keys sorting `ids` in this order: their keys here wherever those already sort so (the most of them that do),
    /// and new keys between them for the rest.
    private func orderKeys(_ ids: [String]) -> [String] {
        let previous = ids.map { entities[$0]?["order"]?.string }
        var keys = [String?](repeating: nil, count: ids.count)
        for index in Self.longestIncreasing(previous) { keys[index] = previous[index] }
        var start = 0
        while start < keys.count {
            guard keys[start] == nil else { start += 1; continue }
            var end = start
            while end < keys.count, keys[end] == nil { end += 1 }
            let spread = OrderKey.spread(end - start, after: start > 0 ? keys[start - 1]! : "", before: end < keys.count ? keys[end] : nil)
            for (offset, key) in spread.enumerated() { keys[start + offset] = key }
            start = end
        }
        return keys.map { $0! }
    }

    /// The indices of the longest run of values, in order though not together, that only increases.
    static func longestIncreasing(_ values: [String?]) -> Set<Int> {
        // Patience sorting: the last index of the best run of each length, and what came before each.
        var tails: [Int] = [], before = [Int?](repeating: nil, count: values.count)
        for (index, value) in values.enumerated() {
            guard let value else { continue }
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if values[tails[middle]]! < value { low = middle + 1 } else { high = middle }
            }
            before[index] = low > 0 ? tails[low - 1] : nil
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run = Set<Int>(), index = tails.last
        while let current = index {
            run.insert(current)
            index = before[current]
        }
        return run
    }

    private static func fields(of value: some Encodable) -> Entity {
        guard let data = try? JSONEncoder().encode(value), case .object(let fields) = try? JSONDecoder().decode(JSON.self, from: data) else {
            return [:]
        }
        return fields
    }
}

/// Keys that sort things in order, as strings compared character by character, from which a key can always be made
/// between any two: "a" < "ai" < "b". Made of 0–9 and a–z, never ending in 0, so there's always room before one.
enum OrderKey {
    private static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static let values = Dictionary(uniqueKeysWithValues: digits.enumerated().map { ($1, $0) })

    /// Whether it's a key one could have made: something else in an `order` field is replaced.
    static func isValid(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 256 && key.last != "0" && key.allSatisfy { values[$0] != nil }
    }

    /// A key after `low` and before `high`, or after `low` with nothing after it; "" is before everything.
    static func between(_ low: String, _ high: String?) -> String {
        let low = Array(low), high = high.map(Array.init)
        var key = "", isBounded = high != nil, index = 0
        while true {
            let a = index < low.count ? values[low[index]] ?? 0 : 0
            let b = isBounded && index < high!.count ? values[high![index]] ?? digits.count : digits.count
            if b - a > 1 {
                key.append(digits[(a + b) / 2])
                return key
            }
            key.append(digits[a])
            // Below `high` now, so free of it from here.
            if b - a == 1 { isBounded = false }
            index += 1
        }
    }

    /// `count` keys in order between `low` and `high`, spread out so later inserts among them stay short.
    static func spread(_ count: Int, after low: String, before high: String?) -> [String] {
        guard count > 0 else { return [] }
        let middle = between(low, high), half = (count - 1) / 2
        return spread(half, after: low, before: middle) + [middle] + spread(count - 1 - half, after: middle, before: high)
    }
}

/// Any JSON value, as entities' fields are.
enum JSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    var string: String? {
        if case .string(let string) = self { string } else { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSON].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

/// On the wire: `{"op": "put", "entity": {…}}`, `{"op": "set", "id": …, "field": …, "value": …}`,
/// `{"op": "delete", "id": …}`.
extension Replica.Op {
    /// The ID of the entity it's on.
    var id: String {
        switch self {
        case .put(let entity): entity["id"]?.string ?? ""
        case .set(let id, _, _), .delete(let id): id
        }
    }
}

extension Replica.Op: Codable {
    private enum CodingKeys: String, CodingKey { case op, entity, id, field, value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .op) {
        case "put": self = .put(try container.decode(Replica.Entity.self, forKey: .entity))
        case "set": self = .set(id: try container.decode(String.self, forKey: .id), field: try container.decode(String.self, forKey: .field),
                                value: try container.decodeIfPresent(JSON.self, forKey: .value) ?? .null)
        case "delete": self = .delete(id: try container.decode(String.self, forKey: .id))
        case let other: throw DecodingError.dataCorruptedError(forKey: .op, in: container, debugDescription: "Unknown op \(other)")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .put(let entity):
            try container.encode("put", forKey: .op)
            try container.encode(entity, forKey: .entity)
        case .set(let id, let field, let value):
            try container.encode("set", forKey: .op)
            try container.encode(id, forKey: .id)
            try container.encode(field, forKey: .field)
            try container.encode(value, forKey: .value)
        case .delete(let id):
            try container.encode("delete", forKey: .op)
            try container.encode(id, forKey: .id)
        }
    }
}
