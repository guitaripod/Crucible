import CrucibleCore
import Foundation

extension DownloadManager {
    // MARK: - Controls

    func pause(_ ratingKey: String) {
        guard let idx = index(ratingKey), items[idx].state.isActive else { return }
        cancelItemTasks(ratingKey)
        items[idx].state = .paused
        persist()
        emit(.changed)
        pumpQueue()
    }

    func resume(_ ratingKey: String) {
        guard let idx = index(ratingKey), items[idx].state == .paused || items[idx].state == .failed else { return }
        items[idx].state = .queued
        items[idx].errorMessage = nil
        resolveRetries[ratingKey] = nil
        persist()
        emit(.changed)
        pumpQueue()
    }

    func retry(_ ratingKey: String) { resume(ratingKey) }

    func delete(_ ratingKey: String) {
        guard let idx = index(ratingKey) else { return }
        cancelItemTasks(ratingKey)
        items.remove(at: idx)
        lastProgressEmit[ratingKey] = nil
        resolveRetries[ratingKey] = nil
        removeAssetDir(ratingKey)
        Task { [store] in await store.deletePoster(ratingKey: ratingKey) }
        persist()
        emit(.changed)
        pumpQueue()
    }

    func deleteItems(_ ratingKeys: [String]) {
        let set = Set(ratingKeys)
        guard !set.isEmpty, items.contains(where: { set.contains($0.ratingKey) }) else { return }
        for key in set {
            jobs[key] = nil
            lastProgressEmit[key] = nil
            resolveRetries[key] = nil
            stopTranscodeSession(key)
            removeAssetDir(key)
        }
        cancelInflight(keys: set)
        items.removeAll { set.contains($0.ratingKey) }
        Task { [store] in
            for key in set { await store.deletePoster(ratingKey: key) }
        }
        persist()
        emit(.changed)
        pumpQueue()
    }

    func deleteAll() {
        let snapshot = items
        jobs.removeAll()
        resolving.removeAll()
        resolveRetries.removeAll()
        stallWatchdogs.values.forEach { $0.cancel() }
        stallWatchdogs.removeAll()
        fallbackFetchers.values.forEach { $0.cancel() }
        fallbackFetchers.removeAll()
        lastProgressEmit.removeAll()
        items.removeAll()
        for key in Array(transcodeSessions.keys) { stopTranscodeSession(key) }
        let session = self.session
        enqueueQueue.async { session.getAllTasks { tasks in tasks.forEach { $0.cancel() } } }
        for item in snapshot { removeAssetDir(item.ratingKey) }
        Task { [store] in
            for item in snapshot { await store.deletePoster(ratingKey: item.ratingKey) }
            await store.save([])
        }
        emit(.changed)
    }

    private func removeAssetDir(_ ratingKey: String) {
        let dir = DownloadPaths.assetDir(ratingKey: ratingKey)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: dir) }
    }

    func recordOfflineProgress(ratingKey: String, positionSecs: Double, finished: Bool = false, deleteIfWatched: Bool = false) {
        guard let idx = index(ratingKey), items[idx].state == .completed else { return }
        let wasWatched = items[idx].isWatched
        items[idx].viewOffsetMs = finished ? items[idx].durationMs : Int(max(0, positionSecs) * 1000)
        if !wasWatched, items[idx].isWatched { scrobbleBestEffort(ratingKey) }
        if deleteIfWatched, Preferences.deleteWatchedDownloads, items[idx].isWatched {
            delete(ratingKey)
        } else {
            persist()
            emit(.changed)
        }
    }

    func cellularPreferenceChanged() {
        promoteWaitingAndPump()
    }
}
