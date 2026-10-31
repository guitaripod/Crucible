import Foundation
import MidgarCore

/// Loads and arranges the content of Home: `/hubs` bucketed and filtered into a `HomeArrangement`,
/// with the cold-launch snapshot as the instant first paint and as the fallback when a refresh
/// fails. The screen owns presentation (skeletons, error and empty states) and asks the feed for
/// content; a failed `refresh()` leaves whatever content the feed already holds.
@MainActor
package final class HomeFeed {
    package struct Environment {
        package var fetchHubs: @Sendable () async throws -> PlexMediaContainer
        package var fetchRecentlyAdded: @Sendable () async throws -> PlexMediaContainer
        package var loadSnapshot: () -> HomeSnapshot?
        package var saveSnapshot: (HomeSnapshot) -> Void
        package var machineIdentifier: () -> String?
        package var excludedLibraries: () -> Set<Int>
        package var now: () -> Date

        package init(
            fetchHubs: @escaping @Sendable () async throws -> PlexMediaContainer,
            fetchRecentlyAdded: @escaping @Sendable () async throws -> PlexMediaContainer,
            loadSnapshot: @escaping () -> HomeSnapshot?,
            saveSnapshot: @escaping (HomeSnapshot) -> Void,
            machineIdentifier: @escaping () -> String?,
            excludedLibraries: @escaping () -> Set<Int>,
            now: @escaping () -> Date
        ) {
            self.fetchHubs = fetchHubs
            self.fetchRecentlyAdded = fetchRecentlyAdded
            self.loadSnapshot = loadSnapshot
            self.saveSnapshot = saveSnapshot
            self.machineIdentifier = machineIdentifier
            self.excludedLibraries = excludedLibraries
            self.now = now
        }

        package static func live(api: APIClient) -> Environment {
            Environment(
                fetchHubs: { try await api.requestContainer(.hubs()) },
                fetchRecentlyAdded: { try await api.requestContainer(.recentlyAdded(start: 0, size: SurpriseMe.recentlyAddedPoolSize)) },
                loadSnapshot: { HomeSnapshotStore.loadSync() },
                saveSnapshot: { HomeSnapshotStore.save($0) },
                machineIdentifier: { ServerBootstrap.connection()?.machineIdentifier },
                excludedLibraries: { LibraryVisibility.excluded },
                now: { Date() }
            )
        }
    }

    package private(set) var arrangement = HomeArrangement()
    package private(set) var cachedArt: [String: String] = [:]
    private var fetched = HomeBuckets()
    private var mediaByID: [String: PlexMetadata] = [:]
    private let environment: Environment

    package init(environment: Environment) {
        self.environment = environment
    }

    package convenience init(api: APIClient) {
        self.init(environment: .live(api: api))
    }

    package var isEmpty: Bool { arrangement.isEmpty }

    package func item(id: String) -> PlexMetadata? {
        mediaByID[id]
    }

    package func heroModel(for item: PlexMetadata, bucket: HomeBucket = .hero, continuing: Bool = false) -> HomeHeroModel {
        HomeHeroModel(item: item, eyebrow: arrangement.title(for: bucket), cachedArt: cachedArt, continuing: continuing)
    }

    /// Fills the feed from the last saved snapshot when it belongs to the connected server and has
    /// cards. Returns whether anything was loaded.
    @discardableResult
    package func hydrateFromSnapshot() -> Bool {
        guard let machineID = environment.machineIdentifier(),
              let snapshot = environment.loadSnapshot(),
              snapshot.machineIdentifier == machineID,
              !snapshot.cards.isEmpty else { return false }
        cachedArt = HomeBuckets.cachedArt(in: snapshot)
        setContent(HomeBuckets(snapshot: snapshot))
        return true
    }

    /// Fetches `/hubs` and applies it; throws, leaving the current content untouched, when the
    /// request fails or the calling task was cancelled meanwhile.
    package func refresh() async throws {
        let container = try await environment.fetchHubs()
        try Task.checkCancellation()
        apply(container: container)
    }

    /// Applies an already fetched `/hubs` response and saves it as the cold-launch snapshot.
    package func apply(container: PlexMediaContainer) {
        let visible = setContent(HomeBuckets(hubs: container.Hub))
        MidgarLog.info(
            "Home loaded: cw=\(visible.continueWatching.count) od=\(visible.onDeck.count) ra=\(visible.recent.count)",
            category: .networking
        )
        environment.saveSnapshot(HomeSnapshot(
            schema: HomeSnapshotStore.schemaVersion,
            machineIdentifier: environment.machineIdentifier() ?? "",
            savedAt: Int(environment.now().timeIntervalSince1970),
            cards: visible.snapshotCards()
        ))
    }

    /// Re-derives the arrangement from the last fetched content after the library choice changed.
    package func reapplyLibraryVisibility() {
        setContent(fetched)
    }

    /// Picks a title for Surprise Me from a fresh recently-added fetch plus the recent items on
    /// screen. A failed fetch falls back to the on-screen items alone; when they hold nothing either,
    /// the failure is thrown as `SurpriseMe.LookupFailure` instead of reporting an empty library.
    /// Throws `CancellationError` if cancelled.
    package func surprise(_ kind: SurpriseMe.Kind) async throws -> SurpriseMe.Target? {
        var pool = arrangement.recent
        var lookupError: Error?
        do {
            let container = try await environment.fetchRecentlyAdded()
            pool = HomeBuckets.visible(container.Metadata ?? [], excluding: environment.excludedLibraries()) + pool
        } catch {
            lookupError = error
            MidgarLog.error("Surprise Me fetch failed, using cached Home items: \(error.localizedDescription)", category: .networking)
        }
        try Task.checkCancellation()
        let pick = SurpriseMe.pick(from: pool, kind: kind)
        if pick == nil, let lookupError {
            throw SurpriseMe.LookupFailure(message: ConnectionError.message(for: lookupError))
        }
        return pick
    }

    @discardableResult
    private func setContent(_ buckets: HomeBuckets) -> HomeBuckets {
        fetched = buckets
        let visible = buckets.visible(excluding: environment.excludedLibraries())
        mediaByID = Dictionary(
            (visible.continueWatching + visible.onDeck + visible.recent).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        arrangement = HomeArrangement(buckets: visible)
        return visible
    }
}
