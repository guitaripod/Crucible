import Foundation
import GRDB

/// All reads and writes over the local watch-history mirror. Every method runs on GRDB's own
/// queue (off the main thread) via the async read/write APIs.
struct StatsStore: Sendable {
    let database: StatsDatabase
    private var dbQueue: DatabaseQueue { database.dbQueue }

    private static let bingeGapSeconds = 5400
    private static let bingeMinEpisodes = 3
    private static let heatmapDays = 371
    private static let sparklineWeeks = 26

    // MARK: - Sync state

    func syncState() async throws -> SyncState {
        let tz = TimeZone.current.identifier
        return try await dbQueue.write { db in
            if let existing = try SyncState.fetchOne(db, key: SyncState.singletonID) {
                return existing
            }
            let fresh = SyncState.initial(tzIdentifier: tz)
            try fresh.insert(db)
            return fresh
        }
    }

    func saveSyncState(_ state: SyncState) async throws {
        try await dbQueue.write { db in
            try state.save(db)
        }
    }

    // MARK: - History ingestion

    /// Inserts a page of plays (duplicates dropped by the UNIQUE(ratingKey, viewedAt) ON CONFLICT
    /// IGNORE constraint). Returns the current total row count.
    @discardableResult
    func insertPlays(_ plays: [Play]) async throws -> Int {
        try await dbQueue.write { db in
            for play in plays {
                var mutable = play
                try mutable.insert(db)
            }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play") ?? 0
        }
    }

    func totalRows() async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play") ?? 0
        }
    }

    /// Re-derives every precomputed local-time column against the current calendar/timezone.
    func recomputeLocalTimeColumns() async throws {
        let time = StatsTime()
        try await dbQueue.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, viewedAt FROM play")
            for row in rows {
                let id: Int64 = row["id"]
                let viewedAt: Int = row["viewedAt"]
                let c = time.components(forViewedAt: viewedAt)
                try db.execute(sql: """
                    UPDATE play SET dayEpoch = ?, hourLocal = ?, weekday = ?, monthEpoch = ?, monthDay = ?, year = ?
                    WHERE id = ?
                    """, arguments: [c.dayEpoch, c.hourLocal, c.weekday, c.monthEpoch, c.monthDay, c.year, id])
            }
        }
    }

    // MARK: - Enrichment

    /// Distinct played items lacking a runtime cache row, newest first.
    func itemsNeedingRuntime(limit: Int) async throws -> [(ratingKey: String, type: String?)] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.ratingKey AS rk, MAX(p.type) AS ty
                FROM play p
                LEFT JOIN item_meta im ON im.ratingKey = p.ratingKey
                WHERE im.ratingKey IS NULL
                GROUP BY p.ratingKey
                ORDER BY MAX(p.viewedAt) DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.map { ($0["rk"], $0["ty"]) }
        }
    }

    /// Distinct shows lacking a leafCount cache row, by most recent activity.
    func showsNeedingMeta(limit: Int) async throws -> [String] {
        try await dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT p.grandparentRatingKey
                FROM play p
                LEFT JOIN show_meta sm ON sm.ratingKey = p.grandparentRatingKey
                WHERE p.type = 'episode' AND p.grandparentRatingKey IS NOT NULL AND sm.ratingKey IS NULL
                GROUP BY p.grandparentRatingKey
                ORDER BY MAX(p.viewedAt) DESC
                LIMIT ?
                """, arguments: [limit])
        }
    }

    func saveItemMeta(_ meta: ItemMeta, genres: [String]) async throws {
        try await dbQueue.write { db in
            try meta.save(db)
            try db.execute(sql: "DELETE FROM genre_link WHERE ownerKey = ?", arguments: [meta.ratingKey])
            for genre in genres where !genre.isEmpty {
                try GenreLink(ownerKey: meta.ratingKey, genre: genre).insert(db, onConflict: .ignore)
            }
        }
    }

    func saveShowMeta(_ meta: ShowMeta, genres: [String]) async throws {
        try await dbQueue.write { db in
            try meta.save(db)
            try db.execute(sql: "DELETE FROM genre_link WHERE ownerKey = ?", arguments: [meta.ratingKey])
            for genre in genres where !genre.isEmpty {
                try GenreLink(ownerKey: meta.ratingKey, genre: genre).insert(db, onConflict: .ignore)
            }
        }
    }

    // MARK: - Snapshot

    func snapshot(range: StatsRange) async throws -> StatsSnapshot {
        let time = StatsTime()
        let lowerBound = range.lowerViewedAt() ?? 0
        let today = time.todayDayEpoch()
        let currentYear = time.components(forViewedAt: Int(Date().timeIntervalSince1970)).year
        let todayMonthDay = time.components(forViewedAt: Int(Date().timeIntervalSince1970)).monthDay

        return try await dbQueue.read { db in
            let scope = try Self.accountScope(db)
            var snap = StatsSnapshot()
            snap.overview = try Self.overview(db, lowerBound: lowerBound, today: today, scope: scope)
            snap.weeklySparkline = try Self.weeklySparkline(db, today: today, scope: scope)
            snap.heatmap = try Self.heatmap(db, sinceDay: today - Self.heatmapDays, scope: scope)
            snap.hourHistogram = try Self.hourHistogram(db, lowerBound: lowerBound, scope: scope)
            snap.weekdayHistogram = try Self.weekdayHistogram(db, lowerBound: lowerBound, scope: scope)
            snap.monthly = try Self.monthly(db, lowerBound: lowerBound, scope: scope)
            snap.topShows = try Self.topShows(db, lowerBound: lowerBound, scope: scope)
            snap.topMovies = try Self.topMovies(db, lowerBound: lowerBound, scope: scope)
            snap.libraries = try Self.libraries(db, lowerBound: lowerBound, scope: scope)
            snap.binges = try Self.binges(db, lowerBound: lowerBound, scope: scope)
            snap.genres = try Self.genres(db, lowerBound: lowerBound, scope: scope)
            snap.onThisDay = try Self.onThisDay(db, monthDay: todayMonthDay, currentYear: currentYear, scope: scope)
            snap.enrichment = try Self.enrichment(db, lowerBound: lowerBound, scope: scope)
            snap.superlatives = try Self.superlatives(
                db, lowerBound: lowerBound, time: time, scope: scope,
                hourHistogram: snap.hourHistogram, longestStreak: snap.overview.longestStreak,
                binges: snap.binges
            )
            return snap
        }
    }

    /// On a multi-user server accessed with the owner token, history spans every account. When more
    /// than one account is present we scope every aggregate to the server owner (account id 1);
    /// single-user and auto-scoped shared-user mirrors contain one account and are left unfiltered.
    private static func accountScope(_ db: Database) throws -> Int? {
        let distinct = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT accountID) FROM play WHERE accountID IS NOT NULL") ?? 0
        guard distinct > 1 else { return nil }
        let ownerRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play WHERE accountID = 1") ?? 0
        return ownerRows > 0 ? 1 : nil
    }

    private static func clause(_ scope: Int?, column: String = "accountID") -> String {
        scope.map { " AND \(column) = \($0)" } ?? ""
    }

    /// Titles watched on a specific local day, for the heatmap drill-down.
    func plays(onDayEpoch dayEpoch: Int) async throws -> [OnThisDayItem] {
        try await dbQueue.read { db in
            let acct = Self.clause(try Self.accountScope(db))
            let rows = try Row.fetchAll(db, sql: """
                SELECT ratingKey, type, title, grandparentTitle, grandparentRatingKey, thumb, grandparentThumb, year
                FROM play WHERE dayEpoch = ?\(acct) ORDER BY viewedAt DESC
                """, arguments: [dayEpoch])
            return rows.map { row in
                OnThisDayItem(
                    ratingKey: row["ratingKey"],
                    type: row["type"],
                    title: row["title"] ?? "Unknown",
                    grandparentTitle: row["grandparentTitle"],
                    grandparentRatingKey: row["grandparentRatingKey"],
                    thumb: row["thumb"],
                    grandparentThumb: row["grandparentThumb"],
                    yearsAgo: 0
                )
            }
        }
    }

    // MARK: - Individual queries

    private static func overview(_ db: Database, lowerBound: Int, today: Int, scope: Int?) throws -> StatsOverview {
        let acct = clause(scope)
        let acctP = clause(scope, column: "p.accountID")
        var o = StatsOverview()
        o.totalPlays = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play WHERE viewedAt >= ?\(acct)", arguments: [lowerBound]) ?? 0
        guard o.totalPlays > 0 else { return o }

        o.episodes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play WHERE viewedAt >= ? AND type = 'episode'\(acct)", arguments: [lowerBound]) ?? 0
        o.moviesWatched = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT ratingKey) FROM play WHERE viewedAt >= ? AND type = 'movie'\(acct)", arguments: [lowerBound]) ?? 0
        o.showsWatched = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT grandparentRatingKey) FROM play WHERE viewedAt >= ? AND type = 'episode' AND grandparentRatingKey IS NOT NULL\(acct)", arguments: [lowerBound]) ?? 0
        o.daysActive = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT dayEpoch) FROM play WHERE viewedAt >= ?\(acct)", arguments: [lowerBound]) ?? 0

        let days = try Int.fetchAll(db, sql: "SELECT DISTINCT dayEpoch FROM play WHERE viewedAt >= ?\(acct) ORDER BY dayEpoch", arguments: [lowerBound])
        o.currentStreak = currentStreak(days: days, today: today)
        o.longestStreak = longestStreak(days: days)

        if let row = try Row.fetchOne(db, sql: "SELECT viewedAt, title, grandparentTitle FROM play WHERE 1=1\(acct) ORDER BY viewedAt ASC LIMIT 1") {
            o.memberSinceViewedAt = row["viewedAt"]
            o.firstTitle = row["grandparentTitle"] ?? row["title"]
        }

        let knownMs = try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(im.durationMs), 0) FROM play p
            JOIN item_meta im ON im.ratingKey = p.ratingKey
            WHERE p.viewedAt >= ? AND im.durationMs IS NOT NULL\(acctP)
            """, arguments: [lowerBound]) ?? 0
        let coveredPlays = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM play p
            JOIN item_meta im ON im.ratingKey = p.ratingKey
            WHERE p.viewedAt >= ? AND im.durationMs IS NOT NULL\(acctP)
            """, arguments: [lowerBound]) ?? 0
        o.coverage = o.totalPlays > 0 ? Double(coveredPlays) / Double(o.totalPlays) : 0
        if o.coverage >= 0.10 {
            o.estHours = Double(knownMs) / 3_600_000.0 / max(o.coverage, 0.0001)
        }
        return o
    }

    private static func currentStreak(days: [Int], today: Int) -> Int {
        guard !days.isEmpty else { return 0 }
        let set = Set(days)
        var cursor = set.contains(today) ? today : today - 1
        var streak = 0
        while set.contains(cursor) {
            streak += 1
            cursor -= 1
        }
        return streak
    }

    private static func longestStreak(days: [Int]) -> Int {
        guard !days.isEmpty else { return 0 }
        var best = 1
        var run = 1
        for i in 1..<days.count {
            if days[i] == days[i - 1] + 1 {
                run += 1
                best = max(best, run)
            } else {
                run = 1
            }
        }
        return best
    }

    private static func weeklySparkline(_ db: Database, today: Int, scope: Int?) throws -> [Int] {
        let firstWeek = (today - (sparklineWeeks - 1) * 7) / 7
        let sinceDay = firstWeek * 7
        let rows = try Row.fetchAll(db, sql: """
            SELECT dayEpoch / 7 AS wk, COUNT(*) AS c FROM play
            WHERE dayEpoch >= ?\(clause(scope)) GROUP BY wk
            """, arguments: [sinceDay])
        var buckets = [Int: Int]()
        for row in rows { buckets[row["wk"]] = row["c"] }
        let todayWeek = today / 7
        return (firstWeek...todayWeek).map { buckets[$0] ?? 0 }
    }

    private static func heatmap(_ db: Database, sinceDay: Int, scope: Int?) throws -> [DayCount] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT dayEpoch, COUNT(*) AS c FROM play WHERE dayEpoch >= ?\(clause(scope)) GROUP BY dayEpoch
            """, arguments: [sinceDay])
        return rows.map { DayCount(dayEpoch: $0["dayEpoch"], count: $0["c"]) }
    }

    private static func hourHistogram(_ db: Database, lowerBound: Int, scope: Int?) throws -> [Int] {
        var hours = Array(repeating: 0, count: 24)
        let rows = try Row.fetchAll(db, sql: "SELECT hourLocal, COUNT(*) AS c FROM play WHERE viewedAt >= ?\(clause(scope)) GROUP BY hourLocal", arguments: [lowerBound])
        for row in rows {
            let h: Int = row["hourLocal"]
            if (0..<24).contains(h) { hours[h] = row["c"] }
        }
        return hours
    }

    private static func weekdayHistogram(_ db: Database, lowerBound: Int, scope: Int?) throws -> [Int] {
        var days = Array(repeating: 0, count: 7)
        let rows = try Row.fetchAll(db, sql: "SELECT weekday, COUNT(*) AS c FROM play WHERE viewedAt >= ?\(clause(scope)) GROUP BY weekday", arguments: [lowerBound])
        for row in rows {
            let w: Int = row["weekday"]
            if (1...7).contains(w) { days[w - 1] = row["c"] }
        }
        return days
    }

    private static func monthly(_ db: Database, lowerBound: Int, scope: Int?) throws -> [MonthCount] {
        let rows = try Row.fetchAll(db, sql: "SELECT monthEpoch, COUNT(*) AS c FROM play WHERE viewedAt >= ?\(clause(scope)) GROUP BY monthEpoch ORDER BY monthEpoch", arguments: [lowerBound])
        guard let start: Int = rows.first?["monthEpoch"], let end: Int = rows.last?["monthEpoch"], end >= start else {
            return rows.map { MonthCount(monthEpoch: $0["monthEpoch"], count: $0["c"]) }
        }
        var counts = [Int: Int]()
        for row in rows { counts[row["monthEpoch"]] = row["c"] }
        return (start...end).map { MonthCount(monthEpoch: $0, count: counts[$0] ?? 0) }
    }

    private static func topShows(_ db: Database, lowerBound: Int, scope: Int?) throws -> [ShowStat] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT p.grandparentRatingKey AS k,
                   MAX(p.grandparentTitle) AS title,
                   MAX(p.grandparentThumb) AS thumb,
                   COUNT(*) AS plays,
                   COUNT(DISTINCT p.ratingKey) AS eps,
                   sm.leafCount AS leaf
            FROM play p
            LEFT JOIN show_meta sm ON sm.ratingKey = p.grandparentRatingKey
            WHERE p.type = 'episode' AND p.grandparentRatingKey IS NOT NULL AND p.viewedAt >= ?\(clause(scope, column: "p.accountID"))
            GROUP BY p.grandparentRatingKey
            ORDER BY plays DESC
            LIMIT 10
            """, arguments: [lowerBound])
        return rows.map { row in
            ShowStat(
                ratingKey: row["k"],
                title: row["title"] ?? "Unknown",
                thumb: row["thumb"],
                count: row["plays"],
                watchedEpisodes: row["eps"],
                leafCount: row["leaf"]
            )
        }
    }

    private static func topMovies(_ db: Database, lowerBound: Int, scope: Int?) throws -> [MovieStat] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT ratingKey AS k, MAX(title) AS title, MAX(thumb) AS thumb,
                   COUNT(*) AS plays, MAX(viewedAt) AS last
            FROM play
            WHERE type = 'movie' AND viewedAt >= ?\(clause(scope))
            GROUP BY ratingKey
            ORDER BY plays DESC, last DESC
            LIMIT 20
            """, arguments: [lowerBound])
        return rows.map { row in
            MovieStat(ratingKey: row["k"], title: row["title"] ?? "Unknown", thumb: row["thumb"], count: row["plays"], lastViewedAt: row["last"])
        }
    }

    private static func libraries(_ db: Database, lowerBound: Int, scope: Int?) throws -> [LibrarySlice] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT librarySectionTitle AS t, COUNT(*) AS c FROM play
            WHERE viewedAt >= ? AND librarySectionTitle IS NOT NULL AND librarySectionTitle <> ''\(clause(scope))
            GROUP BY librarySectionTitle ORDER BY c DESC
            """, arguments: [lowerBound])
        return rows.map { LibrarySlice(title: $0["t"], count: $0["c"]) }
    }

    private static func genres(_ db: Database, lowerBound: Int, scope: Int?) throws -> [GenreStat] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT gl.genre AS g, COUNT(*) AS c
            FROM play p
            JOIN genre_link gl ON gl.ownerKey = COALESCE(p.grandparentRatingKey, p.ratingKey)
            WHERE p.viewedAt >= ?\(clause(scope, column: "p.accountID"))
            GROUP BY gl.genre ORDER BY c DESC LIMIT 8
            """, arguments: [lowerBound])
        return rows.map { GenreStat(genre: $0["g"], count: $0["c"]) }
    }

    private static func binges(_ db: Database, lowerBound: Int, scope: Int?) throws -> [BingeSession] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT grandparentRatingKey AS k, grandparentTitle AS title, viewedAt
            FROM play
            WHERE type = 'episode' AND viewedAt >= ?\(clause(scope))
            ORDER BY viewedAt ASC
            """, arguments: [lowerBound])

        var sessions = [BingeSession]()
        var currentKey: String??
        var currentTitle: String?
        var count = 0
        var start = 0
        var lastViewedAt = 0

        func flush() {
            if count >= bingeMinEpisodes, let key = currentKey {
                sessions.append(BingeSession(
                    showTitle: currentTitle ?? "Unknown",
                    showRatingKey: key,
                    episodeCount: count,
                    startViewedAt: start,
                    endViewedAt: lastViewedAt
                ))
            }
        }

        for row in rows {
            let key: String? = row["k"]
            let viewedAt: Int = row["viewedAt"]
            let sameShow = currentKey.map { $0 == key } ?? false
            let withinGap = viewedAt - lastViewedAt <= bingeGapSeconds
            if sameShow && withinGap && count > 0 {
                count += 1
                lastViewedAt = viewedAt
            } else {
                flush()
                currentKey = key
                currentTitle = row["title"]
                count = 1
                start = viewedAt
                lastViewedAt = viewedAt
            }
        }
        flush()

        return sessions.sorted { $0.episodeCount > $1.episodeCount }.prefix(12).map { $0 }
    }

    private static func onThisDay(_ db: Database, monthDay: Int, currentYear: Int, scope: Int?) throws -> [OnThisDayItem] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT ratingKey, type, title, grandparentTitle, grandparentRatingKey, thumb, grandparentThumb, year
            FROM play
            WHERE monthDay = ? AND year < ?\(clause(scope))
            ORDER BY viewedAt DESC
            LIMIT 40
            """, arguments: [monthDay, currentYear])
        var seen = Set<String>()
        var items = [OnThisDayItem]()
        for row in rows {
            let key: String = row["ratingKey"]
            guard seen.insert(key).inserted else { continue }
            let year: Int = row["year"]
            items.append(OnThisDayItem(
                ratingKey: key,
                type: row["type"],
                title: row["title"] ?? "Unknown",
                grandparentTitle: row["grandparentTitle"],
                grandparentRatingKey: row["grandparentRatingKey"],
                thumb: row["thumb"],
                grandparentThumb: row["grandparentThumb"],
                yearsAgo: max(1, currentYear - year)
            ))
            if items.count >= 20 { break }
        }
        return items
    }

    private static func enrichment(_ db: Database, lowerBound: Int, scope: Int?) throws -> EnrichmentProgress {
        var progress = EnrichmentProgress()
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM play WHERE viewedAt >= ?\(clause(scope))", arguments: [lowerBound]) ?? 0
        guard total > 0 else { return progress }
        let runtimeCovered = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM play p JOIN item_meta im ON im.ratingKey = p.ratingKey
            WHERE p.viewedAt >= ? AND im.durationMs IS NOT NULL\(clause(scope, column: "p.accountID"))
            """, arguments: [lowerBound]) ?? 0
        let genreCovered = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM play p
            WHERE p.viewedAt >= ?\(clause(scope, column: "p.accountID")) AND EXISTS (
                SELECT 1 FROM genre_link gl WHERE gl.ownerKey = COALESCE(p.grandparentRatingKey, p.ratingKey)
            )
            """, arguments: [lowerBound]) ?? 0
        progress.runtimeCoverage = Double(runtimeCovered) / Double(total)
        progress.genreCoverage = Double(genreCovered) / Double(total)
        return progress
    }

    private static func superlatives(
        _ db: Database, lowerBound: Int, time: StatsTime, scope: Int?,
        hourHistogram: [Int], longestStreak: Int, binges: [BingeSession]
    ) throws -> [Superlative] {
        let acct = clause(scope)
        var cards = [Superlative]()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium

        if let row = try Row.fetchOne(db, sql: "SELECT dayEpoch, COUNT(*) AS c FROM play WHERE viewedAt >= ?\(acct) GROUP BY dayEpoch ORDER BY c DESC LIMIT 1", arguments: [lowerBound]) {
            let dayEpoch: Int = row["dayEpoch"]
            let count: Int = row["c"]
            let date = time.date(forDayEpoch: dayEpoch)
            cards.append(Superlative(symbol: "calendar", headline: "\(count)", title: "Busiest Day", caption: "\(count) plays on \(dateFormatter.string(from: date))"))
        }

        if longestStreak > 0 {
            cards.append(Superlative(symbol: "flame.fill", headline: "\(longestStreak)", title: "Longest Streak", caption: longestStreak == 1 ? "day in a row" : "days in a row"))
        }

        if let biggest = binges.first {
            cards.append(Superlative(symbol: "tv.fill", headline: "\(biggest.episodeCount)", title: "Biggest Binge", caption: "\(biggest.episodeCount) episodes of \(biggest.showTitle)"))
        }

        let total = hourHistogram.reduce(0, +)
        if total > 0 {
            let nightPlays = hourHistogram[0...4].reduce(0, +)
            let pct = Int((Double(nightPlays) / Double(total) * 100).rounded())
            cards.append(Superlative(symbol: "moon.stars.fill", headline: "\(pct)%", title: "Night Owl", caption: "of plays after midnight"))

            if let peakHour = hourHistogram.indices.max(by: { hourHistogram[$0] < hourHistogram[$1] }) {
                cards.append(Superlative(symbol: "clock.fill", headline: formatHour(peakHour), title: "Golden Hour", caption: "your most-pressed play time"))
            }
        }

        if let row = try Row.fetchOne(db, sql: "SELECT viewedAt, title, grandparentTitle FROM play WHERE 1=1\(acct) ORDER BY viewedAt ASC LIMIT 1") {
            let viewedAt: Int = row["viewedAt"]
            let date = Date(timeIntervalSince1970: TimeInterval(viewedAt))
            let title: String = row["grandparentTitle"] ?? row["title"] ?? ""
            cards.append(Superlative(symbol: "sparkles", headline: shortRelative(date), title: "Member Since", caption: title.isEmpty ? dateFormatter.string(from: date) : "started with \(title)"))
        }

        return cards
    }

    private static func formatHour(_ hour: Int) -> String {
        let h = hour % 24
        if h == 0 { return "12 AM" }
        if h == 12 { return "12 PM" }
        if h < 12 { return "\(h) AM" }
        return "\(h - 12) PM"
    }

    private static func shortRelative(_ date: Date) -> String {
        let years = Calendar.current.dateComponents([.year], from: date, to: Date()).year ?? 0
        if years >= 1 { return "\(years)y" }
        let months = Calendar.current.dateComponents([.month], from: date, to: Date()).month ?? 0
        if months >= 1 { return "\(months)mo" }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        return "\(max(0, days))d"
    }
}
