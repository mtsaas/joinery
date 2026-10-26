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
        #expect(examples.models.map(Library.name(of:)) == ["Chinook", "Northwind", "Sakila", "Stack Overflow", "Storefront"])
        for url in examples.models { _ = try DataModel(contentsOf: url) }
    }

    @Test func newModelsGetUniqueNamesAndOpen() {
        let library = freshLibrary()
        library.newModel()
        library.newModel()
        #expect(library.models.map(Library.name(of:)) == ["Untitled Data Model", "Untitled Data Model 2"])
        #expect(library.open?.name == "Untitled Data Model 2")
    }

    @Test func renamingAndMovingKeepTheEditsAndTheSelection() throws {
        let library = freshLibrary()
        library.newModel()
        var model = try #require(library.open).model
        model.addTable(at: .zero)
        library.open?.change(to: model)

        library.rename(try #require(library.selection), to: "Shop")
        #expect(library.models.map(Library.name(of:)) == ["Shop"])
        #expect(library.open?.name == "Shop")
        #expect(library.open?.model.tables.count == 1, "the edit was saved before the rename")

        let collection = try #require(library.newCollection())
        library.move(try #require(library.selection), to: collection)
        #expect(library.models.isEmpty)
        #expect(library.collections.first { $0.url == collection }?.models.map(Library.name(of:)) == ["Shop"])
        #expect(library.collection(of: try #require(library.selection)) == collection)
        #expect(try DataModel(contentsOf: try #require(library.selection)).tables.count == 1)
    }

    @Test func aMovedSchemaIsntWrittenBackWhereItWas() async throws {
        let library = freshLibrary()
        library.newModel()
        let open = try #require(library.open), old = open.url
        var model = open.model
        model.addTable(at: .zero)
        open.change(to: model)  // Saves half a second later...
        library.rename(old, to: "Moved")
        try await Task.sleep(for: .seconds(0.8))
        #expect(!FileManager.default.fileExists(atPath: old.path), "...but not to where it was")
    }

    @Test func badNamesAreRefused() throws {
        let library = freshLibrary()
        library.newModel()
        library.rename(try #require(library.selection), to: "a/b")
        #expect(library.failure != nil)
        #expect(library.models.map(Library.name(of:)) == ["Untitled Data Model"])
    }

    @Test func importingCopiesInWithoutReplacingAnything() throws {
        let library = freshLibrary()
        let examples = try #require(library.collections.first).models
        let outside = FileManager.default.temporaryDirectory.appending(path: "Chinook.joinery")
        try? FileManager.default.removeItem(at: outside)
        try FileManager.default.copyItem(at: try #require(examples.first), to: outside)

        library.importModel(from: outside)
        library.importModel(from: outside)
        #expect(library.models.map(Library.name(of:)) == ["Chinook", "Chinook 2"])
        #expect(library.open?.model.tables.count == 11)
    }

    @Test func favoritesFollowARenameButNotACopy() throws {
        let library = freshLibrary()
        library.newModel()
        let original = try #require(library.selection)
        #expect(library.recents.first == original, "opening it makes it recent")
        library.setFavorite(original, true)

        // Saving replaces the file with a new one, which has to take the mark with it.
        var model = try #require(library.open).model
        model.addTable(at: .zero)
        library.open?.change(to: model)
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

    @Test func versionsThinOutAsTheyAge() throws {
        let calendar = Calendar.current
        let day = { (offset: Int, hour: Int) in
            calendar.date(byAdding: .day, value: offset, to: calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: hour))!)!
        }
        let now = day(0, 12)
        // Newest first: kept are the last two days' and the earliest of each older day, then of each older week.
        let dates = [now, day(0, 11), day(-3, 12), day(-3, 10), day(-40, 12), day(-40, 10)]
        #expect(History.kept(dates, now: now) == [0, 1, 3, 5])
    }

    @Test func versionsAreKeptBeforeChangesLikelyToBeRegretted() throws {
        let library = freshLibrary()
        let examples = try #require(library.collections.first { $0.name == Library.examplesName })
        library.selection = examples.models.first { Library.name(of: $0) == "Storefront" }
        let open = try #require(library.open)
        let reasons = { open.history.versions.map(\.reason) }
        #expect(reasons() == ["Opened"])

        var model = open.model
        model.tables[0].position.x += 10
        open.change(to: model)
        for index in model.tables.indices { model.tables[index].position.x += 50 }
        open.change(to: model)
        #expect(reasons() == ["Opened"], "small edits and dragging tables together keep none")

        for index in model.tables.indices { model.tables[index].position.x += CGFloat(index) * 100 + 10 }
        open.change(to: model)
        let deleted = model.tables.removeLast().name
        model.repair()
        open.change(to: model)
        for name in ["a", "b"] {
            model.tables[0].name = name
            open.change(to: model, byAssistant: true)
        }
        #expect(reasons() == ["Before AI assistant changes", "Before deleting \(deleted)", "Before rearranging tables", "Opened"])

        let opened = try #require(open.history.versions.last)
        try open.restore(opened)
        #expect(open.model == (try DataModel(contentsOf: opened.url)))
        #expect(reasons().first?.hasPrefix("Before restoring") == true)

        // Kept in the package, so they go where it goes: copied, the copy has them.
        let versions = open.history.versions.map(\.url.lastPathComponent)
        library.duplicate(try #require(library.selection))
        #expect(library.open?.history.versions.dropFirst().map(\.url.lastPathComponent) == versions, "and one for opening it")
    }
}
