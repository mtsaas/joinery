import Foundation

/// A model's named versions, such as "main" and "draft 1", each the whole model as it was when saved under that name,
/// and which two the window compares. Kept in the model's package as `named-versions.json`, so they go where it goes.
/// Unlike the version history (`History`), they're only ever saved and deleted on purpose, and never thinned out.
struct NamedVersions: Codable, Equatable {
    struct Version: Codable, Equatable {
        var name: String
        var date: Date
        var model: DataModel
    }

    /// Two versions compared: names of versions, or `current` for the model as it is.
    struct Comparison: Codable, Equatable {
        var from: String
        var to: String
    }

    /// Oldest first.
    private(set) var versions: [Version] = []
    var comparison: Comparison?

    /// The name that stands for the model as it is now, never a version's.
    static let current = "current"
    /// The package's file.
    static let fileName = "named-versions.json"
    /// What a review's baseline from before named versions is called once it becomes one.
    static let migratedName = "Before"

    var isEmpty: Bool { versions.isEmpty && comparison == nil }
    var names: [String] { versions.map(\.name) }

    /// The version called `name`, ignoring case and spaces around it.
    func version(named name: String) -> Version? {
        let wanted = Self.clean(name).lowercased()
        return versions.first { $0.name.lowercased() == wanted }
    }

    /// The model `name` stands for: a version's, or `current` for the model as it is.
    func model(_ name: String, current model: DataModel) -> DataModel? {
        Self.isCurrent(name) ? model : version(named: name)?.model
    }

    /// The models compared now, if any, with `current` the model as it is.
    func compared(current model: DataModel) -> (before: DataModel, after: DataModel)? {
        guard let comparison, let before = self.model(comparison.from, current: model),
              let after = self.model(comparison.to, current: model) else { return nil }
        return (before, after)
    }

    /// Saves `model` as `name`, as the newest; one saved before under that name is replaced.
    mutating func save(_ model: DataModel, as name: String, at date: Date = .now) {
        let name = Self.clean(name)
        remove(name)
        // To the second, as the file keeps it, so it reads back the same.
        versions.append(Version(name: name, date: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)), model: model))
    }

    /// Changes the version called `name` to `model`, keeping when it was saved and its place: to lay it out afresh.
    mutating func update(_ name: String, to model: DataModel) {
        let wanted = Self.clean(name).lowercased()
        guard let index = versions.firstIndex(where: { $0.name.lowercased() == wanted }) else { return }
        versions[index].model = model
    }

    /// Deletes the version called `name`, and stops comparing with it.
    mutating func remove(_ name: String) {
        let wanted = Self.clean(name).lowercased()
        versions.removeAll { $0.name.lowercased() == wanted }
        if let comparison, [comparison.from, comparison.to].contains(where: { $0.lowercased() == wanted }) { self.comparison = nil }
    }

    static func isCurrent(_ name: String) -> Bool { clean(name).lowercased() == current }

    static func clean(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A package's from before named versions, with a review's baseline: that becomes a version, compared with now.
    static func migrating(baseline: DataModel, at date: Date) -> NamedVersions {
        var named = NamedVersions()
        named.save(baseline, as: migratedName, at: date)
        named.comparison = Comparison(from: migratedName, to: current)
        return named
    }

    // MARK: The file

    init() {}

    init(fileData data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(NamedVersions.self, from: data)
        for index in versions.indices { versions[index].model.repair() }
    }

    var fileData: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(self)
        }
    }
}
