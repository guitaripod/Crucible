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
        let serverURL = await api.baseURL
        guard !Task.isCancelled else { return false }
        let source = TopShelfBuilder.Source(serverURL: serverURL, token: api.token, machineIdentifier: machineIdentifier)
        let snapshot = TopShelfBuilder.snapshot(
            buckets: HomeBuckets(hubs: container.Hub),
            source: source,
            excludedLibraries: excludedLibraries ?? LibraryVisibility.excluded,
            now: now
        )
        return await MainActor.run {
            guard !Task.isCancelled else { return false }
            return write(snapshot, to: store, notify: notify)
        }
    }

    /// Writes the snapshot unless it matches what is already there, then signals the change. An
    /// empty snapshot removes the file so the Top Shelf shows its static image. `refresh` calls it
    /// on the main actor right after checking for cancellation, so a refresh cancelled by a
    /// sign-out or server change can never write after the clear that cancelled it.
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

    /// Signing out or changing server must not leave watch history and server URLs behind for the
    /// Top Shelf. Only tvOS has a Top Shelf; elsewhere this does nothing.
    @MainActor
    package static func clear(store: TopShelfStore? = nil, notify: () -> Void) {
        let store = store ?? (AppPlatform.isTV ? .shared : TopShelfStore(directory: nil))
        guard store.load() != nil else { return }
        store.clear()
        notify()
    }
}
