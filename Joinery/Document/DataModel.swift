#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A database design: tables placed on the canvas, the foreign keys between their columns, and the zip ties that
/// bundle those keys' wires.
struct DataModel: Codable, Equatable {
    var tables: [Table] = []
    var relationships: [Relationship] = []
    var zipTies: [ZipTie] = []
    /// Named boundaries around tables, such as a database's schemas.
    var groups: [TableGroup] = []
}

extension DataModel {
    /// What a file from before something existed leaves out is empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tables = try container.decodeIfPresent([Table].self, forKey: .tables) ?? []
        relationships = try container.decodeIfPresent([Relationship].self, forKey: .relationships) ?? []
        zipTies = try container.decodeIfPresent([ZipTie].self, forKey: .zipTies) ?? []
        groups = try container.decodeIfPresent([TableGroup].self, forKey: .groups) ?? []
    }
}

/// A boundary drawn around some tables, with a name: for anything, but mostly a schema, whose name it then is. Its
/// tables say they're in it (`Table.group`); it's as big as they make it.
struct TableGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var color: TableColor
    /// Columns outside it that its tables' wires to are bundled into one cable, through a port on its edge.
    var ports: [GroupPort] = []
}

extension TableGroup {
    /// What a file from before ports leaves out is empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(TableColor.self, forKey: .color)
        ports = try container.decodeIfPresent([GroupPort].self, forKey: .ports) ?? []
    }
}

/// A socket on a group's edge, with one side in the group and one out, standing for a column outside it, such as a
/// much-referenced `entity.id`: every wire between that column and the group's tables runs to the port's inside
/// instead, and one cable, a bus, from its outside to the column. Named for the column; nameless until it has one. It
/// sits where it's been put on the edge, or facing its column.
struct GroupPort: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What its outside is plugged into: one column, outside the group.
    var column: Column.ID?
    /// Where it's been put: on which side, and how far along it, from 0 at the top or left end to 1 at the other.
    /// Nil, it faces its column.
    var side: Side4?
    var along: CGFloat?
    /// The zip ties and bend points its bus runs through, from the port to the column, as a wire's.
    var zipTies: [ZipTie.ID] = []
}

extension GroupPort {
    /// What a file from before something existed leaves out is empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        column = try container.decodeIfPresent(Column.ID.self, forKey: .column)
        side = try container.decodeIfPresent(Side4.self, forKey: .side)
        along = try container.decodeIfPresent(CGFloat.self, forKey: .along)
        zipTies = try container.decodeIfPresent([ZipTie.ID].self, forKey: .zipTies) ?? []
    }
}

struct Table: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Top-left corner, in canvas points.
    var position: CGPoint
    /// Shown on the table and on every wire referencing it.
    var color: TableColor
    var columns: [Column] = []
    /// The group it's in, if any; for a schema, the schema.
    var group: TableGroup.ID?
    /// Made-up rows, to show the kind of data it holds: each a value for some of its columns, by the column's ID.
    var samples: [[String: String]] = []
    /// Anything worth writing down about it.
    var notes = ""
}

extension Table {
    /// What a file from before something existed leaves out is empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        position = try container.decode(CGPoint.self, forKey: .position)
        color = try container.decode(TableColor.self, forKey: .color)
        columns = try container.decodeIfPresent([Column].self, forKey: .columns) ?? []
        group = try container.decodeIfPresent(TableGroup.ID.self, forKey: .group)
        samples = try container.decodeIfPresent([[String: String]].self, forKey: .samples) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    /// A sample row's value for a column.
    func sample(_ row: Int, _ column: Column.ID) -> String {
        samples.indices.contains(row) ? samples[row][column.uuidString] ?? "" : ""
    }

    /// Sets a sample row's value for a column; past the last row, adds rows up to it.
    mutating func setSample(_ row: Int, _ column: Column.ID, to value: String) {
        while samples.count <= row { samples.append([:]) }
        samples[row][column.uuidString] = value.isEmpty ? nil : value
    }
}

enum TableColor: String, Codable, CaseIterable, Identifiable {
    case blue, purple, pink, red, orange, yellow, green, teal, indigo, mint, cyan, brown

    var id: Self { self }
}

struct Column: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var type: DataType
    var isPrimaryKey = false
    /// Required (NOT NULL) unless this is set; shown as a `?` after the type.
    var isNullable = false
    /// No two rows may share a value. A primary key is unique anyway, without this.
    var isUnique = false
}

extension Column {
    /// Flags missing from a file, saved before they existed, are off.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(DataType.self, forKey: .type)
        isPrimaryKey = try container.decodeIfPresent(Bool.self, forKey: .isPrimaryKey) ?? false
        isNullable = try container.decodeIfPresent(Bool.self, forKey: .isNullable) ?? false
        isUnique = try container.decodeIfPresent(Bool.self, forKey: .isUnique) ?? false
    }
}

enum DataType: String, Codable, CaseIterable, Identifiable {
    case uuid, integer, bigint, numeric, text, varchar, boolean, date, timestamp, json, bytea

    var id: Self { self }

    /// Other names people type for each type.
    private static let aliases: [String: DataType] = [
        "int": .integer, "int4": .integer, "smallint": .integer, "serial": .integer,
        "int8": .bigint, "long": .bigint, "bigserial": .bigint,
        "decimal": .numeric, "float": .numeric, "double": .numeric, "real": .numeric, "money": .numeric,
        "string": .text, "str": .text, "char": .varchar,
        "bool": .boolean, "datetime": .timestamp, "timestamptz": .timestamp, "ts": .timestamp,
        "jsonb": .json, "blob": .bytea, "bytes": .bytea, "binary": .bytea, "guid": .uuid,
    ]

    /// Reads what someone typed in a type cell: a type's name, an alias, or the start of either, with a trailing `?`
    /// for nullable. "int?" is a nullable integer, "ts" a timestamp. Nil if it matches nothing.
    static func parse(_ input: String) -> (type: DataType, isNullable: Bool)? {
        var word = input.trimmingCharacters(in: .whitespaces).lowercased()
        let isNullable = word.hasSuffix("?")
        if isNullable { word.removeLast() }
        guard !word.isEmpty else { return nil }
        let type = DataType(rawValue: word) ?? aliases[word]
            ?? allCases.first { $0.rawValue.hasPrefix(word) }
            ?? aliases.sorted { $0.key < $1.key }.first { $0.key.hasPrefix(word) }?.value
        return type.map { ($0, isNullable) }
    }
}

/// A foreign key: `from` holds values of `to`, usually a primary key. Its wire passes through `zipTies` in order,
/// from `from` to `to`.
struct Relationship: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: Column.ID
    var to: Column.ID
    var zipTies: [ZipTie.ID] = []
}

/// Clamps wires side by side at one point, which they pass through square to the tie. Holding a single wire, it's a
/// bend point: somewhere that one wire is routed through.
struct ZipTie: Codable, Identifiable, Equatable {
    var id = UUID()
    var position: CGPoint
    /// The way the bundle ran when it was tied, a unit vector. The tie turns to follow its wires as tables move; this
    /// only keeps it from flipping, which would reverse the order of the wires across it.
    var direction: CGPoint
    /// The way it's held, once lined up with others; until then (nil) it turns with its wires.
    var heldDirection: CGPoint?
    /// The wires it holds, in order across the bundle.
    var relationships: [Relationship.ID]
}
