import CrucibleCore
import Foundation
import GRDB
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
            AppLogger.error("Stats DB corrupt (\(error.resultCode)), rebuilding: \(error.localizedDescription)", .stats)
            destroy(at: url)
            return try StatsDatabase(url: url)
        } catch {
            AppLogger.error("Stats DB could not be opened, keeping the file: \(error.localizedDescription)", .stats)
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

        return migrator
    }
}

private extension DatabaseError {
    var isCorruption: Bool {
        resultCode == .SQLITE_CORRUPT || resultCode == .SQLITE_NOTADB
    }
}
