import Foundation
import MidgarCore

/// What came out lately for a show on the viewer's watchlist that their server does not have: a season that premiered, or
/// an episode that aired, in the last two weeks as Plex's catalogue dates them.
package struct WatchlistRelease: Codable, Hashable, Sendable, Identifiable {
    package let guid: String
    package let discoverKey: String
    package let title: String
    package let year: Int?
    package let posterPath: String?
    package let season: Int
    /// The newest episode out, by its number in the season.
    package let episode: Int
    /// How many episodes of the season aired in the window.
    package let episodeCount: Int
    /// The season's first episode is among them: the season itself is the news.
    package let premiered: Bool
    /// The newest episode's air date as the catalogue gives it, `yyyy-MM-dd`.
    package let airDate: String

    package var id: String { guid }

    package init(guid: String, discoverKey: String, title: String, year: Int?, posterPath: String?, season: Int, episode: Int, episodeCount: Int, premiered: Bool, airDate: String) {
        self.guid = guid
        self.discoverKey = discoverKey
        self.title = title
        self.year = year
        self.posterPath = posterPath
        self.season = season
        self.episode = episode
        self.episodeCount = episodeCount
        self.premiered = premiered
        self.airDate = airDate
    }

    package var news: EpisodeNews { premiered ? .newSeason : .newEpisode }

    /// The line under the poster: the season for a premiere, the newest episode otherwise, then how long ago it aired.
    package func caption(now: Date = Date(), calendar: Calendar = .current) -> String {
        let aired = AirDate.daysAgo(airDate, now: now, calendar: calendar).map(WatchlistReleaseCopy.aired(daysAgo:))
        guard !premiered else {
            return HomeFormat.joined([String(localized: "Season \(season)"), aired]) ?? String(localized: "Season \(season)")
        }
        return HomeFormat.episodeLine(season: season, episode: episode, tail: aired)
    }

    /// The show as a Plex-shaped watchlist entry, for the screens that request titles or take them off the watchlist.
    package var asMetadata: PlexMetadata {
        PlexMetadata(
            ratingKey: discoverKey, key: "/library/metadata/\(discoverKey)", type: "show", title: title,
            grandparentTitle: nil, grandparentRatingKey: nil, grandparentThumb: nil, grandparentArt: nil, parentTitle: nil,
            parentRatingKey: nil, parentThumb: nil, parentIndex: nil, index: nil, year: year, summary: nil, tagline: nil,
            contentRating: nil, studio: nil, rating: nil, audienceRating: nil, duration: nil, viewOffset: nil, viewCount: nil,
            lastViewedAt: nil, viewedAt: nil, accountID: nil, deviceID: nil, addedAt: nil, originallyAvailableAt: nil, thumb: posterPath,
            art: nil, leafCount: nil, viewedLeafCount: nil, childCount: nil, librarySectionID: nil, librarySectionTitle: nil,
            Genre: nil, Role: nil, Director: nil, Writer: nil, Media: nil, Marker: nil, Related: nil,
            guid: guid
        )
    }
}

/// Air dates as Plex gives them: a Gregorian day, `yyyy-MM-dd`, with no time or zone, read as that day where the viewer is,
/// whatever calendar their device shows dates in.
package enum AirDate {
    /// Whole days from the air date to today: 0 for today, negative for a day still to come, nil for text that is no date.
    package static func daysAgo(_ text: String, now: Date, calendar: Calendar) -> Int? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let day = gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return gregorian.dateComponents([.day], from: day, to: gregorian.startOfDay(for: now)).day
    }

    /// Whether a release that aired on `text` is still news on `now`.
    package static func isRecent(_ text: String, now: Date, calendar: Calendar = .current) -> Bool {
        guard let days = daysAgo(text, now: now, calendar: calendar) else { return false }
        return days < WatchlistReleaseCheck.windowDays
    }
}

/// Looks through the shows on the viewer's watchlist for new seasons and episodes their server does not have. Plex's
/// catalogue lists a show's seasons and each season's episodes with their air dates; the newest season that has aired
/// anything is the one that counts, so a season announced without episodes falls back to the one before it. Only a show with
/// something out decides whether the server has it, so the server is asked about a few titles, not the whole watchlist.
package struct WatchlistReleaseCheck: Sendable {
    package var fetchChildren: @Sendable (String) async throws -> [PlexMetadata]
    package var isOnServer: @Sendable (PlexMetadata) async throws -> Bool

    /// Days an episode stays news after it aired.
    package static let windowDays = 14
    /// Seasons looked at from the newest down, for a newest one that has not aired yet.
    package static let seasonsToLook = 2
    /// A season the catalogue dates as begun longer ago than this has stopped airing, so its episodes are not fetched.
    package static let finishedSeasonDays = 400
    /// The most shows one look goes through, newest on the watchlist first.
    package static let maxShows = 100
    package static let parallelShows = 4
    /// Pages of children read for one show or season, enough for a season of 1,500 episodes.
    static let maxPages = 5

    package init(
        fetchChildren: @escaping @Sendable (String) async throws -> [PlexMetadata],
        isOnServer: @escaping @Sendable (PlexMetadata) async throws -> Bool
    ) {
        self.fetchChildren = fetchChildren
        self.isOnServer = isOnServer
    }

    package static func live(api: APIClient) -> WatchlistReleaseCheck {
        WatchlistReleaseCheck(
            fetchChildren: { key in
                let token = ServerBootstrap.plexTVToken ?? api.token
                var children = [PlexMetadata]()
                for _ in 0..<Self.maxPages {
                    let response: PlexResponse = try await APIClient.plexTVRequest(.catalogChildren(key: key, start: children.count), token: token)
                    let page = response.MediaContainer.Metadata ?? []
                    children += page
                    let total = response.MediaContainer.totalSize ?? children.count
                    guard !page.isEmpty, children.count < total else { break }
                }
                return children
            },
            isOnServer: { try await WatchlistService.localMatch(for: $0, api: api) != nil }
        )
    }

    /// What one look found: the releases, newest first, and the shows it could not ask about.
    package struct Outcome: Sendable {
        package var releases: [WatchlistRelease]
        /// Guids of shows the catalogue or the server could not answer for, whose earlier release, if any, still stands.
        package var unknown: Set<String>
    }

    /// The releases of `watchlist`'s shows, newest first. A show the catalogue or the server cannot be asked about is left
    /// out rather than guessed at.
    package func run(watchlist: [PlexMetadata], now: Date, calendar: Calendar = .current) async -> [WatchlistRelease] {
        await look(watchlist: watchlist, now: now, calendar: calendar).releases
    }

    package func look(watchlist: [PlexMetadata], now: Date, calendar: Calendar = .current) async -> Outcome {
        var seen = Set<String>()
        let listed = watchlist.filter { $0.mediaType == "show" && $0.guid.map { seen.insert($0).inserted } == true }
        let shows = Array(listed.prefix(Self.maxShows))
        if listed.count > shows.count {
            MidgarLog.notice("Watchlist releases: looked at the newest \(shows.count) of \(listed.count) shows", category: .networking)
        }
        var found = [WatchlistRelease]()
        var unknown = Set<String>()
        var start = 0
        while start < shows.count, !Task.isCancelled {
            let batch = shows[start..<min(start + Self.parallelShows, shows.count)]
            start += Self.parallelShows
            await withTaskGroup(of: (guid: String, release: WatchlistRelease?, failed: Bool).self) { group in
                for show in batch {
                    group.addTask {
                        do {
                            return (show.guid ?? "", try await release(for: show, now: now, calendar: calendar), false)
                        } catch {
                            MidgarLog.notice("Watchlist releases: could not look at \(show.guid ?? show.title): \(error.localizedDescription)", category: .networking)
                            return (show.guid ?? "", nil, true)
                        }
                    }
                }
                for await answer in group {
                    if let release = answer.release { found.append(release) }
                    if answer.failed { unknown.insert(answer.guid) }
                }
            }
        }
        return Outcome(releases: Self.sorted(found, order: shows.compactMap(\.guid), now: now, calendar: calendar), unknown: unknown)
    }

    /// Newest air date first, then in the watchlist's own order.
    static func sorted(_ releases: [WatchlistRelease], order: [String], now: Date, calendar: Calendar) -> [WatchlistRelease] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return releases.sorted {
            let left = AirDate.daysAgo($0.airDate, now: now, calendar: calendar) ?? .max
            let right = AirDate.daysAgo($1.airDate, now: now, calendar: calendar) ?? .max
            return left != right ? left < right : (position[$0.guid] ?? .max) < (position[$1.guid] ?? .max)
        }
    }

    func release(for show: PlexMetadata, now: Date, calendar: Calendar) async throws -> WatchlistRelease? {
        guard let guid = show.guid, let key = WatchlistService.discoverKey(fromGuid: guid) else { return nil }
        let seasons = try await fetchChildren(key)
            .filter { $0.mediaType == "season" && ($0.index ?? 0) > 0 }
            .sorted { ($0.index ?? 0) > ($1.index ?? 0) }
        for season in seasons.prefix(Self.seasonsToLook) {
            guard let number = season.index else { continue }
            if let premiere = season.originallyAvailableAt.flatMap({ AirDate.daysAgo($0, now: now, calendar: calendar) }) {
                if premiere < 0 { continue }
                if premiere > Self.finishedSeasonDays { return nil }
            }
            let aired = try await fetchChildren(season.id).compactMap { episode -> (episode: Int, daysAgo: Int, date: String)? in
                guard episode.mediaType == "episode", let index = episode.index, let date = episode.originallyAvailableAt,
                      let days = AirDate.daysAgo(date, now: now, calendar: calendar), days >= 0 else { return nil }
                return (index, days, date)
            }
            guard !aired.isEmpty else { continue }
            let recent = aired.filter { $0.daysAgo < Self.windowDays }
            guard let newest = recent.max(by: { ($0.episode, -$0.daysAgo) < ($1.episode, -$1.daysAgo) }) else { return nil }
            guard try await !isOnServer(show) else { return nil }
            return WatchlistRelease(
                guid: guid, discoverKey: key, title: show.title, year: show.year, posterPath: show.thumb,
                season: number, episode: newest.episode, episodeCount: recent.count,
                premiered: recent.contains { $0.episode == 1 }, airDate: newest.date
            )
        }
        return nil
    }
}

/// What the latest look found, for whoever is watching on this server: kept across launches so Home shows it at once, and
/// looked again once it is six hours old, when the watchlist changes, or when the viewer pulls to refresh.
@MainActor
package final class WatchlistReleases {
    package static let shared = WatchlistReleases(defaults: .standard)

    package static let storageKey = "watchlistReleases.v1"
    package static let freshness: TimeInterval = 6 * 3_600

    private struct State: Codable {
        var owner: String
        var checkedAt: Date
        var releases: [WatchlistRelease]
    }

    private let defaults: UserDefaults
    private var state: State?
    private var running: (owner: String, task: Task<Void, Never>)?
    private var observers = [UUID: @MainActor () -> Void]()
    nonisolated(unsafe) private var watchlistObserver: (any NSObjectProtocol)?

    private let center: NotificationCenter
    private let currentOwner: @MainActor () -> String?
    /// What the watchlist lost and whether it changed at all while a look was under way, which that look's answer predates.
    private var removedWhileLooking = Set<String>()
    private var changedWhileLooking = false

    package init(defaults: UserDefaults, center: NotificationCenter = .default, owner: @escaping @MainActor () -> String? = { WatchlistReleases.currentOwner }) {
        self.defaults = defaults
        self.center = center
        currentOwner = owner
        if let data = defaults.data(forKey: Self.storageKey) {
            state = try? JSONDecoder().decode(State.self, from: data)
        }
        watchlistObserver = center.addObserver(forName: .watchlistChanged, object: nil, queue: nil) { [weak self] note in
            let guid = note.userInfo?[WatchlistService.changedGuidKey] as? String
            let added = note.userInfo?[WatchlistService.changedAddedKey] as? Bool ?? true
            MainActor.assumeIsolated { self?.watchlistChanged(guid: guid, added: added) }
        }
    }

    deinit {
        if let watchlistObserver { center.removeObserver(watchlistObserver) }
    }

    /// Whoever's watchlist the releases belong to: the server and the Home profile watching it.
    package static var currentOwner: String? {
        guard let server = ServerBootstrap.savedMachineIdentifier else { return nil }
        return server + "|" + (HomeProfiles.active?.id ?? "account")
    }

    /// The releases found for `owner` that are still news on `now`, newest first; none for anyone else. A look that could not
    /// be made leaves the last one standing, so what aired too long ago is dropped here as well.
    package func releases(for owner: String? = WatchlistReleases.currentOwner, now: Date = Date()) -> [WatchlistRelease] {
        guard let owner, let state, state.owner == owner else { return [] }
        return state.releases.filter { AirDate.isRecent($0.airDate, now: now) }
    }

    package func release(guid: String?, owner: String? = WatchlistReleases.currentOwner, now: Date = Date()) -> WatchlistRelease? {
        guard let guid else { return nil }
        return releases(for: owner, now: now).first { $0.guid == guid }
    }

    /// Looks again when the last look is stale or `force` asks for it. `watchlist` saves fetching the watchlist when the
    /// caller has just loaded it; a look already under way for the same viewer is waited for instead of repeated.
    package func refresh(api: APIClient, watchlist: [PlexMetadata]? = nil, force: Bool = false, now: Date = Date()) async {
        guard let owner = Self.currentOwner else { return }
        let token = api.token
        await refresh(
            owner: owner,
            check: .live(api: api),
            loadWatchlist: {
                if let watchlist { return watchlist }
                return try await WatchlistService.items(token: token)
            },
            force: force,
            now: now
        )
    }

    package func refresh(
        owner: String,
        check: WatchlistReleaseCheck,
        loadWatchlist: @escaping @Sendable () async throws -> [PlexMetadata],
        force: Bool,
        now: Date
    ) async {
        if let running, running.owner != owner {
            running.task.cancel()
            self.running = nil
        }
        if let running {
            await running.task.value
            if !force { return }
        }
        if !force, let state, state.owner == owner, now.timeIntervalSince(state.checkedAt) < Self.freshness, now >= state.checkedAt { return }
        removedWhileLooking = []
        changedWhileLooking = false
        let task = Task { @MainActor [weak self] in
            do {
                let watchlist = try await loadWatchlist()
                let outcome = await check.look(watchlist: watchlist, now: now)
                guard !Task.isCancelled, let self else { return }
                MidgarLog.info("Watchlist releases: \(outcome.releases.count) of \(watchlist.filter { $0.mediaType == "show" }.count) shows, \(outcome.unknown.count) unanswered", category: .networking)
                adopt(look: outcome, watchlist: watchlist, owner: owner, now: now)
            } catch {
                MidgarLog.notice("Watchlist releases: watchlist unavailable: \(error.localizedDescription)", category: .networking)
            }
        }
        running = (owner, task)
        await task.value
        if running?.task == task { running = nil }
    }

    /// The server has these now (Home's rows list them), so a release of the same show is no longer news.
    package func noteOnServer(_ items: [PlexMetadata], owner: String? = WatchlistReleases.currentOwner) {
        guard let owner, var changed = state, changed.owner == owner, !changed.releases.isEmpty else { return }
        let arrived = Set(items.flatMap { [$0.guid, $0.parentGuid, $0.grandparentGuid].compactMap { $0 } })
        changed.releases.removeAll { arrived.contains($0.guid) }
        guard changed.releases.count != state?.releases.count else { return }
        adopt(changed)
    }

    /// A look's answer: a show it could not ask about keeps the release the last look found, a title taken off the watchlist
    /// while it ran stays off, and any change to the watchlist meanwhile leaves the answer stale so the next refresh looks again.
    private func adopt(look outcome: WatchlistReleaseCheck.Outcome, watchlist: [PlexMetadata], owner: String, now: Date) {
        let previous = state?.owner == owner ? state?.releases ?? [] : []
        let found = Set(outcome.releases.map(\.guid))
        let kept = previous.filter { outcome.unknown.contains($0.guid) && !found.contains($0.guid) }
        let releases = WatchlistReleaseCheck.sorted(
            (outcome.releases + kept).filter { !removedWhileLooking.contains($0.guid) },
            order: watchlist.compactMap(\.guid), now: now, calendar: .current
        )
        adopt(State(owner: owner, checkedAt: changedWhileLooking ? .distantPast : now, releases: releases))
    }

    /// A title came off the watchlist of whoever is watching: its release goes now. Anything else the watchlist gained is looked
    /// at on the next refresh.
    private func watchlistChanged(guid: String?, added: Bool) {
        guard let owner = currentOwner() else { return }
        if running?.owner == owner {
            changedWhileLooking = true
            if !added, let guid { removedWhileLooking.insert(guid) }
        }
        guard var changed = state, changed.owner == owner else { return }
        if !added, let guid { changed.releases.removeAll { $0.guid == guid } }
        changed.checkedAt = .distantPast
        adopt(changed)
    }

    package func reset() {
        running?.task.cancel()
        running = nil
        state = nil
        defaults.removeObject(forKey: Self.storageKey)
        notify()
    }

    @discardableResult
    package func addObserver(_ handler: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    package func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func adopt(_ new: State) {
        let changed = new.releases != state?.releases || new.owner != state?.owner
        state = new
        if let data = try? JSONEncoder().encode(new) { defaults.set(data, forKey: Self.storageKey) }
        if changed { notify() }
    }

    private func notify() {
        observers.values.forEach { $0() }
    }
}

/// The words around watchlist releases.
package enum WatchlistReleaseCopy {
    package static let rowTitle = String(localized: "Out Now on Your Watchlist", comment: "Title of the Home row of shows on the viewer's Plex watchlist that have a new season or episode out that their server does not have yet")
    package static let rowExplanation = String(localized: "New seasons and episodes of shows on your watchlist that your server doesn’t have yet.", comment: "Explanation of the Out Now on Your Watchlist row in Settings › Home Rows")

    /// How many shows on the watchlist have something new out, on the badge beside the Watchlist row, e.g. 2 New.
    package static func newCount(_ count: Int) -> String {
        String(localized: "\(count) New", comment: "Badge beside the Watchlist row: how many shows on the watchlist have a new season or episode out, e.g. 2 New")
    }

    /// When an episode aired, short enough for the line under a poster: "Today", "Yesterday", "5 days ago".
    package static func aired(daysAgo: Int) -> String {
        let now = Date()
        let aired = Calendar.current.date(byAdding: .day, value: -max(0, daysAgo), to: now) ?? now
        return PortableFormat.relative(aired, to: now, width: .full, named: true, beginningOfSentence: true, locale: Formatters.interfaceLocale)
    }

    /// The line a watchlist card shows: what came out while nobody has asked Seerr for it, otherwise where the request stands.
    package static func cardSubtitle(release: WatchlistRelease?, seerr: SeerrAvailability?, seerrLabel: String?, fallback: String?, now: Date = Date()) -> String? {
        if let release, seerr == nil || seerr == .notRequested { return release.caption(now: now) }
        return seerrLabel ?? fallback
    }
}

/// Keeps a watchlist screen's cards in step with the releases for as long as the screen holds it.
@MainActor
package final class WatchlistReleaseWatcher {
    private var token: UUID?
    private var items: [PlexMetadata] = []
    /// Hears the entry ids of the loaded shows whenever the releases change.
    package var changed: (@MainActor ([String]) -> Void)?

    package init() {
        token = WatchlistReleases.shared.addObserver { [weak self] in
            guard let self else { return }
            changed?(items.filter { $0.mediaType == "show" }.map(\.entryID))
        }
    }

    deinit {
        if let token {
            Task { @MainActor in WatchlistReleases.shared.removeObserver(token) }
        }
    }

    /// The watchlist just loaded: its cards are the ones to refresh, and it is looked through for releases when the last
    /// look is stale.
    package func loaded(_ items: [PlexMetadata], api: APIClient) {
        self.items = items
        Task { await WatchlistReleases.shared.refresh(api: api, watchlist: items) }
    }

    /// Badge and line for a watchlist card, given where Seerr says the title stands.
    package func card(for item: PlexMetadata, seerr: SeerrTitleState?, seerrLabel: String?, fallback: String?) -> (subtitle: String?, badge: String?) {
        let release = WatchlistReleases.shared.release(guid: item.guid)
        let subtitle = WatchlistReleaseCopy.cardSubtitle(release: release, seerr: seerr?.availability, seerrLabel: seerrLabel, fallback: fallback)
        return (subtitle, release?.news.badge)
    }
}
