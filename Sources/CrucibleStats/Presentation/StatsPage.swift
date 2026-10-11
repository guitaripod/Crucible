import Foundation

/// The sections of a statistics page that carry data, in the order the screens show them. A section is
/// only listed when it has something to draw.
package enum StatsPageSection: Hashable, Sendable {
    case hero, kpis, heatmap, topShows, topMovies, clock, momentum, binges, libraries, genres, onThisDay, superlatives
}

/// Everything a Statistics screen draws for one range, assembled once from a ``StatsSnapshot`` so
/// every platform shows the same numbers, copy and sections. Screens read it; they never recompute it.
package struct StatsPage: Equatable, Sendable {
    package struct Hero: Hashable, Sendable {
        package let eyebrow: String
        package let value: Int
        package let unit: String
        package let detail: String
        package let since: String
    }

    package struct Tile: Hashable, Sendable {
        package let key: String
        package let title: String
        package let value: String
        package let systemImage: String
        package let caption: String?
        package let sparkline: [Int]
    }

    package struct LongestBinge: Hashable, Sendable {
        package let value: String
        package let date: String
    }

    package struct ShowRow: Hashable, Sendable {
        package let rank: Int
        package let ratingKey: String
        package let title: String
        package let thumb: String?
        package let valueText: String
        package let fraction: Double
        package let completion: Double?
    }

    package struct GenreRow: Hashable, Sendable {
        package let title: String
        package let valueText: String
        package let fraction: Double
        package let colorIndex: Int
        package let accessibilityLabel: String
    }

    package struct GenresPending: Hashable, Sendable {
        package let title: String
        package let progress: Double
        package let accessibilityLabel: String

        /// The progress bar fill: never empty so the bar reads as started, never past full.
        package var barFraction: Double { max(0.02, min(1, progress)) }
    }

    package enum Genres: Hashable, Sendable {
        case pending(GenresPending)
        case ranked([GenreRow])
    }

    package struct Momentum: Hashable, Sendable {
        package let values: [Double]
        package let peakText: String?
        package let summary: String
    }

    package struct Clock: Hashable, Sendable {
        package let hours: [Int]
        package let weekdays: [Int]
        package let verdict: String
        package let accessibilitySummary: String
    }

    package struct LegendRow: Hashable, Sendable {
        package let colorIndex: Int
        package let title: String
        package let value: String
    }

    package struct Libraries: Hashable, Sendable {
        package let segments: [DonutSegment]
        package let centerTitle: String
        package let centerSubtitle: String
        package let legend: [LegendRow]
        package let accessibilitySummary: String
    }

    package let range: StatsRange
    package let snapshot: StatsSnapshot
    package let heatmap: HeatmapModel
    package let hero: Hero
    package let tiles: [Tile]
    package let longestBinge: LongestBinge?
    package let topShows: [ShowRow]
    package let topMovies: [StatsPoster]
    package let onThisDay: [StatsPoster]
    package let clock: Clock
    package let momentum: Momentum?
    package let libraries: Libraries
    package let genres: Genres
    package let sections: [StatsPageSection]

    package var isEmpty: Bool { snapshot.isEmpty }
    package var binges: [BingeSession] { snapshot.binges }
    package var superlatives: [Superlative] { snapshot.superlatives }

    /// The page for an empty or not-yet-loaded store: no sections, every screen shows a placeholder.
    package static let empty = StatsPage(snapshot: StatsSnapshot(), range: .year)

    package init(snapshot: StatsSnapshot, range: StatsRange, time: StatsTime = StatsTime(), now: Date = Date()) {
        self.range = range
        self.snapshot = snapshot
        heatmap = time.heatmapModel(days: snapshot.heatmap, today: time.todayDayEpoch(now: now))
        let verdict = Self.watchVerdict(snapshot)
        let binge = Self.longestBinge(snapshot)
        longestBinge = binge
        hero = Self.hero(snapshot, range: range, verdict: verdict, time: time, now: now)
        tiles = Self.tiles(snapshot, binge: binge)
        topShows = Self.topShows(snapshot)
        topMovies = snapshot.topMovies.map { StatsPoster($0) }
        onThisDay = snapshot.onThisDay.map { StatsPoster(onThisDay: $0) }
        clock = Clock(
            hours: snapshot.hourHistogram,
            weekdays: snapshot.weekdayHistogram,
            verdict: verdict,
            accessibilitySummary: Self.clockSummary(snapshot.hourHistogram)
        )
        momentum = Self.momentum(snapshot)
        libraries = Self.libraries(snapshot)
        genres = Self.genres(snapshot)
        sections = Self.sections(snapshot, heatmap: heatmap, tiles: tiles)
    }

    private static func sections(_ snapshot: StatsSnapshot, heatmap: HeatmapModel, tiles: [Tile]) -> [StatsPageSection] {
        guard !snapshot.isEmpty else { return [] }
        var sections: [StatsPageSection] = [.hero]
        if !tiles.isEmpty { sections.append(.kpis) }
        if !heatmap.cells.isEmpty { sections.append(.heatmap) }
        if !snapshot.topShows.isEmpty { sections.append(.topShows) }
        if !snapshot.topMovies.isEmpty { sections.append(.topMovies) }
        sections.append(.clock)
        if snapshot.monthly.count >= 2 { sections.append(.momentum) }
        if !snapshot.binges.isEmpty { sections.append(.binges) }
        if snapshot.libraries.count >= 2 { sections.append(.libraries) }
        if !snapshot.genres.isEmpty || snapshot.enrichment.genreCoverage < 0.5 { sections.append(.genres) }
        if !snapshot.onThisDay.isEmpty { sections.append(.onThisDay) }
        if !snapshot.superlatives.isEmpty { sections.append(.superlatives) }
        return sections
    }

    private static func tiles(_ snapshot: StatsSnapshot, binge: LongestBinge?) -> [Tile] {
        let o = snapshot.overview
        let streakCaption = o.longestStreak > o.currentStreak ? "days · best \(o.longestStreak)" : "days"
        var tiles: [Tile] = [
            Tile(key: "days", title: "Days Active", value: "\(o.daysActive)", systemImage: "calendar", caption: nil, sparkline: snapshot.weeklySparkline),
            Tile(key: "streak", title: "Streak", value: "\(o.currentStreak)", systemImage: "flame", caption: streakCaption, sparkline: []),
            Tile(key: "shows", title: "Shows", value: StatsFormat.abbreviatedCount(o.showsWatched), systemImage: "tv", caption: nil, sparkline: []),
            Tile(key: "movies", title: "Movies", value: StatsFormat.abbreviatedCount(o.moviesWatched), systemImage: "film", caption: nil, sparkline: []),
            Tile(key: "episodes", title: "Episodes", value: StatsFormat.abbreviatedCount(o.episodes), systemImage: "play", caption: nil, sparkline: []),
        ]
        if let binge {
            tiles.append(Tile(key: "binge", title: "Longest Binge", value: binge.value, systemImage: "clock", caption: binge.date, sparkline: []))
        }
        return tiles
    }

    /// The longest session by wall-clock span, formatted as "9 h" / "45 min" plus its start date.
    private static func longestBinge(_ snapshot: StatsSnapshot) -> LongestBinge? {
        guard let session = snapshot.binges.max(by: { $0.endViewedAt - $0.startViewedAt < $1.endViewedAt - $1.startViewedAt }) else { return nil }
        let seconds = session.endViewedAt - session.startViewedAt
        guard seconds >= 60 else { return nil }
        let value = seconds >= 3600 ? "\(Int((Double(seconds) / 3600).rounded())) h" : "\(seconds / 60) min"
        let date = Date(timeIntervalSince1970: TimeInterval(session.startViewedAt)).formatted(.dateTime.month(.abbreviated).day())
        return LongestBinge(value: value, date: date)
    }

    /// Hero copy: the verdict as eyebrow, estimated hours (or plays while runtimes are unknown) as the big number.
    private static func hero(_ snapshot: StatsSnapshot, range: StatsRange, verdict: String, time: StatsTime, now: Date) -> Hero {
        let o = snapshot.overview
        let eyebrow = verdict.isEmpty ? "Your viewing" : verdict
        let phrase = rangePhrase(range, time: time, now: now)
        let since = subtitle(snapshot)
        guard let hours = o.estHours, hours >= 0.5 else {
            return Hero(eyebrow: eyebrow, value: o.totalPlays, unit: o.totalPlays == 1 ? "play" : "plays", detail: "watched \(phrase)", since: since)
        }
        let value = Int(hours.rounded())
        let pct = Int((o.coverage * 100).rounded())
        return Hero(eyebrow: eyebrow, value: value, unit: value == 1 ? "hour" : "hours", detail: "watched \(phrase) · estimate, \(pct)% counted", since: since)
    }

    private static func rangePhrase(_ range: StatsRange, time: StatsTime, now: Date) -> String {
        switch range {
        case .week: return "in the last 7 days"
        case .month: return "in the last 30 days"
        case .year: return "in \(time.calendar.component(.year, from: now))"
        case .allTime: return "in total"
        }
    }

    private static func subtitle(_ snapshot: StatsSnapshot) -> String {
        guard let since = snapshot.overview.memberSinceViewedAt else { return "Your viewing, visualized" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return "Watching since \(formatter.string(from: Date(timeIntervalSince1970: TimeInterval(since))))"
    }

    /// A one-line personality for the viewing pattern; empty when nothing was watched.
    private static func watchVerdict(_ snapshot: StatsSnapshot) -> String {
        let hours = snapshot.hourHistogram
        let total = hours.reduce(0, +)
        guard total > 0 else { return "" }
        let lateNight = hours[0...4].reduce(0, +) + hours[22...23].reduce(0, +)
        let morning = hours[5...10].reduce(0, +)
        let wd = snapshot.weekdayHistogram
        let weekend = wd[0] + wd[6]
        let weekdayTotal = max(1, wd.reduce(0, +))
        if Double(lateNight) / Double(total) > 0.33 { return "You're a Night Owl" }
        if Double(morning) / Double(total) > 0.33 { return "You're an Early Bird" }
        if Double(weekend) / Double(weekdayTotal) > 0.45 { return "You're a Weekend Warrior" }
        return "You're a Prime-Time Viewer"
    }

    private static func topShows(_ snapshot: StatsSnapshot) -> [ShowRow] {
        let maxCount = max(1, snapshot.topShows.first?.count ?? 1)
        return snapshot.topShows.enumerated().map { index, show in
            let episodes = show.watchedEpisodes ?? show.count
            return ShowRow(
                rank: index + 1,
                ratingKey: show.ratingKey,
                title: show.title,
                thumb: show.thumb,
                valueText: episodes == 1 ? "1 ep" : "\(episodes) eps",
                fraction: Double(show.count) / Double(maxCount),
                completion: show.completion
            )
        }
    }

    private static func genres(_ snapshot: StatsSnapshot) -> Genres {
        guard !snapshot.genres.isEmpty else {
            let progress = snapshot.enrichment.genreCoverage
            return .pending(GenresPending(
                title: "Analyzing your taste…",
                progress: progress,
                accessibilityLabel: "Analyzing your taste, \(Int((progress * 100).rounded())) percent"
            ))
        }
        let maxCount = max(1, snapshot.genres.first?.count ?? 1)
        return .ranked(snapshot.genres.enumerated().map { index, genre in
            GenreRow(
                title: genre.genre,
                valueText: "\(genre.count)",
                fraction: Double(genre.count) / Double(maxCount),
                colorIndex: index,
                accessibilityLabel: "\(genre.genre), \(genre.count) plays"
            )
        })
    }

    private static func momentum(_ snapshot: StatsSnapshot) -> Momentum? {
        guard snapshot.monthly.count >= 2 else { return nil }
        var summary = "Plays per month."
        var peakText: String?
        if let peak = snapshot.monthly.max(by: { $0.count < $1.count }) {
            let (year, month) = StatsTime.monthEpochToYearMonth(peak.monthEpoch)
            let text = "\(StatsTime.monthSymbols[max(0, min(11, month - 1))]) \(year)"
            peakText = text
            summary += " Peak in \(text) with \(peak.count) plays."
        }
        return Momentum(values: snapshot.monthly.map { Double($0.count) }, peakText: peakText, summary: summary)
    }

    private static func libraries(_ snapshot: StatsSnapshot) -> Libraries {
        let slices = snapshot.libraries
        let total = slices.reduce(0) { $0 + $1.count }
        let legendSlices = slices.prefix(6)
        return Libraries(
            segments: slices.enumerated().map { DonutSegment(label: $0.element.title, value: $0.element.count, colorIndex: $0.offset) },
            centerTitle: StatsFormat.abbreviatedCount(total),
            centerSubtitle: "plays",
            legend: legendSlices.enumerated().map { LegendRow(colorIndex: $0.offset, title: $0.element.title, value: StatsFormat.abbreviatedCount($0.element.count)) },
            accessibilitySummary: "Plays by library. " + legendSlices.map { "\($0.title), \($0.count)" }.joined(separator: ". ")
        )
    }

    /// VoiceOver summary for the 24-hour clock: the busiest hour and its share of plays.
    private static func clockSummary(_ hours: [Int]) -> String {
        let total = hours.reduce(0, +)
        guard total > 0, let peak = hours.max(), let hour = hours.firstIndex(of: peak) else { return "Plays by hour of day." }
        let label = "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
        let share = Int((Double(peak) / Double(total) * 100).rounded())
        return "Plays by hour of day. Busiest at \(label), \(share) percent of plays."
    }
}
