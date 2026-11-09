import CrucibleCore
import Foundation
import GRDB
import MidgarCore
import os

/// Owns the on-disk GRDB queue for the local watch-history mirror. It lives in
/// ``AppPlatform/persistentDirectory`` (Application Support on iOS, Caches on tvOS, where nothing else
/// is writable) and is excluded from backup: it is a rebuildable server mirror, so losing it to a
/// purge only costs a fresh backfill.
final class StatsDatabase: Sendable {
    let dbQueue: DatabaseQueue

    init(url: URL = StatsDatabase.databaseURL()) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var config = Configuration()
        config.busyMode = .timeout(5)
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)

        Self.excludeFromBackup(directory)
        try Self.migrator.migrate(dbQueue)
    }

    static func databaseURL() -> URL {
        AppPlatform.persistentDirectory
            .appendingPathComponent("Stats", isDirectory: true)
            .appendingPathComponent("stats.sqlite")
    }

    /// Opens the mirror, starting over only when the file is genuinely corrupt (a purge can leave a
    /// truncated or garbage file behind). Any other failure, such as a busy or unreadable file or a
    /// full disk, is rethrown and leaves a healthy mirror untouched. A fresh mirror begins with an
    /// unfinished backfill from the first page.
    static func openOrRebuild(at url: URL = databaseURL()) throws -> StatsDatabase {
        do {
            return try StatsDatabase(url: url)
        } catch let error as DatabaseError where error.isCorruption {
            MidgarLog.error("Stats DB corrupt (\(error.resultCode)), rebuilding: \(error.localizedDescription)", category: .stats)
            destroy(at: url)
            return try StatsDatabase(url: url)
        } catch {
            MidgarLog.error("Stats DB could not be opened, keeping the file: \(error.localizedDescription)", category: .stats)
            throw error
        }
    }

    static func destroy(at url: URL = databaseURL()) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "play") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ratingKey", .text).notNull()
                t.column("type", .text)
                t.column("title", .text)
                t.column("grandparentTitle", .text)
                t.column("grandparentRatingKey", .text)
                t.column("grandparentThumb", .text)
                t.column("thumb", .text)
                t.column("parentIndex", .integer)
                t.column("idx", .integer)
                t.column("viewedAt", .integer).notNull()
                t.column("dayEpoch", .integer).notNull()
                t.column("hourLocal", .integer).notNull()
                t.column("weekday", .integer).notNull()
                t.column("monthEpoch", .integer).notNull()
                t.column("monthDay", .integer).notNull()
                t.column("year", .integer).notNull()
                t.column("librarySectionID", .integer)
                t.column("librarySectionTitle", .text)
                t.column("accountID", .integer)
                t.column("deviceID", .integer)
                t.uniqueKey(["ratingKey", "viewedAt"], onConflict: .ignore)
            }
            try db.create(index: "idx_play_viewedAt", on: "play", columns: ["viewedAt"])
            try db.create(index: "idx_play_day", on: "play", columns: ["dayEpoch"])
            try db.create(index: "idx_play_show", on: "play", columns: ["grandparentRatingKey"])
            try db.create(index: "idx_play_lib", on: "play", columns: ["librarySectionID"])

            try db.create(table: "item_meta") { t in
                t.primaryKey("ratingKey", .text)
                t.column("durationMs", .integer)
                t.column("year", .integer)
                t.column("enrichedAt", .integer).notNull()
            }

            try db.create(table: "show_meta") { t in
                t.primaryKey("ratingKey", .text)
                t.column("leafCount", .integer)
                t.column("title", .text)
                t.column("thumb", .text)
                t.column("enrichedAt", .integer).notNull()
            }

            try db.create(table: "genre_link") { t in
                t.column("ownerKey", .text).notNull()
                t.column("genre", .text).notNull()
                t.primaryKey(["ownerKey", "genre"])
            }

            try db.create(table: "sync_state") { t in
                t.primaryKey("id", .integer)
                t.check(Column("id") == 1)
                t.column("highWaterViewedAt", .integer)
                t.column("lowWaterViewedAt", .integer)
                t.column("lastSyncAt", .integer)
                t.column("totalRows", .integer).notNull().defaults(to: 0)
                t.column("historyComplete", .boolean).notNull().defaults(to: false)
                t.column("enrichCursor", .text)
                t.column("enrichedCount", .integer).notNull().defaults(to: 0)
                t.column("tzIdentifier", .text)
                t.column("backfillOffset", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v2-trakt") { db in
            try db.create(table: "trakt_play") { t in
                t.primaryKey("id", .integer)
                t.column("traktKey", .text).notNull()
                t.column("traktShowKey", .text)
                t.column("ratingKey", .text).notNull()
                t.column("type", .text).notNull()
                t.column("title", .text)
                t.column("grandparentTitle", .text)
                t.column("grandparentRatingKey", .text)
                t.column("thumb", .text)
                t.column("grandparentThumb", .text)
                t.column("traktThumb", .text)
                t.column("traktShowThumb", .text)
                t.column("releaseYear", .integer)
                t.column("imdb", .text)
                t.column("tmdb", .integer)
                t.column("tvdb", .integer)
                t.column("showImdb", .text)
                t.column("showTmdb", .integer)
                t.column("showTvdb", .integer)
                t.column("parentIndex", .integer)
                t.column("idx", .integer)
                t.column("viewedAt", .integer).notNull()
                t.column("dayEpoch", .integer).notNull()
                t.column("hourLocal", .integer).notNull()
                t.column("weekday", .integer).notNull()
                t.column("monthEpoch", .integer).notNull()
                t.column("monthDay", .integer).notNull()
                t.column("year", .integer).notNull()
                t.column("librarySectionID", .integer)
                t.column("librarySectionTitle", .text)
                t.column("matchedPlayID", .integer)
            }
            try db.create(index: "idx_trakt_play_viewedAt", on: "trakt_play", columns: ["viewedAt"])

            try db.create(table: "trakt_sync") { t in
                t.primaryKey("id", .integer)
                t.check(Column("id") == 1)
                t.column("owner", .text)
                t.column("newestViewedAt", .integer)
                t.column("nextPage", .integer).notNull().defaults(to: 1)
                t.column("complete", .boolean).notNull().defaults(to: false)
                t.column("passStartAt", .integer)
                t.column("lastSyncAt", .integer)
            }

            try db.create(table: "item_ids") { t in
                t.primaryKey("ratingKey", .text)
                t.column("imdb", .text)
                t.column("tmdb", .integer)
                t.column("tvdb", .integer)
                t.column("checkedAt", .integer).notNull()
            }

            try db.execute(sql: """
                CREATE VIEW every_play AS
                SELECT id, ratingKey, type, title, grandparentTitle, grandparentRatingKey, grandparentThumb, thumb, parentIndex, idx,
                       viewedAt, dayEpoch, hourLocal, weekday, monthEpoch, monthDay, year, librarySectionID, librarySectionTitle,
                       accountID, deviceID, 'plex' AS source
                FROM play
                UNION ALL
                SELECT -id, ratingKey, type, title, grandparentTitle, grandparentRatingKey, grandparentThumb, thumb, parentIndex, idx,
                       viewedAt, dayEpoch, hourLocal, weekday, monthEpoch, monthDay, year, librarySectionID, librarySectionTitle,
                       NULL, NULL, 'trakt' AS source
                FROM trakt_play WHERE matchedPlayID IS NULL
                """)
        }

        return migrator
    }
}

private extension DatabaseError {
    var isCorruption: Bool {
        resultCode == .SQLITE_CORRUPT || resultCode == .SQLITE_NOTADB
    }
}
