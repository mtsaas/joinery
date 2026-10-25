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
}

/// A foreign key: `from` holds values of `to`, usually a primary key. Its wire passes through `zipTies` in order,
/// from `from` to `to`.
struct Relationship: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: Column.ID
    var to: Column.ID
    var zipTies: [ZipTie.ID] = []
}

/// Clamps several wires side by side at one point.
struct ZipTie: Codable, Identifiable, Equatable {
    var id = UUID()
    var position: CGPoint
    /// The way the bundle ran when it was tied, a unit vector. The tie turns to follow its wires as tables move; this
    /// only keeps it from flipping, which would reverse the order of the wires across it.
    var direction: CGPoint
    /// The wires it holds, in order across the bundle.
    var relationships: [Relationship.ID]
}
