import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let joinerySchema = UTType(exportedAs: "com.clarkmccauley.joinery.schema")
}

extension Schema {
    /// Reads a `.joinery` file, dropping anything it refers to that isn't there.
    init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(Schema.self, from: Data(contentsOf: url))
        repair()
    }

    /// Writes it as a `.joinery` file: readable JSON, keys sorted so changes diff cleanly.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
