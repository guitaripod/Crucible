import Foundation

/// Builds the ``StatsPage`` for a range from the local mirror. Obtain one from
/// ``StatsManager/pageLoader``; it is cheap to create and safe to call from any task.
package struct StatsPageLoader: Sendable {
    let store: StatsStore

    package init(store: StatsStore) {
        self.store = store
    }

    package func load(range: StatsRange, now: Date = Date()) async throws -> StatsPage {
        let snapshot = try await store.snapshot(range: range)
        return StatsPage(snapshot: snapshot, range: range, now: now)
    }

    /// Titles watched on one local day, for the heatmap drill-down, one tile per title.
    package func playedOnDay(_ dayEpoch: Int) async throws -> [StatsPoster] {
        let rows = try await store.plays(onDayEpoch: dayEpoch)
        var seen = Set<String>()
        return rows.filter { seen.insert($0.ratingKey).inserted }.map { StatsPoster(playedOnDay: $0) }
    }
}
