import CLinuxServices
import CrucibleCore
import CrucibleUI
import Foundation
import Kiln
import MidgarCore

/// The desktop's notifications (org.freedesktop.Notifications): a notification from Crucible's desktop entry, with a poster
/// when there is one, that opens its `crucible://` link and brings the window forward when clicked.
@MainActor
final class DesktopNotifications {
    /// A clicked notification's link, with the token for raising the window when the notification server gave one.
    var onOpen: ((URL, String?) -> Void)?
    /// Whether any notification was shown.
    private(set) var hasPosted = false

    private let handle: OpaquePointer
    private weak var loop: EventLoop?
    private var links: [UInt32: URL] = [:]

    /// The notifier the bus callbacks reach; the app has one.
    private static weak var current: DesktopNotifications?

    /// Where posters for notifications are kept, the newest few only.
    private nonisolated static let posters = AppPlatform.cachesDirectory.appendingPathComponent("notifications", isDirectory: true)
    private nonisolated static let keptPosters = 24

    init?(loop: EventLoop) {
        guard let handle = crucible_notifier_create(DesktopNotifications.handler, nil) else { return nil }
        self.handle = handle
        self.loop = loop
        loop.add(fd: crucible_notifier_fd(handle)) { [weak self] _ in
            guard let self else { return }
            crucible_notifier_process(self.handle)
        }
        DesktopNotifications.current = self
    }

    private static let handler: crucible_notify_handler = { _, id, action, token in
        let tokenText = token.map { String(cString: $0) }
        let actionText = action.map { String(cString: $0) } ?? ""
        MainActor.assumeIsolated {
            guard let notifications = DesktopNotifications.current, actionText == "default" || actionText == "open",
                  let link = notifications.links.removeValue(forKey: id) else { return }
            notifications.onOpen?(link, tokenText)
        }
    }

    /// Shows `title` and `body`, opening `link` when clicked; `poster` is the picture's file.
    func post(title: String, body: String, poster: URL?, link: URL) {
        let id = crucible_notify(handle, title, body, poster?.path)
        guard id != 0 else {
            MidgarLog.notice("The desktop showed no notification for \(link.host ?? "a title")", category: .lifecycle)
            return
        }
        links[id] = link
        hasPosted = true
        if links.count > 64, let oldest = links.keys.min() { links[oldest] = nil }
    }

    /// Saves the poster at `path` on the server for a notification, keeping only the newest few.
    static func poster(path: String?, key: String, token: String) async -> URL? {
        guard let path, let url = Artwork.pipeline?.url(path: path, kind: .poster, pixelWidth: 256) else { return nil }
        guard let data = try? await PlexArtworkPipeline.fetcher(token: token)(url) else { return nil }
        let file = posters.appendingPathComponent("\(key.filter { $0.isLetter || $0.isNumber || $0 == "." }).jpg")
        return await Task.detached(priority: .utility) { () -> URL? in
            try? FileManager.default.createDirectory(at: posters, withIntermediateDirectories: true)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
            prunePosters()
            return file
        }.value
    }

    private nonisolated static func prunePosters() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: posters, includingPropertiesForKeys: keys) else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keptPosters) { try? FileManager.default.removeItem(at: file) }
    }

    func close() {
        loop?.remove(fd: crucible_notifier_fd(handle))
        crucible_notifier_destroy(handle)
        if DesktopNotifications.current === self { DesktopNotifications.current = nil }
    }
}

/// New episodes of the shows being watched and watchlist titles arriving on the server, announced on the desktop while
/// Crucible runs (the iPhone's `NotificationCoordinator.checkArrivals`). The first look after connecting only notes what is
/// already there, which Home shows anyway; later looks, every quarter hour, announce what arrived since.
@MainActor
final class LibraryNewsWatcher {
    private let notifications: DesktopNotifications
    private var task: Task<Void, Never>?

    /// Every quarter hour; `CRUCIBLE_NEWS_INTERVAL` (seconds) shortens it for headless checks.
    static let interval: Duration = .seconds(ProcessInfo.processInfo.environment["CRUCIBLE_NEWS_INTERVAL"].flatMap(Int.init) ?? 15 * 60)

    init(notifications: DesktopNotifications) {
        self.notifications = notifications
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            _ = await self?.check(post: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled, let self else { return }
                _ = await self.check(post: true)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One look at the server; returns whether it answered.
    @discardableResult
    func check(post: Bool) async -> Bool {
        guard Preferences.notifies(.newEpisodes) || Preferences.notifies(.watchlistArrivals) else { return true }
        guard !DemoMode.shared.isActive, let connection = ServerBootstrap.connection() else { return false }
        let api = APIClient(baseURL: connection.serverURI, token: connection.authToken)
        let ledger = NotificationLedger.shared
        let since = ledger.checkWindowStart(server: connection.machineIdentifier, now: Date())
        let check = LibraryNewsCheck.live(api: api, includeWatchlist: Preferences.notifies(.watchlistArrivals))
        let followed = Preferences.notifies(.newEpisodes) ? FollowedShows.current() : []
        do {
            let news = try await check.run(followed: followed, since: since, announced: ledger.announcedKeys, excluding: LibraryVisibility.excluded)
            if post {
                for show in news.shows where Preferences.notifies(.newEpisodes) { await announce(show, token: connection.authToken) }
                for arrival in news.arrivals where Preferences.notifies(.watchlistArrivals) { await announce(arrival, token: connection.authToken) }
            }
            ledger.noteAnnounced(news.announcedKeys)
            if let newest = news.newestAddedAt { ledger.noteChecked(upTo: newest) }
            return true
        } catch {
            MidgarLog.error("Arrivals check failed: \(error.localizedDescription)", category: .networking)
            return false
        }
    }

    private func announce(_ show: ShowNews, token: String) async {
        let link = show.episodes.count == 1 && show.episodes.first != nil
            ? DeepLink.item(ratingKey: show.episodes[0].id, mediaType: "episode").url
            : DeepLink.item(ratingKey: show.showRatingKey, mediaType: "show").url
        let poster = await DesktopNotifications.poster(path: show.posterPath, key: "show.\(show.showRatingKey)", token: token)
        notifications.post(title: NotificationCopy.newEpisodesTitle(show), body: NotificationCopy.newEpisodesBody(show), poster: poster, link: link)
    }

    private func announce(_ arrival: WatchlistArrival, token: String) async {
        let poster = await DesktopNotifications.poster(path: arrival.posterPath, key: "arrival.\(arrival.ratingKey)", token: token)
        notifications.post(title: NotificationCopy.arrivalTitle(arrival), body: NotificationCopy.arrivalBody, poster: poster,
                           link: DeepLink.item(ratingKey: arrival.ratingKey, mediaType: arrival.mediaType).url)
    }
}
