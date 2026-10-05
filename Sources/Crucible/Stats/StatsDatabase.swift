import Foundation
import GRDB
import os

/// Owns the on-disk GRDB queue for the local watch-history mirror. Lives in Application Support
/// (survives Caches purges) and is excluded from backup — it is a rebuildable server mirror.
final class StatsDatabase: Sendable {
    let dbQueue: DatabaseQueue

    init() throws {
        let url = Self.databaseURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var config = Configuration()
        config.busyMode = .timeout(5)
        dbQueue = try DatabaseQueue(path: url.path, configuration: config)

        Self.excludeFromBackup(directory)
        try Self.migrator.migrate(dbQueue)
    }

    static func databaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Stats", isDirectory: true)
            .appendingPathComponent("stats.sqlite")
    }

    static func destroy() {
        let directory = databaseURL().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
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
