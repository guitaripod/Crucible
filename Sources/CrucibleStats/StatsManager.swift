import CrucibleCore
import Foundation

/// App-level owner of the statistics database and background sync/enrichment. Mirrors the
/// DownloadManager singleton pattern used elsewhere. Sync (fast, incremental) and enrichment
/// (slow, per-item network) run as separate tasks so pull-to-refresh only waits on the sync.
@MainActor
package final class StatsManager {
    package static let shared = StatsManager()

    package private(set) var store: StatsStore?
    private var api: APIClient?
    private var syncTask: Task<Void, Never>?
    private var enrichTask: Task<Void, Never>?
    private var generation = 0

    var isAvailable: Bool { store != nil }

    /// The loader every Statistics screen builds its page with; nil while the store is unavailable.
    package var pageLoader: StatsPageLoader? { store.map { StatsPageLoader(store: $0) } }

    private init() {}

    package func configure(api: APIClient) {
        self.api = api
        if store == nil {
            do {
                store = StatsStore(database: try StatsDatabase.openOrRebuild())
            } catch {
                AppLogger.error("Stats DB init failed: \(error.localizedDescription)", .stats)
            }
        }
    }

    /// Fire-and-forget incremental sync, followed by a bounded enrichment pass. Deliberately delayed
    /// and low-priority so it never competes with the foreground UI's network requests on launch.
    package func kickBackgroundSync() {
        startSync(initialDelay: .seconds(4))
    }

    /// Awaited incremental sync for pull-to-refresh; coalesces with any in-flight sync and does
    /// NOT block on the (much slower) enrichment pass.
    package func refreshNow() async {
        await startSync(initialDelay: .zero)?.value
    }

    @discardableResult
    private func startSync(initialDelay: Duration) -> Task<Void, Never>? {
        if let syncTask { return syncTask }
        guard let api, let store else { return nil }
        generation &+= 1
        let gen = generation
        let task = Task(priority: .utility) { [weak self] in
            if initialDelay > .zero { try? await Task.sleep(for: initialDelay) }
            await StatsSyncService(api: api, store: store).sync()
            guard let self, generation == gen else { return }
            syncTask = nil
            startEnrichment(generation: gen)
        }
        syncTask = task
        return task
    }

    private func startEnrichment(generation gen: Int) {
        guard enrichTask == nil, generation == gen, let api, let store else { return }
        enrichTask = Task(priority: .background) { [weak self] in
            await StatsSyncService(api: api, store: store).enrichLoop(perLaunchCap: 400)
            guard let self, generation == gen else { return }
            enrichTask = nil
        }
    }

    package func handleSignOut() {
        generation &+= 1
        syncTask?.cancel()
        enrichTask?.cancel()
        syncTask = nil
        enrichTask = nil
        store = nil
        api = nil
        StatsDatabase.destroy()
    }
}
