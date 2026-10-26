import Foundation

/// Earlier states of a data model to go back to: not one per change, but the ones most likely wanted. The model as it
/// was opened (and so as each day's work left it), before an AI assistant's changes, before a change that deletes or
/// rearranges tables, and hourly while editing. Thinned as they age: everything from the last two days, then one a day
/// for a month, then one a week.
///
/// They're kept in the model's `.joinery` package, in `Versions`, so they go wherever it goes: renamed, moved, copied,
/// sent. Each is the model's JSON, named for when it was saved and why.
@MainActor
struct History {
    struct Version: Identifiable, Hashable {
        let url: URL
        let date: Date
        let reason: String
        var id: URL { url }
    }

    let folder: URL

    /// The history kept in the `.joinery` package at `url`.
    init(of url: URL) {
        folder = url.appending(path: "Versions", directoryHint: .isDirectory)
    }

    /// Newest first.
    var versions: [Version] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> Version? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", let date = Self.stamp.date(from: String(name.prefix(Self.stampLength))) else { return nil }
            return Version(url: url, date: date, reason: String(name.dropFirst(Self.stampLength + 1)))
        }
        .sorted { $0.date > $1.date }
    }

    /// Saves `model` as a version, unless it's the same as the latest, then thins out old ones.
    func save(_ model: DataModel, reason: String, now: Date = .now) throws {
        let data = try model.fileData
        let latest = versions.first
        if let latest, (try? Data(contentsOf: latest.url)) == data { return }
        // Always after the latest, so they sort in the order they were saved, even within a millisecond.
        let now = max(now, (latest?.date ?? .distantPast).addingTimeInterval(0.001))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reason = reason.replacing("/", with: "-").replacing(":", with: "-")
        try data.write(to: folder.appending(path: "\(Self.stamp.string(from: now)) \(reason).json"), options: .atomic)
        let versions = versions
        let kept = Self.kept(versions.map(\.date), now: now)
        for (index, version) in versions.enumerated() where !kept.contains(index) {
            try? FileManager.default.removeItem(at: version.url)
        }
    }

    /// Which of `dates` (newest first) to keep: all from the last two days; then the earliest of each day for a month,
    /// the state that day began from; then the earliest of each week.
    static func kept(_ dates: [Date], now: Date) -> Set<Int> {
        let calendar = Calendar.current
        var kept = Set<Int>(), earliest: [DateComponents: Int] = [:]
        for (index, date) in dates.enumerated() {
            let age = now.timeIntervalSince(date)
            if age < 2 * 24 * 3600 {
                kept.insert(index)
                continue
            }
            let bucket = age < 30 * 24 * 3600 ? calendar.dateComponents([.year, .month, .day], from: date)
                : calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            earliest[bucket] = index  // Newest first, so the last one seen is the earliest.
        }
        return kept.union(earliest.values)
    }

    private static let stampLength = 23
    private static let stamp = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        return formatter
    }()
}
