import BackgroundTasks
import CrucibleCore
import CrucibleDesign
import CrucibleStats
import MidgarCore
import UIKit
import UserNotifications

/// Every notification the iPhone sends besides downloads: reminders to rate what you finished (with star buttons that rate
/// without opening the app), new episodes of the shows you watch, watchlist titles that arrived, the Sunday recap and Year
/// in Review. Each kind follows its switch in Settings › Notifications. Arrivals are found by a background refresh; nothing
/// ever leaves the device but the requests to your own server and to plex.tv for your watchlist.
@MainActor
final class NotificationCoordinator {
    static let shared = NotificationCoordinator()

    static let refreshTaskIdentifier = "com.guitaripod.crucible.refresh"
    static let rateCategory = "crucible.rate"
    private static let rateActionPrefix = "rate."
    private static let rateIdentifierPrefix = "crucible.rate."
    private static let recapIdentifier = "crucible.recap"
    private static let refreshInterval: TimeInterval = 2 * 3_600
    private static let quickRatings = [10, 8, 6, 4, 2]

    private let center = UNUserNotificationCenter.current()
    private var ledgerObserver: UUID?
    private var backgroundObserver: (any NSObjectProtocol)?
    private var foregroundObserver: (any NSObjectProtocol)?

    /// Called once from `application(_:didFinishLaunchingWithOptions:)`: the background task must be registered before
    /// launch ends.
    func install() {
        registerCategories()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in NotificationCoordinator.shared.runBackgroundRefresh(refresh) }
        }
        ledgerObserver = FinishedTitlesLedger.shared.addObserver { [weak self] in self?.syncRatingReminders() }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in NotificationCoordinator.shared.didEnterBackground() }
        }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in NotificationCoordinator.shared.willEnterForeground() }
        }
    }

    /// A switch in Settings › Notifications changed: bring every scheduled notification in line with it.
    func preferencesChanged() {
        if NotificationKind.allCases.contains(where: { Preferences.notifies($0) }) {
            Task { await requestPermissionIfNeeded() }
        }
        syncRatingReminders()
        Task { await scheduleWeeklyRecap() }
        scheduleYearInReview()
        scheduleBackgroundRefresh()
        if Preferences.notifies(.newEpisodes) || Preferences.notifies(.watchlistArrivals) {
            markCurrentArrivalsSeen()
        }
    }

    /// Asks for permission the first time a notification is about to matter. Returns whether alerts may show.
    @discardableResult
    func requestPermissionIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }

    // MARK: - Rating reminders

    private func syncRatingReminders() {
        let server = ServerBootstrap.savedMachineIdentifier
        let asks = FinishedTitlesLedger.shared.asks(now: Date(), server: server)
        let wanted = Set(asks.map { Self.rateIdentifierPrefix + $0.ratingKey })
        Task { [center] in
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.rateIdentifierPrefix) }
            let delivered = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(Self.rateIdentifierPrefix) }
            let stale = (pending + delivered).filter { !wanted.contains($0) || !Preferences.notifies(.ratingReminders) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            center.removeDeliveredNotifications(withIdentifiers: stale)
        }
        guard Preferences.notifies(.ratingReminders) else { return }
        for ask in NotificationLedger.shared.asksNeedingReminders(asks, server: server) {
            NotificationLedger.shared.noteReminded(ask)
            Task { await scheduleReminder(for: ask) }
        }
    }

    private func scheduleReminder(for ask: RatingAsk) async {
        guard await requestPermissionIfNeeded() else { return }
        let content = UNMutableNotificationContent()
        content.title = NotificationCopy.ratingTitle(for: ask)
        content.body = NotificationCopy.ratingBody(for: ask)
        content.categoryIdentifier = Self.rateCategory
        content.threadIdentifier = Self.rateCategory
        content.userInfo = ["kind": "rate", "ratingKey": ask.ratingKey, "mediaType": ask.mediaType, "title": ask.title]
        if let attachment = await Self.posterAttachment(path: ask.posterPath) { content.attachments = [attachment] }
        let date = ReminderSchedule.ratingReminder(finishedAt: ask.finishedAt, timing: Preferences.ratingReminderTiming, quietHours: Preferences.quietHours)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(60, date.timeIntervalSinceNow), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: Self.rateIdentifierPrefix + ask.ratingKey, content: content, trigger: trigger))
        MidgarLog.info("Rating reminder scheduled ratingKey=\(ask.ratingKey) reason=\(ask.reason.key) at=\(date)", category: .lifecycle)
    }

    private func registerCategories() {
        let stars = Self.quickRatings.map { halfStars in
            UNNotificationAction(
                identifier: Self.rateActionPrefix + String(halfStars),
                title: String(repeating: "★", count: halfStars / 2),
                options: [],
                icon: UNNotificationActionIcon(systemImageName: "star.fill")
            )
        }
        let rate = UNNotificationCategory(identifier: Self.rateCategory, actions: stars, intentIdentifiers: [], options: [])
        center.setNotificationCategories([rate])
    }

    // MARK: - Responses

    /// Handles a tap on a notification or one of its buttons. A star button rates in the background, without opening the app.
    func handle(_ tap: NotificationTap) async {
        if tap.category == Self.rateCategory, tap.action.hasPrefix(Self.rateActionPrefix), let ratingKey = tap.ratingKey,
           let halfStars = Int(tap.action.dropFirst(Self.rateActionPrefix.count)), let rating = UserRating(halfStars: halfStars) {
            await quickRate(ratingKey: ratingKey, rating: rating)
            return
        }
        guard tap.action == UNNotificationDefaultActionIdentifier else { return }
        let tabBar = Self.frontTabBar()
        switch tap.kind {
        case "rate":
            guard let ratingKey = tap.ratingKey, let mediaType = tap.mediaType else { return }
            let ask = FinishedTitlesLedger.shared.asks(now: Date(), server: ServerBootstrap.savedMachineIdentifier).first { $0.ratingKey == ratingKey }
                ?? RatingAsk(ratingKey: ratingKey, mediaType: mediaType, title: tap.title ?? "", posterPath: nil, reason: .finishedMovie, finishedAt: Date())
            tabBar?.presentRating(for: ask)
        case "statistics":
            tabBar?.openStatistics()
        default:
            guard let ratingKey = tap.ratingKey, let mediaType = tap.mediaType else { return }
            tabBar?.openMedia(ratingKey: ratingKey, mediaType: mediaType)
        }
    }

    private func quickRate(ratingKey: String, rating: UserRating) async {
        guard let connection = ServerBootstrap.connection() else { return }
        let api = APIClient(baseURL: connection.serverURI, token: connection.authToken)
        do {
            try await RatingService.setRating(rating, ratingKey: ratingKey, api: api)
            MidgarLog.notice("Rated ratingKey=\(ratingKey) \(rating.stars) stars from a notification", category: .lifecycle)
        } catch {
            MidgarLog.error("Rating from a notification failed ratingKey=\(ratingKey): \(error.localizedDescription)", category: .lifecycle)
        }
    }

    private static func frontTabBar() -> TabBarController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.sorted { $0.activationState.rawValue < $1.activationState.rawValue }
            .compactMap { ($0.keyWindow ?? $0.windows.first)?.rootViewController as? TabBarController }
            .first
    }

    // MARK: - Weekly recap and Year in Review

    private func didEnterBackground() {
        Task { await scheduleWeeklyRecap() }
        scheduleYearInReview()
        scheduleBackgroundRefresh()
    }

    private func willEnterForeground() {
        markCurrentArrivalsSeen()
    }

    /// Next Sunday's recap carries this week's numbers as they stand, so it is only scheduled while the Sunday is in this week.
    private func scheduleWeeklyRecap() async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.recapIdentifier])
        guard Preferences.notifies(.weeklyRecap), let store = StatsManager.shared.store else { return }
        let now = Date()
        let date = ReminderSchedule.nextRecap(after: now)
        guard Self.isSameMondayWeek(date, now),
              let summary = await store.homeWeekSummaryOrNil(now: now), summary.thisWeekSeconds > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = NotificationCopy.recapTitle
        content.body = NotificationCopy.recapBody(seconds: summary.thisWeekSeconds, deltaPercent: summary.deltaPercent)
        content.interruptionLevel = .passive
        content.userInfo = ["kind": "statistics"]
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: Self.recapIdentifier, content: content, trigger: trigger))
    }

    /// The recap's Sunday ends a Monday-to-Sunday week, so it belongs to `now`'s week when it is fewer days away than are left.
    private static func isSameMondayWeek(_ sunday: Date, _ now: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: now)
        let daysToSunday = (8 - weekday) % 7
        let endOfWeek = Calendar.current.date(byAdding: .day, value: daysToSunday + 1, to: Calendar.current.startOfDay(for: now)) ?? now
        return sunday < endOfWeek
    }

    private func scheduleYearInReview() {
        let year = Calendar.current.component(.year, from: Date())
        let identifier = "crucible.yearInReview.\(year)"
        guard Preferences.notifies(.yearInReview), StatsManager.shared.store != nil,
              let date = ReminderSchedule.yearInReview(after: Date()) else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            return
        }
        let content = UNMutableNotificationContent()
        content.title = NotificationCopy.yearInReviewTitle(year: year)
        content.body = NotificationCopy.yearInReviewBody
        content.userInfo = ["kind": "statistics"]
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        Task { [center] in try? await center.add(request) }
    }

    // MARK: - New episodes and watchlist arrivals

    private var wantsArrivalChecks: Bool {
        Preferences.notifies(.newEpisodes) || Preferences.notifies(.watchlistArrivals) || Preferences.notifies(.weeklyRecap)
    }

    private func scheduleBackgroundRefresh() {
        guard wantsArrivalChecks, ServerBootstrap.connection() != nil, !DemoMode.shared.isActive else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(Self.refreshInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            MidgarLog.error("Background refresh not scheduled: \(error.localizedDescription)", category: .lifecycle)
        }
    }

    private func runBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let work = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let posted = await checkArrivals(post: true)
            await scheduleWeeklyRecap()
            return posted
        }
        task.expirationHandler = { work.cancel() }
        Task { @MainActor in
            let success = await work.value
            task.setTaskCompleted(success: success)
        }
    }

    /// While the app is open what arrived is on screen already, so it is noted as seen instead of announced later.
    private func markCurrentArrivalsSeen() {
        guard Preferences.notifies(.newEpisodes) || Preferences.notifies(.watchlistArrivals) else { return }
        Task { _ = await checkArrivals(post: false) }
    }

    @discardableResult
    private func checkArrivals(post: Bool) async -> Bool {
        guard !DemoMode.shared.isActive, let connection = ServerBootstrap.connection() else { return false }
        let api = APIClient(baseURL: connection.serverURI, token: connection.authToken)
        let ledger = NotificationLedger.shared
        let since = ledger.checkWindowStart(server: connection.machineIdentifier, now: Date())
        let check = LibraryNewsCheck.live(api: api, includeWatchlist: Preferences.notifies(.watchlistArrivals))
        let followed = Preferences.notifies(.newEpisodes) ? FollowedShows.current() : []
        do {
            let news = try await check.run(followed: followed, since: since, announced: ledger.announcedKeys)
            if post, !news.isEmpty, await requestPermissionIfNeeded() {
                for show in news.shows where Preferences.notifies(.newEpisodes) { await postNewEpisodes(show) }
                for arrival in news.arrivals where Preferences.notifies(.watchlistArrivals) { await postArrival(arrival) }
            }
            ledger.noteAnnounced(news.announcedKeys)
            if let newest = news.newestAddedAt { ledger.noteChecked(upTo: newest) }
            return true
        } catch {
            MidgarLog.error("Arrivals check failed: \(error.localizedDescription)", category: .networking)
            return false
        }
    }

    private func postNewEpisodes(_ show: ShowNews) async {
        let content = UNMutableNotificationContent()
        content.title = NotificationCopy.newEpisodesTitle(show)
        content.body = NotificationCopy.newEpisodesBody(show)
        content.sound = .default
        content.threadIdentifier = "crucible.new.\(show.showRatingKey)"
        if show.episodes.count == 1, let episode = show.episodes.first {
            content.userInfo = ["kind": "media", "ratingKey": episode.id, "mediaType": "episode"]
        } else {
            content.userInfo = ["kind": "media", "ratingKey": show.showRatingKey, "mediaType": "show"]
        }
        if let attachment = await Self.posterAttachment(path: show.posterPath) { content.attachments = [attachment] }
        try? await center.add(UNNotificationRequest(identifier: "crucible.new.\(show.showRatingKey).\(show.episodes.map(\.id).joined(separator: "-"))", content: content, trigger: nil))
    }

    private func postArrival(_ arrival: WatchlistArrival) async {
        let content = UNMutableNotificationContent()
        content.title = NotificationCopy.arrivalTitle(arrival)
        content.body = NotificationCopy.arrivalBody
        content.sound = .default
        content.userInfo = ["kind": "media", "ratingKey": arrival.ratingKey, "mediaType": arrival.mediaType]
        if let attachment = await Self.posterAttachment(path: arrival.posterPath) { content.attachments = [attachment] }
        try? await center.add(UNNotificationRequest(identifier: "crucible.arrival.\(arrival.ratingKey)", content: content, trigger: nil))
    }

    // MARK: - Artwork

    /// A poster for the notification: the image loader's copy written to a file of its own, because the notification store
    /// takes ownership of the file it is given.
    private static func posterAttachment(path: String?) async -> UNNotificationAttachment? {
        guard let path, let image = await ImageLoader.shared.loadImage(path: path, width: 360),
              let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notification-\(UUID().uuidString).jpg")
        do {
            try data.write(to: file)
            return try UNNotificationAttachment(identifier: "poster", url: file)
        } catch {
            return nil
        }
    }
}

/// What a tap on a notification carries, read off the response before it leaves the notification center's thread.
struct NotificationTap: Sendable {
    let category: String
    let action: String
    let kind: String?
    let ratingKey: String?
    let mediaType: String?
    let title: String?

    init(_ response: UNNotificationResponse) {
        let content = response.notification.request.content
        category = content.categoryIdentifier
        action = response.actionIdentifier
        kind = content.userInfo["kind"] as? String
        ratingKey = content.userInfo["ratingKey"] as? String
        mediaType = content.userInfo["mediaType"] as? String
        title = content.userInfo["title"] as? String
    }
}
