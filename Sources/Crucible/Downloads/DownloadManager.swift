import BackgroundTasks
import Foundation
import Network
import os
import UIKit
import UserNotifications

/// State-of-the-art offline download engine. Plex only transcodes to HLS, so each download is fetched
/// segment-by-segment into a local playlist folder (see `HLSDownloader`) that AVPlayer plays with no
/// network. Sequential fetching matches Plex's on-demand transcoder; re-running resumes by skipping
/// existing segments. A concurrency-limited queue, Wi-Fi-only gating, pause/resume/retry, background
/// time assertions, and on-disk persistence round it out.
@MainActor
final class DownloadManager: NSObject {
    static let shared = DownloadManager()
    static let backgroundProcessingId = "com.guitaripod.crucible.downloads.process"
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "downloads")

    private struct Config { let baseURL: URL; let token: String }
    private var config: Config?

    private(set) var items: [DownloadItem] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var taskTokens: [String: String] = [:]
    private var observers: [UUID: (DownloadEvent) -> Void] = [:]
    private var lastProgressEmit: [String: Date] = [:]
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var bgProcessingTask: BGProcessingTask?

    let store = DownloadStore()
    var backgroundCompletionHandler: (() -> Void)?

    private let pathMonitor = NWPathMonitor()
    private var isOnWiFi = true
    private var isOnline = true
    private var didBootstrap = false

    #if os(iOS) && canImport(ActivityKit)
    private let liveActivity = DownloadActivityController()
    #endif

    private override init() {
        super.init()
        startPathMonitor()
    }

    // MARK: - Lifecycle

    func configure(baseURL: URL, token: String) {
        config = Config(baseURL: baseURL, token: token)
        pumpQueue()
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        #if os(iOS) && canImport(ActivityKit)
        liveActivity.endStale()
        #endif
        Task { [weak self] in
            guard let self else { return }
            let loaded = await self.store.load()
            self.items = loaded
            self.finishBootstrap()
        }
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func handleSignOut() {
        deleteAll()
        config = nil
    }

    // MARK: - Observers

    @discardableResult
    func addObserver(_ handler: @escaping (DownloadEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func emit(_ event: DownloadEvent) {
        for handler in observers.values { handler(event) }
        #if os(iOS) && canImport(ActivityKit)
        if case .progress = event {
            liveActivity.sync(items: items, force: false)
        } else {
            liveActivity.sync(items: items, force: true)
        }
        #endif
    }

    // MARK: - Queries

    func item(for ratingKey: String) -> DownloadItem? {
        items.first { $0.ratingKey == ratingKey }
    }

    func state(for ratingKey: String) -> DownloadState? {
        item(for: ratingKey)?.state
    }

    func isDownloaded(_ ratingKey: String) -> Bool {
        item(for: ratingKey)?.state == .completed
    }

    var hasActiveDownloads: Bool {
        items.contains { $0.state.isActive }
    }

    var activeDownloadCount: Int {
        items.filter { $0.state.isActive }.count
    }

    private func index(_ ratingKey: String) -> Int? {
        items.firstIndex { $0.ratingKey == ratingKey }
    }

    func offlineAsset(for ratingKey: String) -> OfflineAsset? {
        guard let item = item(for: ratingKey), item.state == .completed else { return nil }
        let url = DownloadPaths.playlistURL(ratingKey: ratingKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return OfflineAsset(
            fileURL: url,
            markers: item.markers.map(\.asPlexMarker),
            durationSecs: item.durationSecs,
            resumeSecs: item.resumeSecs
        )
    }

    func totalBytesOnDisk() async -> Int64 {
        items.filter { $0.state == .completed }.reduce(0) { $0 + $1.totalBytes }
    }

    func availableCapacity() async -> Int64 { await store.availableCapacityBytes() }

    // MARK: - Enqueue

    func enqueue(metadata: PlexMetadata, quality: DownloadQuality? = nil) {
        let ratingKey = metadata.id
        guard !ratingKey.isEmpty else { return }
        if let existing = item(for: ratingKey) {
            if existing.state == .failed || existing.state == .paused { resume(ratingKey) }
            return
        }
        items.insert(makeItem(metadata: metadata, quality: quality ?? Preferences.downloadQuality), at: 0)
        persist()
        emit(.changed)
        pumpQueue()
    }

    @discardableResult
    func enqueueAll(_ metadatas: [PlexMetadata], quality: DownloadQuality? = nil) -> Int {
        let q = quality ?? Preferences.downloadQuality
        var added = 0
        for metadata in metadatas {
            let key = metadata.id
            guard !key.isEmpty, item(for: key) == nil else { continue }
            items.insert(makeItem(metadata: metadata, quality: q), at: 0)
            added += 1
        }
        if added > 0 {
            persist()
            emit(.changed)
            pumpQueue()
        }
        return added
    }

    private func makeItem(metadata: PlexMetadata, quality: DownloadQuality) -> DownloadItem {
        let mediaType = metadata.mediaType
        let posterPath = mediaType == "episode" ? (metadata.grandparentThumb ?? metadata.thumb) : metadata.thumb
        let durationMs = metadata.duration ?? 0
        return DownloadItem(
            ratingKey: metadata.id,
            mediaType: mediaType,
            title: metadata.title,
            showTitle: metadata.grandparentTitle,
            grandparentRatingKey: metadata.grandparentRatingKey,
            parentRatingKey: metadata.parentRatingKey,
            seasonNumber: metadata.parentIndex,
            episodeNumber: metadata.index,
            year: metadata.year,
            durationMs: durationMs,
            summary: metadata.summary,
            plexThumbPath: posterPath,
            quality: quality,
            isTranscoded: true,
            fileExtension: "movpkg",
            hlsRelativePath: nil,
            state: .queued,
            progress: 0,
            totalBytes: 0,
            downloadedBytes: 0,
            estimatedBytes: quality.estimatedBytes(durationMs: durationMs),
            errorMessage: nil,
            createdAt: Date(),
            completedAt: nil,
            viewOffsetMs: metadata.viewOffset ?? 0,
            markers: []
        )
    }

    // MARK: - Controls

    func pause(_ ratingKey: String) {
        guard let idx = index(ratingKey), items[idx].state.isActive else { return }
        cancelTask(ratingKey)
        items[idx].state = .paused
        persist()
        emit(.changed)
        pumpQueue()
    }

    func resume(_ ratingKey: String) {
        guard let idx = index(ratingKey), items[idx].state == .paused || items[idx].state == .failed else { return }
        items[idx].state = .queued
        items[idx].errorMessage = nil
        persist()
        emit(.changed)
        pumpQueue()
    }

    func retry(_ ratingKey: String) { resume(ratingKey) }

    func delete(_ ratingKey: String) {
        guard let idx = index(ratingKey) else { return }
        cancelTask(ratingKey)
        items.remove(at: idx)
        lastProgressEmit[ratingKey] = nil
        removeAssetDir(ratingKey)
        Task { [store] in await store.deletePoster(ratingKey: ratingKey) }
        persist()
        emit(.changed)
        pumpQueue()
    }

    func deleteAll() {
        let snapshot = items
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
        taskTokens.removeAll()
        lastProgressEmit.removeAll()
        items.removeAll()
        for item in snapshot { removeAssetDir(item.ratingKey) }
        Task { [store] in
            for item in snapshot { await store.deletePoster(ratingKey: item.ratingKey) }
            await store.save([])
        }
        updateBackgroundAssertion()
        emit(.changed)
    }

    private func removeAssetDir(_ ratingKey: String) {
        let dir = DownloadPaths.assetDir(ratingKey: ratingKey)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: dir) }
    }

    func recordOfflineProgress(ratingKey: String, positionSecs: Double, deleteIfWatched: Bool = false) {
        guard let idx = index(ratingKey), items[idx].state == .completed else { return }
        items[idx].viewOffsetMs = Int(max(0, positionSecs) * 1000)
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

    // MARK: - Queue

    private func pumpQueue() {
        guard config != nil else { return }
        let net = canStartOnCurrentNetwork()
        if !net {
            var changed = false
            for i in items.indices where items[i].state == .queued {
                items[i].state = .waitingForWiFi
                changed = true
            }
            if changed { persist(); emit(.changed) }
            return
        }
        for i in items.indices where items[i].state == .waitingForWiFi {
            items[i].state = .queued
        }
        var slots = Preferences.maxConcurrentDownloads - tasks.count
        guard slots > 0 else { return }
        for item in items where item.state == .queued {
            guard slots > 0 else { break }
            guard tasks[item.ratingKey] == nil else { continue }
            startDownload(item.ratingKey)
            slots -= 1
        }
    }

    private func canStartOnCurrentNetwork() -> Bool {
        Preferences.downloadOverCellular ? isOnline : isOnWiFi
    }

    private func startDownload(_ ratingKey: String) {
        guard config != nil, let idx = index(ratingKey), items[idx].state == .queued else { return }
        let token = UUID().uuidString
        taskTokens[ratingKey] = token
        items[idx].state = .downloading
        items[idx].errorMessage = nil
        persist()
        emit(.changed)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runDownload(ratingKey: ratingKey, token: token)
        }
        tasks[ratingKey] = task
        updateBackgroundAssertion()
    }

    private func runDownload(ratingKey: String, token: String) async {
        guard let cfg = config else { finishTask(ratingKey, token: token); return }
        let api = APIClient(baseURL: cfg.baseURL, token: cfg.token)
        do {
            let plan = try await DownloadResolver.plan(api: api, ratingKey: ratingKey, quality: item(for: ratingKey)?.quality ?? Preferences.downloadQuality)
            guard taskTokens[ratingKey] == token, let idx = index(ratingKey) else { finishTask(ratingKey, token: token); return }

            items[idx].estimatedBytes = plan.estimatedBytes
            items[idx].durationMs = plan.durationMs > 0 ? plan.durationMs : items[idx].durationMs
            items[idx].markers = plan.markers
            if items[idx].summary == nil { items[idx].summary = plan.summary }
            if items[idx].viewOffsetMs == 0 { items[idx].viewOffsetMs = plan.initialViewOffsetMs }
            persist()

            if let posterPath = plan.posterPath ?? items[idx].plexThumbPath {
                fetchPoster(path: posterPath, ratingKey: ratingKey, baseURL: cfg.baseURL, token: cfg.token)
            }
            AppLogger.notice("Download started key=\(ratingKey) quality=\(items[idx].quality.shortLabel) path=\(plan.url.path)", .persistence)

            let result = try await HLSDownloader.download(masterURL: plan.url, ratingKey: ratingKey) { fraction in
                Task { @MainActor [weak self] in
                    self?.handleProgress(ratingKey: ratingKey, token: token, fraction: fraction)
                }
            }

            guard taskTokens[ratingKey] == token, let fidx = index(ratingKey) else { finishTask(ratingKey, token: token); return }
            items[fidx].state = .completed
            items[fidx].progress = 1
            items[fidx].totalBytes = result.totalBytes
            items[fidx].downloadedBytes = result.totalBytes
            items[fidx].completedAt = Date()
            items[fidx].errorMessage = nil
            finishTask(ratingKey, token: token)
            lastProgressEmit[ratingKey] = nil
            persist()
            emit(.finished(ratingKey: ratingKey))
            emit(.changed)
            notifyDownloadComplete(title: items[fidx].displayTitle)
            AppLogger.notice("Download finished key=\(ratingKey) bytes=\(result.totalBytes) segments=\(result.segmentCount)", .persistence)
        } catch is CancellationError {
            finishTask(ratingKey, token: token)
        } catch HLSDownloadError.cancelled {
            finishTask(ratingKey, token: token)
        } catch {
            guard taskTokens[ratingKey] == token, let idx = index(ratingKey) else { finishTask(ratingKey, token: token); return }
            items[idx].state = .failed
            items[idx].errorMessage = error.localizedDescription
            finishTask(ratingKey, token: token)
            persist()
            emit(.failed(ratingKey: ratingKey, message: error.localizedDescription))
            emit(.changed)
            AppLogger.error("Download failed key=\(ratingKey): \(error.localizedDescription)", .persistence)
        }
    }

    /// Clears task bookkeeping for the given token and pumps the queue. Safe to call when the token is
    /// stale (a newer task owns the key) — it then leaves the live task untouched.
    private func finishTask(_ ratingKey: String, token: String) {
        if taskTokens[ratingKey] == nil || taskTokens[ratingKey] == token {
            tasks[ratingKey] = nil
            taskTokens[ratingKey] = nil
        }
        updateBackgroundAssertion()
        pumpQueue()
        if bgProcessingTask != nil, !hasActiveDownloads {
            completeBackgroundProcessing(success: true)
        }
    }

    private func cancelTask(_ ratingKey: String) {
        tasks[ratingKey]?.cancel()
        tasks[ratingKey] = nil
        taskTokens[ratingKey] = nil
        updateBackgroundAssertion()
    }

    private func fetchPoster(path: String, ratingKey: String, baseURL: URL, token: String) {
        guard let url = DownloadResolver.posterURL(baseURL: baseURL, token: token, path: path, width: 400, height: 600) else { return }
        Task { [store] in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            for (key, value) in PlexHeaders.allHeaders(token: token) {
                request.setValue(value, forHTTPHeaderField: key)
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return }
            await store.savePoster(data, ratingKey: ratingKey)
        }
    }

    private func updateBackgroundAssertion() {
        if !tasks.isEmpty, bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "crucible.downloads") { [weak self] in
                self?.interruptForBackground()
            }
        } else if tasks.isEmpty {
            endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: - Background execution

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundProcessingId, using: nil) { task in
            guard let processing = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in DownloadManager.shared.handleBackgroundProcessing(processing) }
        }
    }

    func handleEnteredBackground() {
        scheduleBackgroundProcessing()
    }

    func handleEnteredForeground() {
        resumeStalledDownloads()
        #if os(iOS) && canImport(ActivityKit)
        liveActivity.sync(items: items, force: true)
        #endif
    }

    private func scheduleBackgroundProcessing() {
        guard hasActiveDownloads else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundProcessingId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.log.error("BG processing submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleBackgroundProcessing(_ task: BGProcessingTask) {
        scheduleBackgroundProcessing()
        bgProcessingTask = task
        task.expirationHandler = {
            Task { @MainActor in
                DownloadManager.shared.interruptForBackground()
                DownloadManager.shared.completeBackgroundProcessing(success: false)
            }
        }
        resumeStalledDownloads()
        if tasks.isEmpty {
            completeBackgroundProcessing(success: true)
        }
    }

    private func completeBackgroundProcessing(success: Bool) {
        bgProcessingTask?.setTaskCompleted(success: success)
        bgProcessingTask = nil
    }

    /// Cancels in-flight download tasks without failing them — items stay `.downloading` (no task) and
    /// are resumed on the next foreground or background-processing window.
    private func interruptForBackground() {
        #if os(iOS) && canImport(ActivityKit)
        liveActivity.markPaused(items: items)
        #endif
        for (_, task) in tasks { task.cancel() }
        tasks.removeAll()
        taskTokens.removeAll()
        endBackgroundAssertion()
    }

    private func resumeStalledDownloads() {
        var changed = false
        for i in items.indices where items[i].state == .downloading && tasks[items[i].ratingKey] == nil {
            items[i].state = .queued
            changed = true
        }
        if changed { persist(); emit(.changed) }
        pumpQueue()
    }

    private func notifyDownloadComplete(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = title
        content.sound = .default
        let request = UNNotificationRequest(identifier: "crucible.download.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Network changes

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.handlePathChange(isOnWiFi: wifi, isOnline: online)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.guitaripod.crucible.netmon"))
    }

    private func handlePathChange(isOnWiFi wifi: Bool, isOnline online: Bool) {
        let wasWiFi = isOnWiFi
        isOnWiFi = wifi
        isOnline = online
        if !Preferences.downloadOverCellular {
            if !wifi {
                if items.contains(where: { $0.state == .downloading }) {
                    pauseActiveForWiFi()
                }
                pumpQueue()
            } else if !wasWiFi {
                promoteWaitingAndPump()
            }
        } else if online {
            promoteWaitingAndPump()
        }
    }

    private func promoteWaitingAndPump() {
        for i in items.indices where items[i].state == .waitingForWiFi {
            items[i].state = .queued
        }
        persist()
        emit(.changed)
        pumpQueue()
    }

    private func pauseActiveForWiFi() {
        for i in items.indices where items[i].state == .downloading {
            cancelTask(items[i].ratingKey)
            items[i].state = .waitingForWiFi
        }
        persist()
        emit(.changed)
    }

    // MARK: - Recovery

    private func finishBootstrap() {
        for i in items.indices {
            switch items[i].state {
            case .downloading:
                if completedAssetExists(items[i]) {
                    items[i].state = .completed
                    items[i].progress = 1
                    items[i].completedAt = items[i].completedAt ?? Date()
                } else {
                    items[i].state = .queued
                }
            case .waitingForWiFi:
                items[i].state = .queued
            default:
                break
            }
        }
        Task { [store, items] in
            await store.reconcile(keepRatingKeys: Set(items.map(\.ratingKey)))
        }
        persist()
        emit(.changed)
        pumpQueue()
    }

    private func completedAssetExists(_ item: DownloadItem) -> Bool {
        FileManager.default.fileExists(atPath: DownloadPaths.playlistURL(ratingKey: item.ratingKey).path)
    }

    // MARK: - Progress (MainActor)

    fileprivate func handleProgress(ratingKey: String, token: String, fraction: Double) {
        guard let idx = index(ratingKey), taskTokens[ratingKey] == token, items[idx].state == .downloading else { return }
        let clamped = min(0.999, max(0, fraction))
        items[idx].progress = clamped
        items[idx].downloadedBytes = Int64(clamped * Double(items[idx].knownBytes))
        let now = Date()
        if let last = lastProgressEmit[ratingKey], now.timeIntervalSince(last) < 0.25 { return }
        lastProgressEmit[ratingKey] = now
        emit(.progress(ratingKey: ratingKey, fractionCompleted: clamped, downloadedBytes: items[idx].downloadedBytes, totalBytes: items[idx].knownBytes))
    }

    // MARK: - Persistence

    private func persist() {
        let snapshot = items
        Task { [store] in await store.save(snapshot) }
    }
}
