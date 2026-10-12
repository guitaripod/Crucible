import Foundation

/// Builds the viewing history of the last twelve months, relative to today: evening sessions, long weekend afternoons, the odd
/// binge, a quiet week now and then, and a run of recent days. Each calendar day is decided by its own date, so the same day always
/// holds the same plays however often the app is opened, and every new day adds new ones.
enum DemoHistory {
    struct Playable {
        let key: String
        let durationMs: Int
    }

    struct Series {
        let title: String
        let weight: Int
        let episodes: [Playable]
    }

    private static let weights = [
        "The Salt Road": 22, "Meridian": 18, "Ironwood": 12, "Northbound": 6,
        "Paper Lanterns": 4, "Kestrel Row": 8, "Halftide": 8, "Dry Season": 3,
    ]
    private static let originComponents = DateComponents(year: 2025, month: 1, day: 1)
    private static let windowDays = 365
    private static let guaranteedRecentDays = 2
    private static let latestPlayAge = 6 * 3600

    static func build(items: [String: DemoItem], showKeys: [String], movieKeys: [String], now: Date) -> [DemoHistoryRow] {
        let nowSeconds = Int(now.timeIntervalSince1970)
        let series = showKeys.compactMap { series(for: $0, in: items) }
        let movies = movieKeys.compactMap { items[$0] }.filter(\.isWatched).map { Playable(key: $0.ratingKey, durationMs: $0.durationMs) }
        var plays = generate(series: series, movies: movies, now: now, calendar: .current)
        plays = plays.filter { $0.viewedAt <= nowSeconds - latestPlayAge && $0.viewedAt >= nowSeconds - windowDays * 86400 }
        plays += recentPlays(items: items, now: nowSeconds)
        plays.sort { ($0.viewedAt, $0.key) < ($1.viewedAt, $1.key) }
        return plays.enumerated().map { DemoHistoryRow(id: $0.offset + 1, ratingKey: $0.element.key, viewedAt: $0.element.viewedAt) }
    }

    private static func series(for showKey: String, in items: [String: DemoItem]) -> Series? {
        guard let show = items[showKey] else { return nil }
        let watched = show.children
            .flatMap { items[$0]?.children ?? [] }
            .compactMap { items[$0] }
            .filter(\.isWatched)
            .map { Playable(key: $0.ratingKey, durationMs: $0.durationMs) }
        guard !watched.isEmpty else { return nil }
        return Series(title: show.title, weight: weights[show.title] ?? 3, episodes: watched)
    }

    struct Play {
        let key: String
        let viewedAt: Int
    }

    /// The plays of the last few hours: the movie finished a couple of hours ago and the three episodes before it.
    private static func recentPlays(items: [String: DemoItem], now: Int) -> [Play] {
        var plays = [Play]()
        if let movie = items.values.first(where: { $0.kind == .movie && $0.title == "Halcyon" }) {
            plays.append(Play(key: movie.ratingKey, viewedAt: now - 2 * 3600))
        }
        let offsets = [3: 3 * 3600 + 600, 2: 4 * 3600, 1: 4 * 3600 + 3000]
        for (index, offset) in offsets {
            let episode = items.values.first {
                $0.kind == .episode && $0.fields.string("grandparentTitle") == "The Salt Road"
                    && $0.fields.int("parentIndex") == 2 && $0.fields.int("index") == index
            }
            if let episode { plays.append(Play(key: episode.ratingKey, viewedAt: now - offset)) }
        }
        return plays
    }

    static func generate(series: [Series], movies: [Playable], now: Date, calendar: Calendar) -> [Play] {
        guard !series.isEmpty || !movies.isEmpty, let origin = calendar.date(from: originComponents) else { return [] }
        let today = calendar.startOfDay(for: now)
        let lastIndex = max(0, calendar.dateComponents([.day], from: origin, to: today).day ?? 0)
        var cursors = series.map { startingCursor(for: $0) }
        var plays = [Play]()
        var run = 0
        for index in 0...lastIndex {
            guard let day = calendar.date(byAdding: .day, value: index, to: origin) else { continue }
            let age = lastIndex - index
            var random = DemoRandom(UInt64(index), 0xA11CE)
            let parts = calendar.dateComponents([.weekday, .month], from: day)
            let weekend = parts.weekday == 1 || parts.weekday == 7
            let active = isActive(index: index, age: age, weekend: weekend, month: parts.month ?? 1, run: run, random: &random)
            run = active ? run + 1 : 0
            guard active else { continue }
            let bingeRoll = random.int(0...39)
            let isBinge = weekend && age >= 10 && bingeRoll == 0
            let context = DayContext(day: day, calendar: calendar)
            if isBinge, !series.isEmpty {
                let show = random.weightedIndex(series.map(\.weight))
                plays += episodeRun(show, count: random.int(10...13), start: context.time(hour: 11, minute: random.int(0...50)), series: series, cursors: &cursors, random: &random, gap: 0...1)
                continue
            }
            for session in sessions(weekend: weekend, random: &random) {
                let start = context.time(hour: session.hour, minute: random.int(0...55))
                if !movies.isEmpty, series.isEmpty || random.chance(weekend ? 0.4 : 0.2) {
                    plays.append(Play(key: random.pick(movies).key, viewedAt: start))
                } else {
                    let show = random.weightedIndex(series.map(\.weight))
                    plays += episodeRun(show, count: session.count, start: start, series: series, cursors: &cursors, random: &random, gap: 0...9)
                }
            }
        }
        return plays
    }

    private static func startingCursor(for series: Series) -> Int {
        var random = DemoRandom(series.title.hashValueStable, 0xC0DE)
        return random.int(0...max(0, series.episodes.count - 1))
    }

    private struct DayContext {
        let day: Date
        let calendar: Calendar

        func time(hour: Int, minute: Int) -> Int {
            let moment = calendar.date(bySettingHour: min(hour, 23), minute: minute, second: 0, of: day) ?? day
            return Int(moment.timeIntervalSince1970)
        }
    }

    private struct Session {
        let hour: Int
        let count: Int
    }

    private static func isActive(index: Int, age: Int, weekend: Bool, month: Int, run: Int, random: inout DemoRandom) -> Bool {
        let roll = random.unit()
        let longestRun = random.int(6...12)
        var probability = weekend ? 0.8 : 0.5
        if [11, 12, 1, 2].contains(month) { probability += 0.1 }
        if [6, 7, 8].contains(month) { probability -= 0.12 }
        var quietWeek = DemoRandom(UInt64(index / 7), 0xFACE)
        let isQuiet = quietWeek.int(0...9) == 0
        if age <= guaranteedRecentDays { return true }
        return roll < probability && !isQuiet && run < longestRun
    }

    private static func sessions(weekend: Bool, random: inout DemoRandom) -> [Session] {
        if weekend {
            var sessions = [Session(hour: random.pick([14, 15, 17, 19, 20]), count: random.int(3...5))]
            if random.chance(0.4) { sessions.append(Session(hour: random.pick([22, 23]), count: random.int(1...3))) }
            return sessions
        }
        let hour = [20, 21, 22, 23][random.weightedIndex([2, 4, 3, 1])]
        return [Session(hour: hour, count: random.int(2...3))]
    }

    private static func episodeRun(
        _ show: Int,
        count: Int,
        start: Int,
        series: [Series],
        cursors: inout [Int],
        random: inout DemoRandom,
        gap: ClosedRange<Int>
    ) -> [Play] {
        var plays = [Play]()
        var moment = start
        let episodes = series[show].episodes
        for _ in 0..<count {
            let episode = episodes[cursors[show] % episodes.count]
            cursors[show] += 1
            plays.append(Play(key: episode.key, viewedAt: moment))
            moment += episode.durationMs / 1000 + random.int(gap) * 60
        }
        return plays
    }
}

private extension String {
    /// A hash that does not change between launches, unlike `hashValue`.
    var hashValueStable: UInt64 {
        utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }
}
