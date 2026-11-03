import Foundation

/// A row Home can show. The hero belongs to whichever of Continue Watching and Up Next it was lifted from.
package enum HomeRow: String, CaseIterable, Codable, Sendable {
    case continueWatching
    case upNext
    case thisWeek
    case recentlyAdded
    case rateWatched

    package var title: String {
        switch self {
        case .continueWatching: return String(localized: "Continue Watching")
        case .upNext: return String(localized: "Up Next")
        case .thisWeek: return String(localized: "This Week", comment: "Name of the Home row that shows this week's watch time")
        case .recentlyAdded: return String(localized: "Recently Added")
        case .rateWatched: return RatingAskCopy.rowTitle
        }
    }

    package var symbol: String {
        switch self {
        case .continueWatching: return "play.circle"
        case .upNext: return "forward.end"
        case .thisWeek: return "chart.bar"
        case .recentlyAdded: return "sparkles.tv"
        case .rateWatched: return "star"
        }
    }

    package var explanation: String {
        switch self {
        case .continueWatching: return String(localized: "Movies and episodes you started, with the latest one as the big card at the top.")
        case .upNext: return String(localized: "The next episode of each show you are watching.")
        case .thisWeek: return String(localized: "This week's watch time, with a link to Statistics.")
        case .recentlyAdded: return String(localized: "What arrived on your server most recently.")
        case .rateWatched: return String(localized: "Movies and shows you just finished and have not rated yet.")
        }
    }
}

/// Which Home rows show and in what order, as the viewer arranged them in Settings. Every row is always present exactly
/// once; a row added in a later version joins at its default place, switched on.
@MainActor
package enum HomeLayout {
    package struct Entry: Codable, Equatable, Sendable {
        package let row: HomeRow
        package var isOn: Bool

        package init(row: HomeRow, isOn: Bool) {
            self.row = row
            self.isOn = isOn
        }
    }

    package static let storageKey = "homeRows.v1"
    package static let defaultEntries = HomeRow.allCases.map { Entry(row: $0, isOn: true) }
    private static var observers = [UUID: @MainActor () -> Void]()

    package static func entries(in defaults: UserDefaults = .standard) -> [Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return defaultEntries }
        return normalized(saved)
    }

    package static func save(_ entries: [Entry], in defaults: UserDefaults = .standard) {
        let normalized = normalized(entries)
        guard normalized != Self.entries(in: defaults) else { return }
        if normalized == defaultEntries {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: storageKey)
        }
        notify()
    }

    package static func isOn(_ row: HomeRow, in defaults: UserDefaults = .standard) -> Bool {
        entries(in: defaults).first { $0.row == row }?.isOn ?? true
    }

    package static func setOn(_ row: HomeRow, _ isOn: Bool, in defaults: UserDefaults = .standard) {
        save(entries(in: defaults).map { $0.row == row ? Entry(row: row, isOn: isOn) : $0 }, in: defaults)
    }

    /// Moves the row at `source` to `destination` in the full list of rows.
    package static func move(from source: Int, to destination: Int, in defaults: UserDefaults = .standard) {
        var current = entries(in: defaults)
        guard current.indices.contains(source), current.indices.contains(destination), source != destination else { return }
        let entry = current.remove(at: source)
        current.insert(entry, at: destination)
        save(current, in: defaults)
    }

    package static func reset(in defaults: UserDefaults = .standard) {
        save(defaultEntries, in: defaults)
    }

    /// The rows to draw, in order.
    package static func visibleRows(in defaults: UserDefaults = .standard) -> [HomeRow] {
        entries(in: defaults).filter(\.isOn).map(\.row)
    }

    package static var isCustomized: Bool { entries() != defaultEntries }

    /// Every row that shows titles is off, so an empty Home is the viewer's own doing.
    package static var contentRowsAreOff: Bool {
        !visibleRows().contains { [.continueWatching, .upNext, .recentlyAdded].contains($0) }
    }

    @discardableResult
    package static func addObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    package static func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private static func notify() {
        observers.values.forEach { $0() }
    }

    private static func normalized(_ entries: [Entry]) -> [Entry] {
        var seen = Set<HomeRow>()
        var result = entries.filter { seen.insert($0.row).inserted }
        for (index, row) in HomeRow.allCases.enumerated() where !seen.contains(row) {
            result.insert(Entry(row: row, isOn: true), at: min(index, result.count))
        }
        return result
    }
}
