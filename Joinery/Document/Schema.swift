import CoreGraphics
import Foundation

/// A database design: tables placed on the canvas, the foreign keys between their columns, and the zip ties that
/// bundle those keys' wires.
struct Schema: Codable, Equatable {
    var tables: [Table] = []
    var relationships: [Relationship] = []
    var zipTies: [ZipTie] = []
}

struct Table: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Top-left corner, in canvas points.
    var position: CGPoint
    /// Shown on the table and on every wire referencing it.
    var color: TableColor
    var columns: [Column] = []
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
    var isNullable = false
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
    /// The wires it holds, in order across the bundle.
    var relationships: [Relationship.ID]
}
