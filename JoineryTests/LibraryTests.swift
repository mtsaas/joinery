import Foundation
import Testing
@testable import Joinery

@MainActor
struct LibraryTests {
    /// A library in a new temporary folder, which it seeds with the examples.
    private func freshLibrary() -> Library {
        Library(root: FileManager.default.temporaryDirectory.appending(path: "JoineryTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    @Test func aNewLibraryStartsWithTheExamples() throws {
        let library = freshLibrary()
        let examples = try #require(library.collections.first { $0.name == Library.examplesName })
        #expect(examples.schemas.map(Library.name(of:)) == ["Chinook", "Northwind", "Sakila", "Stack Overflow", "Storefront"])
        for url in examples.schemas { _ = try Schema(contentsOf: url) }
    }

    @Test func newSchemasGetUniqueNamesAndOpen() {
        let library = freshLibrary()
        library.newSchema()
        library.newSchema()
        #expect(library.schemas.map(Library.name(of:)) == ["Untitled Schema", "Untitled Schema 2"])
        #expect(library.open?.name == "Untitled Schema 2")
    }

    @Test func renamingAndMovingKeepTheEditsAndTheSelection() throws {
        let library = freshLibrary()
        library.newSchema()
        var schema = try #require(library.open).schema
        schema.addTable(at: .zero)
        library.open?.change(to: schema)

        library.rename(try #require(library.selection), to: "Shop")
        #expect(library.schemas.map(Library.name(of:)) == ["Shop"])
        #expect(library.open?.name == "Shop")
        #expect(library.open?.schema.tables.count == 1, "the edit was saved before the rename")

        let collection = try #require(library.newCollection())
        library.move(try #require(library.selection), to: collection)
        #expect(library.schemas.isEmpty)
        #expect(library.collections.first { $0.url == collection }?.schemas.map(Library.name(of:)) == ["Shop"])
        #expect(library.collection(of: try #require(library.selection)) == collection)
        #expect(try Schema(contentsOf: try #require(library.selection)).tables.count == 1)
    }

    @Test func aMovedSchemaIsntWrittenBackWhereItWas() async throws {
        let library = freshLibrary()
        library.newSchema()
        let open = try #require(library.open), old = open.url
        var schema = open.schema
        schema.addTable(at: .zero)
        open.change(to: schema)  // Saves half a second later...
        library.rename(old, to: "Moved")
        try await Task.sleep(for: .seconds(0.8))
        #expect(!FileManager.default.fileExists(atPath: old.path), "...but not to where it was")
    }

    @Test func badNamesAreRefused() throws {
        let library = freshLibrary()
        library.newSchema()
        library.rename(try #require(library.selection), to: "a/b")
        #expect(library.failure != nil)
        #expect(library.schemas.map(Library.name(of:)) == ["Untitled Schema"])
    }

    @Test func importingCopiesInWithoutReplacingAnything() throws {
        let library = freshLibrary()
        let examples = try #require(library.collections.first).schemas
        let outside = FileManager.default.temporaryDirectory.appending(path: "Chinook.joinery")
        try? FileManager.default.removeItem(at: outside)
        try FileManager.default.copyItem(at: try #require(examples.first), to: outside)

        library.importSchema(from: outside)
        library.importSchema(from: outside)
        #expect(library.schemas.map(Library.name(of:)) == ["Chinook", "Chinook 2"])
        #expect(library.open?.schema.tables.count == 11)
    }

    @Test func favoritesFollowARenameButNotACopy() throws {
        let library = freshLibrary()
        library.newSchema()
        let original = try #require(library.selection)
        #expect(library.recents.first == original, "opening it makes it recent")
        library.setFavorite(original, true)

        // Saving replaces the file with a new one, which has to take the mark with it.
        var schema = try #require(library.open).schema
        schema.addTable(at: .zero)
        library.open?.change(to: schema)
        library.open?.saveNow()
        library.reload()
        #expect(library.details[original]?.isFavorite == true, "still a favorite after saving")

        library.rename(original, to: "Liked")
        let renamed = try #require(library.selection)
        library.reload()
        #expect(library.details[renamed]?.isFavorite == true, "kept on the file, so it moves with it")

        library.duplicate(renamed)
        let copy = try #require(library.selection)
        #expect(copy != renamed)
        #expect(library.details[copy]?.isFavorite == false)
    }
}
