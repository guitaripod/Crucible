import CrucibleCore
import Foundation
import GRDB
import MidgarCore

extension StatsStore {
    /// The viewer's year and whole history as the Pro sheet may quote them: the counts Statistics shows for the Plex source, for
    /// the same account and libraries. The year is only read once the mirror reaches back to its first day, and the all-time
    /// figures only once the whole history is mirrored, so a number here never grows just because the backfill went on. Nil while
    /// neither is known or nothing was ever watched.
    package func viewerHistory(now: Date = Date(), time: StatsTime = StatsTime()) async throws -> ProViewerFacts.History? {
        let year = time.calendar.component(.year, from: now)
        guard let yearStart = StatsRange.year.lowerViewedAt(now: now, calendar: time.calendar) else { return nil }
        let today = time.todayDayEpoch(now: now)
        return try await dbQueue.read { db in
            guard let state = try SyncState.fetchOne(db, key: SyncState.singletonID) else { return nil }
            guard state.historyComplete || (state.lowWaterViewedAt ?? .max) <= yearStart else { return nil }
            let scope = try Self.scope(db)
            let overview = try Self.overview(db, lowerBound: yearStart, today: today, scope: scope)
            var history = ProViewerFacts.History(
                year: year,
                playsThisYear: overview.totalPlays,
                moviesThisYear: overview.moviesWatched,
                episodesThisYear: overview.episodes,
                hoursThisYear: overview.estHours.map { Int($0.rounded()) }
            )
            if state.historyComplete {
                let account = scope.clause()
                let plays = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(scope.table) WHERE 1=1\(account)") ?? 0
                let oldest = try Int.fetchOne(db, sql: "SELECT MIN(viewedAt) FROM \(scope.table) WHERE 1=1\(account)")
                history.playsAllTime = plays
                history.firstYear = oldest.map { time.calendar.component(.year, from: Date(timeIntervalSince1970: TimeInterval($0))) }
            }
            guard history.playsThisYear > 0 || (history.playsAllTime ?? 0) > 0 else { return nil }
            return history
        }
    }

    /// `viewerHistory` with a failure logged and reported as nothing known, which leaves the Pro sheet on its general lines.
    package func viewerHistoryOrNil(now: Date = Date()) async -> ProViewerFacts.History? {
        do {
            return try await viewerHistory(now: now)
        } catch is CancellationError {
            return nil
        } catch {
            MidgarLog.error("Viewer history for the Pro sheet failed: \(error.localizedDescription)", category: .stats)
            return nil
        }
    }
}
