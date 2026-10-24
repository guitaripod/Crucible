import CrucibleCore
import Foundation
import Network
import os

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
    static let maxSessionRefreshes = 12
    static let maxResolveRetries = 5

    struct Config { let baseURL: URL; let token: String }
    var config: Config?

    struct SegmentJob {
        let base: URL
        let names: [String]
        var onDisk: Set<String>
        let token: String
        var refreshes: Int
        var total: Int { names.count }
    }

    var items: [DownloadItem] = []
    var jobs: [String: SegmentJob] = [:]
    var resolving: Set<String> = []
    var resolveRetries: [String: Int] = [:]
    var transcodeSessions: [String: String] = [:]
    var stallWatchdogs: [String: Task<Void, Never>] = [:]
    var fallbackFetchers: [String: Task<Void, Never>] = [:]
    var continuedTask: AnyObject?
    var continuedProcessingActive = false
    var continuedUnitsDone: Int64 = 0
    var continuedUnitsTotal: Int64 = 0

    /// Persisted: once the OS background-transfer daemon is caught running none of our tasks (iOS 27
    /// beta + sideload), later launches skip straight to in-process fetching instead of burning a 20s
    /// watchdog per item — a watchdog that never fires if the app is backgrounded first.
    var backgroundSessionBroken: Bool {
        get { UserDefaults.standard.bool(forKey: "crucible.backgroundSessionBroken") }
        set { UserDefaults.standard.set(newValue, forKey: "crucible.backgroundSessionBroken") }
    }
    var observers: [UUID: (DownloadEvent) -> Void] = [:]
    var lastProgressEmit: [String: Date] = [:]

    let store = DownloadStore()
    var backgroundCompletionHandler: (() -> Void)?

    let pathMonitor = NWPathMonitor()
    let enqueueQueue = DispatchQueue(label: "com.guitaripod.crucible.enqueue")
    var isOnWiFi = true
    var isOnline = true
    var didBootstrap = false

    #if os(iOS) && canImport(ActivityKit)
    let liveActivity = DownloadActivityController()
    #endif

    lazy var session: URLSession = {
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

    // MARK: - Persistence

    func persist() {
        let snapshot = items
        Task { [store] in await store.save(snapshot) }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {}
