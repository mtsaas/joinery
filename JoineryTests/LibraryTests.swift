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

    @Test func aReviewKeepsItsChangeInTheVersionHistory() throws {
        let library = freshLibrary()
        let examples = try #require(library.collections.first { $0.name == Library.examplesName })
        library.selection = examples.models.first { Library.name(of: $0) == "Storefront" }
        let open = try #require(library.open)
        let before = open.model
        var named = open.named
        named.save(before, as: "main")
        named.comparison = .init(from: "main", to: NamedVersions.current)
        try open.setNamed(named)
        var after = before
        after.tables[0].name = "renamed_by_the_change"
        open.change(to: after, byAssistant: true)
        open.endComparison()
        #expect(open.named.comparison == nil)
        #expect(open.named.names == ["main"], "the versions stay")

        // Edited since, the reviewed version still holds the change, both sides of it.
        var edited = after
        edited.tables[1].name = "edited_after"
        open.change(to: edited)
        let review = try #require(open.history.versions.first { $0.isReview })
        #expect(review.reason == OpenModel.reviewReason)
        #expect(try DataModel(contentsOf: review.url) == after)
        #expect(try DataModel(contentsOf: review.beforeURL) == before)
        #expect(SchemaDiff(from: try DataModel(contentsOf: review.beforeURL), to: try DataModel(contentsOf: review.url)).summary == "1 table renamed")

        // Kept as the rest thin out.
        let history = open.history
        let reviewDate = review.date
        try history.save(edited, reason: "While editing", now: reviewDate.addingTimeInterval(40 * 24 * 3600))
        #expect(history.versions.contains { $0.isReview })
    }

    @Test func savingAVersionKeepsItForGood() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "JoineryTests-\(UUID().uuidString).joinery", directoryHint: .isDirectory)
        try DataModel().write(to: folder)
        let history = History(of: folder)
        let old = Date.now.addingTimeInterval(-10 * 24 * 3600)
        var model = DataModel()
        try history.save(model, reason: "Opened", now: old)
        model.addTable(at: .zero)
        #expect(try history.save(model, reason: History.savedReason, now: old.addingTimeInterval(60)))
        #expect(try !history.save(model, reason: History.savedReason, now: old.addingTimeInterval(120)), "the same again isn't kept twice")
        model.addTable(at: CGPoint(x: 400, y: 0))
        try history.save(model, reason: "Opened", now: old.addingTimeInterval(180))
        model.addTable(at: CGPoint(x: 800, y: 0))
        try history.save(model, reason: "While editing")
        // Ten days old, only the day's earliest stays, and the one saved with ⌘S, though it isn't the earliest.
        #expect(history.versions.map(\.reason) == ["While editing", "Saved", "Opened"])
    }

    @Test func namedVersionsAndTheirComparisonAreKeptInThePackage() throws {
        let library = freshLibrary()
        let examples = try #require(library.collections.first { $0.name == Library.examplesName })
        let url = try #require(examples.models.first { Library.name(of: $0) == "Storefront" })
        library.selection = url
        let open = try #require(library.open)
        var named = open.named
        named.save(open.model, as: "main")
        named.comparison = .init(from: "main", to: NamedVersions.current)
        try open.setNamed(named)
        let reopened = try OpenModel(url: url)
        #expect(reopened.named == named)
        #expect(reopened.named.compared(current: reopened.model)?.before == open.model)
        // Nothing left, the file goes.
        try open.setNamed(NamedVersions())
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: NamedVersions.fileName).path))
    }

    @Test func layingOutAVersionKeepsTheLayoutInItAndNothingElse() throws {
        let library = freshLibrary()
        let examples = try #require(library.collections.first { $0.name == Library.examplesName })
        let url = try #require(examples.models.first { Library.name(of: $0) == "Storefront" })
        library.selection = url
        let open = try #require(library.open)
        var named = open.named
        named.save(open.model, as: "main")
        try open.setNamed(named)
        let saved = try #require(open.named.version(named: "main"))
        let now = open.model

        // Moving a table, coloring it and renaming it, as shown: only the move and color count, and only there.
        var shown = saved.model
        shown.tables[0].position.x += 300
        shown.tables[0].color = shown.tables[0].color == .red ? .blue : .red
        shown.tables[0].name = "renamed"
        let laid = try #require(open.layOut(.named("Main"), as: shown))
        #expect(laid.tables[0].position == shown.tables[0].position && laid.tables[0].color == shown.tables[0].color)
        #expect(laid.tables[0].name == saved.model.tables[0].name)
        let version = try #require(open.named.version(named: "main"))
        #expect(version.model == laid && version.date == saved.date && open.named.names == ["main"])
        #expect(open.model == now)
        #expect(try OpenModel(url: url).named.version(named: "main") == version, "kept in the package")

        // A group's color too.
        var grouped = laid
        grouped.groups.append(TableGroup(name: "sales", color: .green))
        grouped.tables[0].group = grouped.groups[0].id  // A group with no tables isn't kept.
        var recolored = grouped
        recolored.groups[0].color = .pink
        #expect(grouped.takingLayout(from: recolored).groups.first?.color == .pink)

        // With `only`, just those tables.
        var both = laid
        both.tables[0].position.y += 50
        both.tables[1].position.y += 50
        let one = try #require(open.layOut(.named("main"), as: both, only: [both.tables[1].id]))
        #expect(one.tables[0].position == laid.tables[0].position && one.tables[1].position == both.tables[1].position)

        // A version in the version history: its file.
        let old = try #require(open.history.versions.first)
        var moved = try DataModel(contentsOf: old.url)
        moved.tables[0].position.y += 120
        open.layOut(.history(old.url), as: moved)
        #expect(try DataModel(contentsOf: old.url).tables[0].position == moved.tables[0].position)
        #expect(open.model == now)

        // Now, the model as it is, undoably.
        open.layOut(.named(NamedVersions.current), as: moved)
        #expect(open.model.tables[0].position == moved.tables[0].position)
    }

    @Test func aReviewsBaselineFromBeforeNamedVersionsBecomesOne() throws {
        let library = freshLibrary()
        let examples = try #require(library.collections.first { $0.name == Library.examplesName })
        let url = try #require(examples.models.first { Library.name(of: $0) == "Storefront" })
        _ = try OpenModel(url: url)  // Made a package, as opening any model from before packages does.
        var before = try DataModel(contentsOf: url)
        before.tables.removeLast()
        before.repair()  // As reading it back does: no keys to the table gone.
        try before.fileData.write(to: url.appending(path: "baseline.json"))
        let open = try OpenModel(url: url)
        #expect(open.named.names == [NamedVersions.migratedName])
        #expect(open.named.comparison == .init(from: NamedVersions.migratedName, to: NamedVersions.current))
        #expect(open.named.compared(current: open.model)?.before == before)
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: "baseline.json").path))
        #expect(try OpenModel(url: url).named == open.named, "and it stays one")
    }
}
