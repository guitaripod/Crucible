import Foundation

/// The Year in Review card of the You tab: this year's hours (or plays while runtimes are unknown),
/// a one-line detail and a three-row heat strip of the last 78 days. Any screen that shows the card
/// builds it with ``load()``; it is nil when there is no store or nothing was watched yet.
package struct YearInReviewSummary: Equatable, Sendable {
    package var caption: String
    package var primary: String
    package var unit: String
    package var detail: String
    package var strip: [Int]

    package static let stripColumns = 26
    package static let stripRows = 3

    package static var stripCount: Int { stripColumns * stripRows }

    package var spokenText: String {
        "\(caption.capitalized). \(primary) \(unit). \(detail). Statistics"
    }

    /// Builds the card from the shared statistics mirror.
    @MainActor
    package static func load() async -> YearInReviewSummary? {
        guard let store = StatsManager.shared.store else { return nil }
        return await load(store: store)
    }

    package static func load(store: StatsStore) async -> YearInReviewSummary? {
        guard let snapshot = try? await store.snapshot(range: .year) else { return nil }
        return YearInReviewSummary(snapshot: snapshot)
    }

    package init?(snapshot: StatsSnapshot, time: StatsTime = StatsTime(), now: Date = Date()) {
        guard !snapshot.isEmpty else { return nil }
        let overview = snapshot.overview
        let year = time.calendar.component(.year, from: now)

        let primary: String
        let unit: String
        if let hours = overview.estHours {
            let rounded = Int(hours.rounded())
            primary = rounded == 0 ? "<1" : "\(rounded)"
            unit = rounded == 1 ? "hour" : "hours"
        } else {
            primary = "\(overview.totalPlays)"
            unit = overview.totalPlays == 1 ? "play" : "plays"
        }

        var parts = [String]()
        if overview.moviesWatched > 0 { parts.append("\(overview.moviesWatched) \(overview.moviesWatched == 1 ? "movie" : "movies")") }
        if overview.episodes > 0 { parts.append("\(overview.episodes) \(overview.episodes == 1 ? "episode" : "episodes")") }
        if overview.currentStreak > 0 { parts.append("\(overview.currentStreak)-day streak") }

        caption = "\(year) SO FAR"
        self.primary = primary
        self.unit = unit
        detail = parts.joined(separator: " · ")
        strip = Self.stripLevels(from: snapshot.heatmap, today: time.todayDayEpoch(now: now))
    }

    /// Last 78 days, three days per column, bucketed into 0...5 by quantile so light watchers still get contrast.
    package static func stripLevels(from days: [DayCount], today: Int) -> [Int] {
        var counts = [Int: Int]()
        for day in days { counts[day.dayEpoch] = day.count }
        let window = (0..<stripCount).map { counts[today - (stripCount - 1) + $0] ?? 0 }
        let positives = window.filter { $0 > 0 }.sorted()
        guard !positives.isEmpty else { return Array(repeating: 0, count: stripCount) }
        let thresholds = [0.2, 0.4, 0.6, 0.8].map { positives[min(positives.count - 1, Int(Double(positives.count - 1) * $0))] }
        return window.map { count in
            count == 0 ? 0 : min(5, 1 + thresholds.filter { count > $0 }.count)
        }
    }
}
