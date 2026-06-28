import Foundation
import Network
import os
import UIKit
import UserNotifications

/// State-of-the-art offline download engine. Plex only transcodes to HLS, so each download is fetched
/// segment-by-segment over a **background `URLSession`** — transfers run in the system daemon and
/// continue while the app is suspended or terminated, and iOS wakes the app to advance the chain.
/// Segments are fetched sequentially per item (matching Plex's on-demand transcoder); a fresh Plex
/// session is re-minted on failure. Includes a concurrency-limited queue, Wi-Fi-only gating (via
/// per-request cellular policy + iOS deferral), pause/resume/retry, a download Live Activity, and
/// on-disk persistence.
@MainActor
final class DownloadManager: NSObject {
    static let shared = DownloadManager()
    static let sessionIdentifier = "com.guitaripod.crucible.segments"
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "downloads")
    private static let maxSessionRefreshes = 12

    private struct Config { let baseURL: URL; let token: String }
    private var config: Config?

    private struct SegmentJob {
        let base: URL
        let names: [String]
        var completed: Int
        let token: String
        var refreshes: Int
        var total: Int { names.count }
    }

    private(set) var items: [DownloadItem] = []
    private var jobs: [String: SegmentJob] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var resolving: Set<String> = []
    private var observers: [UUID: (DownloadEvent) -> Void] = [:]
    private var lastProgressEmit: [String: Date] = [:]

    let store = DownloadStore()
    var backgroundCompletionHandler: (() -> Void)?

    private let pathMonitor = NWPathMonitor()
    private var isOnWiFi = true
    private var isOnline = true
    private var didBootstrap = false

    #if os(iOS) && canImport(ActivityKit)
    private let liveActivity = DownloadActivityController()
    #endif

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = max(2, Preferences.maxConcurrentDownloads)
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

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
            self.recoverLiveTasks()
        }
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else { completionHandler(); return }
        backgroundCompletionHandler = completionHandler
        _ = session
    }

    func handleEnteredForeground() {
        #if os(iOS) && canImport(ActivityKit)
        liveActivity.sync(items: items, force: true)
        #endif
        pumpQueue()
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

    var hasActiveDownloads: Bool { items.contains { $0.state.isActive } }
    var activeDownloadCount: Int { items.filter { $0.state.isActive }.count }

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
            ratingKey: metadata.id, mediaType: mediaType, title: metadata.title,
            showTitle: metadata.grandparentTitle, grandparentRatingKey: metadata.grandparentRatingKey,
            parentRatingKey: metadata.parentRatingKey, seasonNumber: metadata.parentIndex,
            episodeNumber: metadata.index, year: metadata.year, durationMs: durationMs,
            summary: metadata.summary, plexThumbPath: posterPath, quality: quality,
            isTranscoded: true, fileExtension: "movpkg", hlsRelativePath: nil, state: .queued,
            progress: 0, totalBytes: 0, downloadedBytes: 0,
            estimatedBytes: quality.estimatedBytes(durationMs: durationMs), errorMessage: nil,
            createdAt: Date(), completedAt: nil, viewOffsetMs: metadata.viewOffset ?? 0, markers: []
        )
    }

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
        jobs.removeAll()
        resolving.removeAll()
        lastProgressEmit.removeAll()
        items.removeAll()
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
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
        let activeItems = items.filter { $0.state == .downloading }.count
        var slots = Preferences.maxConcurrentDownloads - activeItems
        guard slots > 0 else { return }
        for item in items where item.state == .queued {
            guard slots > 0 else { break }
            guard jobs[item.ratingKey] == nil, tasks[item.ratingKey] == nil, !resolving.contains(item.ratingKey) else { continue }
            startDownload(item.ratingKey)
            slots -= 1
        }
    }

    private func canStartOnCurrentNetwork() -> Bool {
        Preferences.downloadOverCellular ? isOnline : isOnWiFi
    }

    private func startDownload(_ ratingKey: String) {
        guard config != nil, let idx = index(ratingKey), items[idx].state == .queued else { return }
        items[idx].state = .downloading
        items[idx].errorMessage = nil
        persist()
        emit(.changed)
        beginResolve(ratingKey, countAsFailure: false)
    }

    /// (Re)resolves a fresh Plex session and starts/continues the segment chain.
    private func beginResolve(_ ratingKey: String, countAsFailure: Bool) {
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        guard !resolving.contains(ratingKey) else { return }
        var refreshes = jobs[ratingKey]?.refreshes ?? 0
        if countAsFailure {
            refreshes += 1
            if refreshes > Self.maxSessionRefreshes {
                failItem(ratingKey, message: "Download failed")
                return
            }
        }
        tasks[ratingKey]?.cancel()
        tasks[ratingKey] = nil
        jobs[ratingKey] = nil
        resolving.insert(ratingKey)
        let quality = items[idx].quality
        let carriedRefreshes = refreshes
        Task { [weak self] in
            await self?.performResolve(ratingKey, quality: quality, refreshes: carriedRefreshes)
        }
    }

    private func performResolve(_ ratingKey: String, quality: DownloadQuality, refreshes: Int) async {
        defer { resolving.remove(ratingKey) }
        guard let cfg = config else { return }
        let api = APIClient(baseURL: cfg.baseURL, token: cfg.token)
        do {
            let plan = try await DownloadResolver.plan(api: api, ratingKey: ratingKey, quality: quality)
            guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
            applyPlanMetadata(at: idx, plan: plan)
            if let posterPath = plan.posterPath ?? items[idx].plexThumbPath {
                fetchPoster(path: posterPath, ratingKey: ratingKey, baseURL: cfg.baseURL, token: cfg.token)
            }
            let resolved = try await HLSDownloader.resolve(masterURL: plan.url, ratingKey: ratingKey)
            guard let liveIdx = index(ratingKey), items[liveIdx].state == .downloading else { return }
            jobs[ratingKey] = SegmentJob(base: resolved.base, names: resolved.segments, completed: 0, token: UUID().uuidString, refreshes: refreshes)
            AppLogger.notice("Download \(refreshes == 0 ? "started" : "resumed") key=\(ratingKey) quality=\(quality.shortLabel) segments=\(resolved.segments.count)", .persistence)
            enqueueNextSegment(ratingKey)
        } catch {
            guard index(ratingKey) != nil else { return }
            failItem(ratingKey, message: error.localizedDescription)
        }
    }

    private func applyPlanMetadata(at idx: Int, plan: DownloadResolver.Plan) {
        items[idx].estimatedBytes = plan.estimatedBytes
        items[idx].durationMs = plan.durationMs > 0 ? plan.durationMs : items[idx].durationMs
        items[idx].markers = plan.markers
        if items[idx].summary == nil { items[idx].summary = plan.summary }
        if items[idx].viewOffsetMs == 0 { items[idx].viewOffsetMs = plan.initialViewOffsetMs }
        persist()
    }

    private func enqueueNextSegment(_ ratingKey: String) {
        guard var job = jobs[ratingKey], let idx = index(ratingKey), items[idx].state == .downloading else { return }
        let dir = DownloadPaths.assetDir(ratingKey: ratingKey)
        while job.completed < job.total {
            let onDisk = dir.appendingPathComponent(HLSDownloader.localName(for: job.names[job.completed]))
            guard FileManager.default.fileExists(atPath: onDisk.path) else { break }
            job.completed += 1
        }
        jobs[ratingKey] = job

        items[idx].progress = job.total > 0 ? Double(job.completed) / Double(job.total) : 0
        items[idx].downloadedBytes = Int64(items[idx].progress * Double(items[idx].knownBytes))

        guard job.completed < job.total else {
            finalizeComplete(ratingKey)
            return
        }
        let name = job.names[job.completed]
        guard let url = HLSDownloader.segmentURL(name: name, base: job.base) else {
            failItem(ratingKey, message: "Bad segment URL")
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        request.allowsCellularAccess = Preferences.downloadOverCellular
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)
        task.taskDescription = "\(ratingKey)|\(HLSDownloader.localName(for: name))|\(job.token)"
        tasks[ratingKey] = task
        task.resume()
        emitProgress(ratingKey)
    }

    private func emitProgress(_ ratingKey: String) {
        guard let idx = index(ratingKey) else { return }
        let now = Date()
        if let last = lastProgressEmit[ratingKey], now.timeIntervalSince(last) < 0.4 { return }
        lastProgressEmit[ratingKey] = now
        emit(.progress(ratingKey: ratingKey, fractionCompleted: items[idx].progress, downloadedBytes: items[idx].downloadedBytes, totalBytes: items[idx].knownBytes))
    }

    private func finalizeComplete(_ ratingKey: String) {
        guard let idx = index(ratingKey) else { return }
        let size = HLSDownloader.directorySize(DownloadPaths.assetDir(ratingKey: ratingKey))
        items[idx].state = .completed
        items[idx].progress = 1
        items[idx].totalBytes = size
        items[idx].downloadedBytes = size
        items[idx].completedAt = Date()
        items[idx].errorMessage = nil
        jobs[ratingKey] = nil
        tasks[ratingKey] = nil
        lastProgressEmit[ratingKey] = nil
        persist()
        emit(.finished(ratingKey: ratingKey))
        emit(.changed)
        notifyDownloadComplete(title: items[idx].displayTitle)
        AppLogger.notice("Download finished key=\(ratingKey) bytes=\(size)", .persistence)
        pumpQueue()
    }

    private func failItem(_ ratingKey: String, message: String) {
        guard let idx = index(ratingKey) else { return }
        tasks[ratingKey]?.cancel()
        tasks[ratingKey] = nil
        jobs[ratingKey] = nil
        items[idx].state = .failed
        items[idx].errorMessage = message
        persist()
        emit(.failed(ratingKey: ratingKey, message: message))
        emit(.changed)
        AppLogger.error("Download failed key=\(ratingKey): \(message)", .persistence)
        pumpQueue()
    }

    private func cancelItemTasks(_ ratingKey: String) {
        jobs[ratingKey] = nil
        if let task = tasks[ratingKey] {
            task.cancel()
            tasks[ratingKey] = nil
        }
        session.getAllTasks { tasks in
            for task in tasks where (task.taskDescription?.split(separator: "|").first).map(String.init) == ratingKey {
                task.cancel()
            }
        }
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
        if canStartOnCurrentNetwork(), (wifi && !wasWiFi) || online {
            promoteWaitingAndPump()
        } else {
            pumpQueue()
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

    private func notifyDownloadComplete(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = title
        content.sound = .default
        let request = UNNotificationRequest(identifier: "crucible.download.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Recovery

    private func recoverLiveTasks() {
        session.getAllTasks { [weak self] tasks in
            let liveKeys: Set<String> = Set(tasks.compactMap { task in
                guard task.state == .running || task.state == .suspended else { return nil }
                return task.taskDescription?.split(separator: "|").first.map(String.init)
            })
            Task { @MainActor [weak self] in
                self?.finishBootstrap(liveKeys: liveKeys)
            }
        }
    }

    private func finishBootstrap(liveKeys: Set<String>) {
        for i in items.indices {
            switch items[i].state {
            case .downloading:
                if completedAssetExists(items[i]) {
                    items[i].state = .completed
                    items[i].progress = 1
                    items[i].completedAt = items[i].completedAt ?? Date()
                } else if !liveKeys.contains(items[i].ratingKey) {
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
        // Live recovered tasks drive their own chain via the delegate; non-live .downloading items
        // were demoted to .queued above and are started by pumpQueue.
        pumpQueue()
    }

    private func completedAssetExists(_ item: DownloadItem) -> Bool {
        FileManager.default.fileExists(atPath: DownloadPaths.playlistURL(ratingKey: item.ratingKey).path)
    }

    // MARK: - Delegate-driven handlers (MainActor)

    fileprivate func handleSegmentFinished(ratingKey: String, token: String) {
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        tasks[ratingKey] = nil
        if jobs[ratingKey] == nil {
            beginResolve(ratingKey, countAsFailure: false)
            return
        }
        guard jobs[ratingKey]?.token == token else { return }
        jobs[ratingKey]?.refreshes = 0
        enqueueNextSegment(ratingKey)
    }

    fileprivate func handleSegmentError(ratingKey: String, token: String) {
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        guard jobs[ratingKey] == nil || jobs[ratingKey]?.token == token else { return }
        tasks[ratingKey] = nil
        beginResolve(ratingKey, countAsFailure: true)
    }

    fileprivate func runBackgroundCompletionHandler() {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }

    // MARK: - Persistence

    private func persist() {
        let snapshot = items
        Task { [store] in await store.save(snapshot) }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let parts = Self.descriptor(downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard (200...299).contains(status), size > 0,
              DownloadPaths.commitSegment(tempURL: location, ratingKey: parts.key, name: parts.name) else {
            Task { @MainActor in DownloadManager.shared.handleSegmentError(ratingKey: parts.key, token: parts.token) }
            return
        }
        Task { @MainActor in DownloadManager.shared.handleSegmentFinished(ratingKey: parts.key, token: parts.token) }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error, let parts = Self.descriptor(task) else { return }
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        Task { @MainActor in DownloadManager.shared.handleSegmentError(ratingKey: parts.key, token: parts.token) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in DownloadManager.shared.runBackgroundCompletionHandler() }
    }

    nonisolated private static func descriptor(_ task: URLSessionTask) -> (key: String, name: String, token: String)? {
        guard let desc = task.taskDescription else { return nil }
        let parts = desc.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}
