import Foundation
import GRDB

/// Watch time for the current Monday-to-Sunday week, plus last week for the delta line.
struct HomeWeekSummary: Hashable, Sendable {
    var dailySeconds: [Int]
    var todayIndex: Int
    var thisWeekSeconds: Int
    var lastWeekSameSpanSeconds: Int
    var lastWeekSeconds: Int

    var isEmpty: Bool { thisWeekSeconds == 0 && lastWeekSeconds == 0 }

    /// Percentage change against the same days of last week; nil when there is nothing to compare.
    var deltaPercent: Int? {
        guard lastWeekSameSpanSeconds > 0 else { return nil }
        let change = Double(thisWeekSeconds - lastWeekSameSpanSeconds) / Double(lastWeekSameSpanSeconds)
        return Int((change * 100).rounded())
    }
}

extension StatsStore {
    /// Per-day watch seconds for this week and last. A play's time is its item's runtime from the
    /// enrichment cache; plays not yet enriched are counted at the average known runtime.
    func homeWeekSummary(now: Date = Date()) async throws -> HomeWeekSummary {
        let time = StatsTime()
        let today = time.todayDayEpoch(now: now)
        let weekday = time.calendar.component(.weekday, from: now)
        let todayIndex = (weekday + 5) % 7
        let weekStart = today - todayIndex
        let lastWeekStart = weekStart - 7

        let perDay: [Int: Int] = try await database.dbQueue.read { db in
            let acct = try Self.scope(db).clause(column: "p.accountID")
            let averageMs = try Double.fetchOne(db, sql: """
                SELECT AVG(im.durationMs) FROM play p
                JOIN item_meta im ON im.ratingKey = p.ratingKey
                WHERE im.durationMs IS NOT NULL AND im.durationMs > 0\(acct)
                """) ?? 0
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.dayEpoch AS d,
                       COALESCE(SUM(im.durationMs), 0) AS known,
                       SUM(CASE WHEN im.durationMs IS NULL THEN 1 ELSE 0 END) AS unknown
                FROM play p
                LEFT JOIN item_meta im ON im.ratingKey = p.ratingKey
                WHERE p.dayEpoch >= ? AND p.dayEpoch <= ?\(acct)
                GROUP BY p.dayEpoch
                """, arguments: [lastWeekStart, today])
            var result = [Int: Int]()
            for row in rows {
                let day: Int = row["d"]
                let known: Int = row["known"]
                let unknown: Int = row["unknown"]
                result[day] = Int((Double(known) + Double(unknown) * averageMs) / 1000)
            }
            return result
        }

        let daily = (0..<7).map { perDay[weekStart + $0] ?? 0 }
        let lastWeek = (0..<7).map { perDay[lastWeekStart + $0] ?? 0 }
        return HomeWeekSummary(
            dailySeconds: daily,
            todayIndex: todayIndex,
            thisWeekSeconds: daily.prefix(todayIndex + 1).reduce(0, +),
            lastWeekSameSpanSeconds: lastWeek.prefix(todayIndex + 1).reduce(0, +),
            lastWeekSeconds: lastWeek.reduce(0, +)
        )
    }
}
