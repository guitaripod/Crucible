import Foundation

/// Keeps the Top Shelf snapshot current. The tvOS scene calls `refresh` on launch, when the app
/// returns to the foreground and after playback; `notify` is where it tells the system the Top
/// Shelf changed (`TVTopShelfContentProvider.topShelfContentDidChange()`).
///
/// ```swift
/// await TopShelfUpdater.refresh(api: api, machineIdentifier: connection.machineIdentifier) {
///     TVTopShelfContentProvider.topShelfContentDidChange()
/// }
/// ```
package enum TopShelfUpdater {
    @discardableResult
    package static func refresh(
        api: APIClient,
        machineIdentifier: String,
        store: TopShelfStore = .shared,
        excludedLibraries: Set<Int>? = nil,
        now: Date = Date(),
        notify: @Sendable () -> Void
    ) async -> Bool {
        let container: PlexMediaContainer
        do {
            container = try await api.requestContainer(.hubs())
        } catch {
            AppLogger.error("Top Shelf refresh skipped: \(error.localizedDescription)", .networking)
            return false
        }
        let source = TopShelfBuilder.Source(serverURL: await api.baseURL, token: api.token, machineIdentifier: machineIdentifier)
        let snapshot = TopShelfBuilder.snapshot(
            buckets: HomeBuckets(hubs: container.Hub),
            source: source,
            excludedLibraries: excludedLibraries ?? LibraryVisibility.excluded,
            now: now
        )
        return write(snapshot, to: store, notify: notify)
    }

    /// Writes the snapshot unless it matches what is already there, then signals the change. An
    /// empty snapshot removes the file so the Top Shelf shows its static image.
    static func write(_ snapshot: TopShelfSnapshot, to store: TopShelfStore, notify: @Sendable () -> Void) -> Bool {
        let existing = store.load()
        if snapshot.isEmpty {
            guard existing != nil else { return false }
            store.clear()
            notify()
            return true
        }
        if let existing, existing.hasSameContent(as: snapshot) { return false }
        guard store.save(snapshot) else { return false }
        AppLogger.info("Top Shelf updated: \(snapshot.sections.map { "\($0.title)=\($0.items.count)" }.joined(separator: " "))", .lifecycle)
        notify()
        return true
    }

    /// Signing out must not leave watch history and server URLs behind for the Top Shelf.
    package static func clear(store: TopShelfStore = .shared, notify: @Sendable () -> Void) {
        guard store.load() != nil else { return }
        store.clear()
        notify()
    }
}
