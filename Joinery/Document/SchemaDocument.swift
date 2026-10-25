import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let joinerySchema = UTType(exportedAs: "com.clarkmccauley.joinery.schema")
}

struct SchemaDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.joinerySchema]

    var schema: Schema

    init(schema: Schema = Schema()) {
        self.schema = schema
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        schema = try JSONDecoder().decode(Schema.self, from: data)
        schema.repair()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(schema))
    }
}
