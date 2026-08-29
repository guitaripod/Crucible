import Foundation
import GRDB

struct Play: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "play"

    var id: Int64?
    var ratingKey: String
    var type: String?
    var title: String?
    var grandparentTitle: String?
    var grandparentRatingKey: String?
    var grandparentThumb: String?
    var thumb: String?
    var parentIndex: Int?
    var idx: Int?
    var viewedAt: Int
    var dayEpoch: Int
    var hourLocal: Int
    var weekday: Int
    var monthEpoch: Int
    var monthDay: Int
    var year: Int
    var librarySectionID: Int?
    var librarySectionTitle: String?
    var accountID: Int?
    var deviceID: Int?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct ItemMeta: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "item_meta"
    var ratingKey: String
    var durationMs: Int?
    var year: Int?
    var enrichedAt: Int
}

struct ShowMeta: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "show_meta"
    var ratingKey: String
    var leafCount: Int?
    var title: String?
    var thumb: String?
    var enrichedAt: Int
}

struct GenreLink: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "genre_link"
    var ownerKey: String
    var genre: String
}

struct SyncState: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_state"
    var id: Int
    var highWaterViewedAt: Int?
    var lowWaterViewedAt: Int?
    var lastSyncAt: Int?
    var totalRows: Int
    var historyComplete: Bool
    var enrichCursor: String?
    var enrichedCount: Int
    var tzIdentifier: String?
    var backfillOffset: Int

    static let singletonID = 1

    static func initial(tzIdentifier: String) -> SyncState {
        SyncState(
            id: singletonID,
            highWaterViewedAt: nil,
            lowWaterViewedAt: nil,
            lastSyncAt: nil,
            totalRows: 0,
            historyComplete: false,
            enrichCursor: nil,
            enrichedCount: 0,
            tzIdentifier: tzIdentifier,
            backfillOffset: 0
        )
    }
}

struct PlayTimeComponents {
    let dayEpoch: Int
    let hourLocal: Int
    let weekday: Int
    let monthEpoch: Int
    let monthDay: Int
    let year: Int
}

/// Precomputes local-calendar buckets so every count chart is a pure index-friendly GROUP BY.
/// dayEpoch is a proleptic day index (consecutive local days differ by exactly 1) so streaks and
/// the heatmap stay DST-correct.
struct StatsTime {
    let calendar: Calendar
    private let dayZero: Date

    init(calendar: Calendar = .current) {
        self.calendar = calendar
        self.dayZero = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
    }

    func components(forViewedAt viewedAt: Int) -> PlayTimeComponents {
        let date = Date(timeIntervalSince1970: TimeInterval(viewedAt))
        let startOfDay = calendar.startOfDay(for: date)
        let dayEpoch = calendar.dateComponents([.day], from: dayZero, to: startOfDay).day ?? 0
        let c = calendar.dateComponents([.year, .month, .day, .hour, .weekday], from: date)
        let year = c.year ?? 1970
        let month = c.month ?? 1
        let day = c.day ?? 1
        return PlayTimeComponents(
            dayEpoch: dayEpoch,
            hourLocal: c.hour ?? 0,
            weekday: c.weekday ?? 1,
            monthEpoch: year * 12 + (month - 1),
            monthDay: month * 100 + day,
            year: year
        )
    }

    func date(forDayEpoch dayEpoch: Int) -> Date {
        calendar.date(byAdding: .day, value: dayEpoch, to: dayZero) ?? dayZero
    }

    func todayDayEpoch(now: Date = Date()) -> Int {
        let startOfDay = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: dayZero, to: startOfDay).day ?? 0
    }

    static func monthEpochToYearMonth(_ monthEpoch: Int) -> (year: Int, month: Int) {
        (monthEpoch / 12, monthEpoch % 12 + 1)
    }

    /// Builds a GitHub-style 53-week grid (7 rows, Sunday-aligned columns) from daily counts,
    /// quantile-bucketing intensity so light watchers still get contrast.
    func heatmapModel(days: [DayCount], today: Int, columns: Int = 53) -> HeatmapModel {
        let todayWeekday = weekday(forDayEpoch: today)
        let currentWeekSunday = today - (todayWeekday - 1)
        let firstSunday = currentWeekSunday - (columns - 1) * 7

        let counts = days.map(\.count).filter { $0 > 0 }.sorted()
        let thresholds = quantiles(counts)

        var cells = [HeatmapCell]()
        cells.reserveCapacity(days.count)
        for day in days where day.dayEpoch >= firstSunday && day.dayEpoch <= today && day.count > 0 {
            let offset = day.dayEpoch - firstSunday
            let level = 1 + thresholds.filter { day.count > $0 }.count
            cells.append(HeatmapCell(column: offset / 7, row: offset % 7, level: min(5, level), dayEpoch: day.dayEpoch, count: day.count))
        }

        var monthLabels = [Int: String]()
        var previousMonth = -1
        for column in 0..<columns {
            let sunday = firstSunday + column * 7
            if sunday > today { break }
            let comps = calendar.dateComponents([.month], from: date(forDayEpoch: sunday))
            let month = comps.month ?? 0
            if month != previousMonth {
                monthLabels[column] = StatsStyle.monthSymbols[max(0, min(11, month - 1))]
                previousMonth = month
            }
        }

        return HeatmapModel(cells: cells, columns: columns, firstDayEpoch: firstSunday, lastDayEpoch: today, monthLabels: monthLabels)
    }

    private func weekday(forDayEpoch dayEpoch: Int) -> Int {
        let comps = calendar.dateComponents([.weekday], from: date(forDayEpoch: dayEpoch))
        return comps.weekday ?? 1
    }

    private func quantiles(_ sorted: [Int]) -> [Int] {
        guard !sorted.isEmpty else { return [0, 0, 0, 0] }
        func at(_ fraction: Double) -> Int {
            let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
            return sorted[index]
        }
        return [at(0.2), at(0.4), at(0.6), at(0.8)]
    }
}

enum StatsRange: Int, CaseIterable {
    case year
    case days90
    case allTime

    var title: String {
        switch self {
        case .year: return "This Year"
        case .days90: return "90 Days"
        case .allTime: return "All Time"
        }
    }

    /// Inclusive lower bound on viewedAt (unix seconds); nil == unbounded.
    func lowerViewedAt(now: Date = Date(), calendar: Calendar = .current) -> Int? {
        switch self {
        case .allTime:
            return nil
        case .days90:
            guard let d = calendar.date(byAdding: .day, value: -90, to: now) else { return nil }
            return Int(d.timeIntervalSince1970)
        case .year:
            let comps = calendar.dateComponents([.year], from: now)
            guard let start = calendar.date(from: comps) else { return nil }
            return Int(start.timeIntervalSince1970)
        }
    }
}
