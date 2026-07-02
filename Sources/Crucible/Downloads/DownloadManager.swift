import BackgroundTasks
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
    static let continuedTaskIdentifier = "com.guitaripod.crucible.download.continued"
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "downloads")
    private static let maxSessionRefreshes = 12
    private static let maxResolveRetries = 5

    private struct Config { let baseURL: URL; let token: String }
    private var config: Config?

    private struct SegmentJob {
        let base: URL
        let names: [String]
        var onDisk: Set<String>
        let token: String
        var refreshes: Int
        var total: Int { names.count }
    }

    private(set) var items: [DownloadItem] = []
    private var jobs: [String: SegmentJob] = [:]
    private var resolving: Set<String> = []
    private var resolveRetries: [String: Int] = [:]
    private var transcodeSessions: [String: String] = [:]
    private var stallWatchdogs: [String: Task<Void, Never>] = [:]
    private var fallbackFetchers: [String: Task<Void, Never>] = [:]
    private var continuedTask: AnyObject?
    private var continuedProcessingActive = false
    private var continuedUnitsDone: Int64 = 0
    private var continuedUnitsTotal: Int64 = 0

    /// Persisted: once the OS background-transfer daemon is caught running none of our tasks (iOS 27
    /// beta + sideload), later launches skip straight to in-process fetching instead of burning a 20s
    /// watchdog per item — a watchdog that never fires if the app is backgrounded first.
    private var backgroundSessionBroken: Bool {
        get { UserDefaults.standard.bool(forKey: "crucible.backgroundSessionBroken") }
        set { UserDefaults.standard.set(newValue, forKey: "crucible.backgroundSessionBroken") }
    }
    private var observers: [UUID: (DownloadEvent) -> Void] = [:]
    private var lastProgressEmit: [String: Date] = [:]

    let store = DownloadStore()
    var backgroundCompletionHandler: (() -> Void)?

    private let pathMonitor = NWPathMonitor()
    private let enqueueQueue = DispatchQueue(label: "com.guitaripod.crucible.enqueue")
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
        configuration.httpMaximumConnectionsPerHost = 1
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
        registerContinuedProcessing()
        #if os(iOS) && canImport(ActivityKit)
        liveActivity.endStale()
        #endif
        LocalMediaServer.shared.start()
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
        AppLogger.notice("Entered foreground; \(activeDownloadCount) active downloads", .lifecycle)
        resolveRetries.removeAll()
        #if os(iOS) && canImport(ActivityKit)
        liveActivity.sync(items: items, force: true)
        #endif
        for item in items where item.state == .downloading {
            if let job = jobs[item.ratingKey], fallbackFetchers[item.ratingKey] == nil {
                scheduleStallWatchdog(item.ratingKey, token: job.token)
            }
        }
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
        let needsForeground = backgroundSessionBroken && UIApplication.shared.applicationState == .background
        if case .progress = event {
            liveActivity.sync(items: items, force: false, needsForeground: needsForeground)
        } else {
            liveActivity.sync(items: items, force: true, needsForeground: needsForeground)
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
        guard FileManager.default.fileExists(atPath: DownloadPaths.playlistURL(ratingKey: ratingKey).path) else { return nil }
        LocalMediaServer.shared.awaitReady(timeout: 2)
        guard let url = LocalMediaServer.shared.playlistURL(ratingKey: ratingKey) else { return nil }
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

    /// Enqueues a batch preserving its order (episode 1 downloads first) and, like single `enqueue`,
    /// re-queues any existing failed/paused member so "Download Remaining" actually retries them.
    @discardableResult
    func enqueueAll(_ metadatas: [PlexMetadata], quality: DownloadQuality? = nil) -> Int {
        let q = quality ?? Preferences.downloadQuality
        var newItems: [DownloadItem] = []
        var touched = 0
        for metadata in metadatas {
            let key = metadata.id
            guard !key.isEmpty else { continue }
            if let idx = index(key) {
                if items[idx].state == .failed || items[idx].state == .paused {
                    items[idx].state = .queued
                    items[idx].errorMessage = nil
                    resolveRetries[key] = nil
                    touched += 1
                }
                continue
            }
            newItems.append(makeItem(metadata: metadata, quality: q))
            touched += 1
        }
        items.insert(contentsOf: newItems, at: 0)
        if touched > 0 {
            persist()
            emit(.changed)
            pumpQueue()
        }
        return touched
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

    func recordOfflineProgress(ratingKey: String, positionSecs: Double, deleteIfWatched: Bool = false) {
        guard let idx = index(ratingKey), items[idx].state == .completed else { return }
        let wasWatched = items[idx].isWatched
        items[idx].viewOffsetMs = Int(max(0, positionSecs) * 1000)
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

    // MARK: - Queue

    /// With the daemon broken, downloads run in-process and need runtime: while backgrounded, only
    /// start new work when a meaningful slice of background time remains. This lets a batch chain
    /// episode-to-episode under the ~30s grace, but never restarts into a doomed frozen fetch the
    /// way an expired-assertion restart would (the cause of a stuck Live Activity).
    private func pumpQueue() {
        guard config != nil else { return }
        if backgroundSessionBroken, UIApplication.shared.applicationState == .background,
           !continuedProcessingActive,
           UIApplication.shared.backgroundTimeRemaining < 10 { return }
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
        // Segments stream over one background session capped to a single connection per host (Plex's
        // transcode session is single-threaded), so downloads run one item at a time — concurrent
        // items would starve each other's transcode sessions into refresh churn.
        guard !items.contains(where: { $0.state == .downloading }) else { return }
        for item in items where item.state == .queued {
            guard jobs[item.ratingKey] == nil, !resolving.contains(item.ratingKey) else { continue }
            startDownload(item.ratingKey)
            return
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
        let oldToken = jobs[ratingKey]?.token
        jobs[ratingKey] = nil
        if let oldToken { cancelInflight(ratingKey, scope: .matching(oldToken)) }
        stopTranscodeSession(ratingKey)
        resolving.insert(ratingKey)
        let quality = items[idx].quality
        let carriedRefreshes = refreshes
        Task { [weak self] in
            await self?.performResolve(ratingKey, quality: quality, refreshes: carriedRefreshes)
        }
    }

    /// Resolving fetches the Plex plan + playlists over a foreground URLSession, which is suspended
    /// while the app is backgrounded. A background-task assertion buys ~30s so a hand-off between
    /// episodes (the resolve) can finish even when iOS woke us only for a background segment event.
    private func performResolve(_ ratingKey: String, quality: DownloadQuality, refreshes: Int) async {
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        let endAssertion = { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid } }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "crucible.resolve.\(ratingKey)") { endAssertion() }
        defer { resolving.remove(ratingKey); endAssertion(); pumpQueue() }
        guard let cfg = config else { return }
        let api = APIClient(baseURL: cfg.baseURL, token: cfg.token)
        var plannedSessionID: String?
        do {
            let plan = try await DownloadResolver.plan(api: api, ratingKey: ratingKey, quality: quality)
            guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
            plannedSessionID = plan.sessionID
            transcodeSessions[ratingKey] = plan.sessionID
            applyPlanMetadata(at: idx, plan: plan)
            if let posterPath = plan.posterPath ?? items[idx].plexThumbPath {
                fetchPoster(path: posterPath, ratingKey: ratingKey, baseURL: cfg.baseURL, token: cfg.token)
            }
            let resolved = try await HLSDownloader.resolve(masterURL: plan.url, ratingKey: ratingKey)
            guard let liveIdx = index(ratingKey), items[liveIdx].state == .downloading else {
                abandonTranscodeSession(plan.sessionID, ratingKey: ratingKey)
                return
            }
            let dir = DownloadPaths.assetDir(ratingKey: ratingKey)
            let onDisk = Set(resolved.segments
                .map { HLSDownloader.localName(for: $0) }
                .filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) })
            let token = UUID().uuidString
            jobs[ratingKey] = SegmentJob(base: resolved.base, names: resolved.segments, onDisk: onDisk, token: token, refreshes: refreshes)
            cancelInflight(ratingKey, scope: .excluding(token))
            resolveRetries[ratingKey] = nil
            AppLogger.notice("Download \(refreshes == 0 ? "started" : "resumed") key=\(ratingKey) quality=\(quality.shortLabel) segments=\(resolved.segments.count) onDisk=\(onDisk.count)", .persistence)
            enqueueAllSegments(ratingKey)
        } catch {
            guard index(ratingKey) != nil else {
                if let plannedSessionID { abandonTranscodeSession(plannedSessionID, ratingKey: ratingKey) }
                return
            }
            handleResolveFailure(ratingKey, error: error)
        }
    }

    /// A timeout/connectivity error during resolve is almost always the app being suspended mid
    /// hand-off, not a dead download — re-queue it rather than failing terminally. While backgrounded
    /// we simply wait for the next foreground entry; while active we retry a bounded number of times.
    private func handleResolveFailure(_ ratingKey: String, error: Error) {
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        jobs[ratingKey] = nil
        stopTranscodeSession(ratingKey)
        if isTransientNetworkError(error) {
            let backgrounded = UIApplication.shared.applicationState == .background
            if backgrounded {
                items[idx].state = .queued
                persist()
                emit(.changed)
                AppLogger.notice("Resolve deferred (app backgrounded) key=\(ratingKey)", .persistence)
                return
            }
            let retries = (resolveRetries[ratingKey] ?? 0) + 1
            if retries <= Self.maxResolveRetries {
                resolveRetries[ratingKey] = retries
                items[idx].state = .queued
                persist()
                emit(.changed)
                AppLogger.notice("Resolve retry \(retries)/\(Self.maxResolveRetries) key=\(ratingKey)", .persistence)
                scheduleResolveRetry()
                return
            }
        }
        resolveRetries[ratingKey] = nil
        failItem(ratingKey, message: error.localizedDescription)
    }

    private func isTransientNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        let transient: Set<URLError.Code> = [
            .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .networkConnectionLost, .notConnectedToInternet, .resourceUnavailable,
            .secureConnectionFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
        ]
        return transient.contains(urlError.code)
    }

    private func scheduleResolveRetry() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.pumpQueue()
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

    /// Enqueues every not-yet-downloaded segment at once. With the session capped to one connection per
    /// host, iOS runs them back-to-back in the daemon in playlist order — sequential (so Plex's
    /// single-threaded transcode session never contends) yet with no per-segment app-wake latency.
    private func enqueueAllSegments(_ ratingKey: String) {
        guard let job = jobs[ratingKey], let idx = index(ratingKey), items[idx].state == .downloading else { return }
        updateProgress(ratingKey)
        let pending: [(url: URL, descriptor: String)] = job.names.compactMap { name in
            let local = HLSDownloader.localName(for: name)
            guard !job.onDisk.contains(local),
                  let url = HLSDownloader.segmentURL(name: name, base: job.base) else { return nil }
            return (url, "\(ratingKey)|\(local)|\(job.token)")
        }
        guard !pending.isEmpty else { finalizeComplete(ratingKey); return }
        recordContinuedProgress(addedUnits: Int64(pending.count))
        if backgroundSessionBroken {
            AppLogger.notice("Background session known broken; fetching in-process key=\(ratingKey)", .persistence)
            startFallbackFetch(ratingKey, token: job.token)
            return
        }
        resumeSegmentTasks(pending, allowsCellular: Preferences.downloadOverCellular)
        scheduleStallWatchdog(ratingKey, token: job.token)
    }

    /// Detects a wedged background session: if not a single segment lands within the window (seen on
    /// iOS 27 beta, where the daemon silently runs none of a sideloaded app's transfers), the item
    /// falls back to an in-process fetch over `URLSession.shared` — the same session the resolve just
    /// succeeded on — so downloads still complete while the app is running.
    private func scheduleStallWatchdog(_ ratingKey: String, token: String) {
        stallWatchdogs[ratingKey]?.cancel()
        let baseline = jobs[ratingKey]?.onDisk.count ?? 0
        stallWatchdogs[ratingKey] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled else { return }
            guard let job = self.jobs[ratingKey], job.token == token, job.onDisk.count == baseline,
                  let idx = self.index(ratingKey), self.items[idx].state == .downloading,
                  self.fallbackFetchers[ratingKey] == nil else { return }
            AppLogger.error("Background session stalled (no segment progress in 20s) key=\(ratingKey); falling back to in-process fetch", .persistence)
            self.backgroundSessionBroken = true
            self.cancelInflight(ratingKey, scope: .matching(token))
            self.startFallbackFetch(ratingKey, token: token)
        }
    }

    /// iOS 26's continued-processing task keeps the in-process fetcher alive long after the ~30s
    /// assertion grace, with system-managed progress UI — the only sanctioned way to keep
    /// user-initiated downloads running in background now that the transfer daemon ignores us.
    private func registerContinuedProcessing() {
        guard #available(iOS 26.0, *) else { return }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.continuedTaskIdentifier, using: nil) { task in
            AppLogger.notice("Continued processing launch handler invoked", .persistence)
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in DownloadManager.shared.adoptContinuedTask(task) }
        }
        AppLogger.notice("Continued processing registration \(registered ? "succeeded" : "FAILED")", .persistence)
    }

    /// `.fail` forces the system to either start the task immediately or throw a diagnosable error;
    /// only when it reports transient load does the `.queue` retry make sense. A `.queue` submit that
    /// silently never launches (observed on this iOS 26/27 line, see FB-referenced forum thread
    /// 807370) would otherwise look identical to success.
    private func submitContinuedTaskIfNeeded(title: String) {
        guard #available(iOS 26.0, *), continuedTask == nil else { return }
        func request(_ strategy: BGContinuedProcessingTaskRequest.SubmissionStrategy) -> BGContinuedProcessingTaskRequest {
            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.continuedTaskIdentifier,
                title: title,
                subtitle: "Downloading for offline playback"
            )
            request.strategy = strategy
            return request
        }
        do {
            try BGTaskScheduler.shared.submit(request(.fail))
            AppLogger.notice("Continued processing task submitted (fail strategy)", .persistence)
        } catch {
            AppLogger.error("Continued processing .fail submit rejected: \(error as NSError); retrying with .queue", .persistence)
            do {
                try BGTaskScheduler.shared.submit(request(.queue))
                AppLogger.notice("Continued processing task submitted (queue strategy)", .persistence)
            } catch {
                AppLogger.error("Continued processing .queue submit rejected: \(error as NSError)", .persistence)
                return
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.continuedTask == nil else { return }
            AppLogger.error("Continued processing task not launched 8s after submit", .persistence)
        }
    }

    @available(iOS 26.0, *)
    private func adoptContinuedTask(_ task: BGContinuedProcessingTask) {
        continuedTask = task
        continuedProcessingActive = true
        continuedUnitsDone = 0
        continuedUnitsTotal = Int64(jobs.values.reduce(0) { $0 + max(0, $1.total - $1.onDisk.count) })
        task.progress.totalUnitCount = max(continuedUnitsTotal, 1)
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.continuedTaskExpired() }
        }
        AppLogger.notice("Continued processing task adopted; remaining units=\(continuedUnitsTotal)", .persistence)
        if !hasActiveDownloads { completeContinuedTaskIfNeeded(success: true) }
    }

    private func continuedTaskExpired() {
        AppLogger.notice("Continued processing expired; suspending in-process fetches", .persistence)
        continuedProcessingActive = false
        for key in Array(fallbackFetchers.keys) { suspendFallbackFetch(key) }
        completeContinuedTaskIfNeeded(success: false)
    }

    private func completeContinuedTaskIfNeeded(success: Bool) {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        continuedTask = nil
        continuedProcessingActive = false
        task.setTaskCompleted(success: success)
        AppLogger.notice("Continued processing task completed success=\(success)", .persistence)
    }

    private func recordContinuedProgress(addedUnits: Int64 = 0, completedOne: Bool = false) {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        if addedUnits > 0 {
            continuedUnitsTotal += addedUnits
            task.progress.totalUnitCount = max(continuedUnitsTotal, 1)
        }
        if completedOne {
            continuedUnitsDone += 1
            task.progress.completedUnitCount = continuedUnitsDone
        }
    }

    /// In-process fetches stop when iOS suspends the app; a background-task assertion buys ~30s of
    /// grace after backgrounding, then the item is honestly re-queued (auto-resumes on foreground)
    /// and the Live Activity updates to Queued instead of freezing at a stale percentage.
    private func suspendFallbackFetch(_ ratingKey: String) {
        guard fallbackFetchers[ratingKey] != nil, !continuedProcessingActive else { return }
        fallbackFetchers.removeValue(forKey: ratingKey)?.cancel()
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        jobs[ratingKey] = nil
        items[idx].state = .queued
        persist()
        emit(.changed)
        AppLogger.notice("Fallback fetch suspended (background time expired) key=\(ratingKey)", .persistence)
    }

    private func startFallbackFetch(_ ratingKey: String, token: String) {
        if let idx = index(ratingKey) {
            submitContinuedTaskIfNeeded(title: items[idx].displayTitle)
        }
        fallbackFetchers[ratingKey]?.cancel()
        fallbackFetchers[ratingKey] = Task { @MainActor [weak self] in
            var bgTask: UIBackgroundTaskIdentifier = .invalid
            let endAssertion = { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid } }
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "crucible.fallback.\(ratingKey)") { [weak self] in
                self?.suspendFallbackFetch(ratingKey)
                endAssertion()
            }
            if bgTask == .invalid, UIApplication.shared.applicationState == .background {
                self?.suspendFallbackFetch(ratingKey)
                return
            }
            defer {
                self?.fallbackFetchers[ratingKey] = nil
                endAssertion()
            }
            var fetched = 0
            while let self, !Task.isCancelled,
                  let job = self.jobs[ratingKey], job.token == token,
                  let idx = self.index(ratingKey), self.items[idx].state == .downloading {
                guard let name = job.names.first(where: { !job.onDisk.contains(HLSDownloader.localName(for: $0)) }) else { return }
                let local = HLSDownloader.localName(for: name)
                guard let url = HLSDownloader.segmentURL(name: name, base: job.base) else {
                    self.failItem(ratingKey, message: "Could not build segment URL")
                    return
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 90
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                do {
                    let (tmp, response) = try await URLSession.shared.download(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard !Task.isCancelled, self.jobs[ratingKey]?.token == token else { return }
                    guard (200...299).contains(status),
                          DownloadPaths.commitSegment(tempURL: tmp, ratingKey: ratingKey, name: local) else {
                        AppLogger.error("Fallback segment failed status=\(status) key=\(ratingKey) name=\(local)", .persistence)
                        self.handleSegmentError(ratingKey: ratingKey, token: token)
                        return
                    }
                    fetched += 1
                    if fetched == 1 || fetched % 25 == 0 {
                        AppLogger.notice("Fallback fetch progress key=\(ratingKey) fetched=\(fetched)", .persistence)
                    }
                    self.handleSegmentFinished(ratingKey: ratingKey, name: local, token: token)
                } catch {
                    guard !Task.isCancelled else { return }
                    AppLogger.error("Fallback segment error key=\(ratingKey): \(error.localizedDescription)", .persistence)
                    self.handleSegmentError(ratingKey: ratingKey, token: token)
                    return
                }
            }
        }
    }

    /// Creates and resumes the background segment tasks off the main thread: spawning a few hundred
    /// background tasks at once is XPC-heavy and would hitch the UI at every item boundary (painfully
    /// visible when downloading a whole season). The serial queue preserves playlist order, which the
    /// single-connection session then streams sequentially for Plex's on-demand transcoder.
    private func resumeSegmentTasks(_ pending: [(url: URL, descriptor: String)], allowsCellular: Bool) {
        let session = self.session
        enqueueQueue.async {
            for segment in pending {
                var request = URLRequest(url: segment.url)
                request.timeoutInterval = 90
                request.allowsCellularAccess = allowsCellular
                request.setValue("*/*", forHTTPHeaderField: "Accept")
                let task = session.downloadTask(with: request)
                task.taskDescription = segment.descriptor
                task.resume()
            }
            AppLogger.notice("Enqueued \(pending.count) background segment tasks", .persistence)
        }
    }

    private func updateProgress(_ ratingKey: String) {
        guard let job = jobs[ratingKey], let idx = index(ratingKey) else { return }
        items[idx].progress = job.total > 0 ? Double(job.onDisk.count) / Double(job.total) : 0
        items[idx].downloadedBytes = Int64(items[idx].progress * Double(items[idx].knownBytes))
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
        cancelInflight(ratingKey)
        stopTranscodeSession(ratingKey)
        lastProgressEmit[ratingKey] = nil
        resolveRetries[ratingKey] = nil
        persist()
        emit(.finished(ratingKey: ratingKey))
        emit(.changed)
        notifyDownloadComplete(items[idx])
        AppLogger.notice("Download finished key=\(ratingKey) bytes=\(size)", .persistence)
        pumpQueue()
        if !hasActiveDownloads { completeContinuedTaskIfNeeded(success: true) }
    }

    private func failItem(_ ratingKey: String, message: String) {
        guard let idx = index(ratingKey) else { return }
        jobs[ratingKey] = nil
        cancelInflight(ratingKey)
        stopTranscodeSession(ratingKey)
        items[idx].state = .failed
        items[idx].errorMessage = message
        persist()
        emit(.failed(ratingKey: ratingKey, message: message))
        emit(.changed)
        AppLogger.error("Download failed key=\(ratingKey): \(message)", .persistence)
        notifyDownloadFailed(items[idx], message: message)
        pumpQueue()
        if !hasActiveDownloads { completeContinuedTaskIfNeeded(success: false) }
    }

    private func cancelItemTasks(_ ratingKey: String) {
        jobs[ratingKey] = nil
        stallWatchdogs.removeValue(forKey: ratingKey)?.cancel()
        fallbackFetchers.removeValue(forKey: ratingKey)?.cancel()
        cancelInflight(ratingKey)
        stopTranscodeSession(ratingKey)
    }

    /// Scopes a cancel sweep by segment-task generation. `getAllTasks` snapshots asynchronously, so an
    /// unscoped sweep issued before a re-resolve could land after the NEW job's tasks exist and cancel
    /// them — cancellations are ignored by the delegate, leaving the item stuck at `.downloading`
    /// forever. Re-resolve paths therefore cancel `.matching` the old token (and `.excluding` the new
    /// one as a straggler catch-up); terminal paths (pause/delete/fail/complete) sweep `.all`.
    private enum CancelScope {
        case all
        case matching(String)
        case excluding(String)

        func admits(_ token: String) -> Bool {
            switch self {
            case .all: return true
            case .matching(let t): return token == t
            case .excluding(let t): return token != t
            }
        }
    }

    private func cancelInflight(_ ratingKey: String, scope: CancelScope = .all) {
        cancelInflight(keys: [ratingKey], scope: scope)
    }

    /// Rides the enqueue queue so the cancel sweep is ordered after any in-flight off-main task
    /// creation — a pause/delete issued while segments are still being spawned can never leak
    /// orphan transfers that would keep downloading in the daemon.
    private func cancelInflight(keys: Set<String>, scope: CancelScope = .all) {
        let session = self.session
        enqueueQueue.async {
            session.getAllTasks { tasks in
                for task in tasks {
                    guard let desc = task.taskDescription else { continue }
                    let parts = desc.split(separator: "|", maxSplits: 2).map(String.init)
                    guard parts.count == 3, keys.contains(parts[0]), scope.admits(parts[2]) else { continue }
                    task.cancel()
                }
            }
        }
    }

    /// Downloads mint a fresh Plex transcode session per resolve; tell the server to reap it as soon
    /// as the job ends (complete/fail/pause/delete/re-resolve) instead of leaving it to idle-timeout.
    private func stopTranscodeSession(_ ratingKey: String) {
        guard let sessionID = transcodeSessions.removeValue(forKey: ratingKey) else { return }
        stopTranscode(sessionID: sessionID)
    }

    /// Covers the mid-resolve teardown race: a pause/delete may stop-and-forget the session while the
    /// playlist fetches are still in flight and about to (re)start it server-side, so bail-out paths
    /// stop the planned session directly instead of relying on the (already cleared) map entry.
    private func abandonTranscodeSession(_ sessionID: String, ratingKey: String) {
        if transcodeSessions[ratingKey] == sessionID { transcodeSessions[ratingKey] = nil }
        stopTranscode(sessionID: sessionID)
    }

    private func stopTranscode(sessionID: String) {
        guard let cfg = config else { return }
        let api = APIClient(baseURL: cfg.baseURL, token: cfg.token)
        Task.detached(priority: .utility) {
            try? await api.requestVoid(.stopTranscode(session: sessionID))
        }
    }

    /// Marks a download watched on the server the moment local playback crosses the watched
    /// threshold, so On Deck stays honest even when the item is then auto-deleted.
    private func scrobbleBestEffort(_ ratingKey: String) {
        guard let cfg = config else { return }
        let api = APIClient(baseURL: cfg.baseURL, token: cfg.token)
        Task.detached(priority: .utility) {
            try? await api.requestVoid(.scrobble(ratingKey: ratingKey))
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

    private func notifyDownloadComplete(_ item: DownloadItem) {
        var parts: [String] = []
        if let subtitle = item.episodeSubtitle { parts.append(subtitle) }
        parts.append(item.quality.shortLabel)
        if item.totalBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))
        }
        postDownloadNotification(
            title: item.displayTitle,
            subtitle: "Download complete",
            body: parts.joined(separator: " · "),
            ratingKey: item.ratingKey,
            mediaType: item.mediaType
        )
    }

    /// The Live Activity ends immediately when the last item fails, indistinguishable from success at
    /// a glance — a failure notification is the only lock-screen signal the download did not finish.
    private func notifyDownloadFailed(_ item: DownloadItem, message: String) {
        var parts: [String] = []
        if let subtitle = item.episodeSubtitle { parts.append(subtitle) }
        parts.append(message)
        postDownloadNotification(
            title: item.displayTitle,
            subtitle: "Download failed",
            body: parts.joined(separator: " · "),
            ratingKey: item.ratingKey,
            mediaType: item.mediaType
        )
    }

    private func postDownloadNotification(title: String, subtitle: String, body: String, ratingKey: String, mediaType: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.threadIdentifier = "crucible.downloads"
        content.userInfo = ["ratingKey": ratingKey, "mediaType": mediaType]
        if let attachment = posterAttachment(ratingKey: ratingKey) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: "crucible.download.\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Attachments are moved into the notification store, so the poster is copied to a temp file
    /// first — attaching the original would delete the artwork the Downloads UI still displays.
    private func posterAttachment(ratingKey: String) -> UNNotificationAttachment? {
        let poster = DownloadPaths.posterURL(ratingKey: ratingKey)
        guard FileManager.default.fileExists(atPath: poster.path) else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-poster-\(ratingKey)-\(UUID().uuidString).jpg")
        do {
            try FileManager.default.copyItem(at: poster, to: tmp)
            return try UNNotificationAttachment(identifier: "poster", url: tmp)
        } catch {
            return nil
        }
    }

    // MARK: - Recovery

    private func recoverLiveTasks() {
        // Clean slate: cancel any tasks left in the background session from a previous launch, then
        // re-resolve each active download fresh (it resumes from the segments already on disk). This
        // avoids trusting a recovered task that may be stuck, which would freeze the item.
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
            Task { @MainActor in DownloadManager.shared.finishBootstrap() }
        }
    }

    private func finishBootstrap() {
        for i in items.indices {
            switch items[i].state {
            case .downloading:
                if completedAssetExists(items[i]) {
                    items[i].state = .completed
                    items[i].progress = 1
                    items[i].completedAt = items[i].completedAt ?? Date()
                }
            case .completed:
                if !completedAssetExists(items[i]) {
                    items[i].state = .queued
                    items[i].progress = 0
                    items[i].completedAt = nil
                    AppLogger.notice("Download re-queued (asset incomplete on disk) key=\(items[i].ratingKey)", .persistence)
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
        for item in items where item.state == .downloading {
            beginResolve(item.ratingKey, countAsFailure: false)
        }
        pumpQueue()
    }

    /// True only when the persisted playlist exists AND every segment it references is on disk. The
    /// playlist is written at resolve time — before any segment downloads — so its mere presence says
    /// nothing about completeness; trusting it marked interrupted downloads as finished.
    private func completedAssetExists(_ item: DownloadItem) -> Bool {
        let playlistURL = DownloadPaths.playlistURL(ratingKey: item.ratingKey)
        guard let names = HLSDownloader.referencedLocalNames(inPlaylistAt: playlistURL), !names.isEmpty else { return false }
        let dir = DownloadPaths.assetDir(ratingKey: item.ratingKey)
        let fm = FileManager.default
        return names.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    // MARK: - Delegate-driven handlers (MainActor)

    fileprivate func handleSegmentFinished(ratingKey: String, name: String, token: String) {
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        if jobs[ratingKey] == nil {
            beginResolve(ratingKey, countAsFailure: false)
            return
        }
        guard jobs[ratingKey]?.token == token else { return }
        jobs[ratingKey]?.onDisk.insert(name)
        jobs[ratingKey]?.refreshes = 0
        recordContinuedProgress(completedOne: true)
        updateProgress(ratingKey)
        if let job = jobs[ratingKey], job.onDisk.count >= job.total {
            finalizeComplete(ratingKey)
        }
    }

    fileprivate func handleSegmentError(ratingKey: String, token: String) {
        guard let idx = index(ratingKey), items[idx].state == .downloading else { return }
        guard jobs[ratingKey] == nil || jobs[ratingKey]?.token == token else { return }
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
            AppLogger.error("Segment rejected status=\(status) size=\(size) key=\(parts.key) name=\(parts.name)", .persistence)
            Task { @MainActor in DownloadManager.shared.handleSegmentError(ratingKey: parts.key, token: parts.token) }
            return
        }
        Task { @MainActor in DownloadManager.shared.handleSegmentFinished(ratingKey: parts.key, name: parts.name, token: parts.token) }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error, let parts = Self.descriptor(task) else { return }
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        AppLogger.error("Segment task error key=\(parts.key) name=\(parts.name) \(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)", .persistence)
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
