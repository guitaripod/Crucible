import Foundation
import MidgarCore

/// New episodes of one show the viewer is watching.
package struct ShowNews: Sendable, Equatable {
    package let showRatingKey: String
    package let showTitle: String
    package let posterPath: String?
    package let episodes: [PlexMetadata]

    package static func == (lhs: ShowNews, rhs: ShowNews) -> Bool {
        lhs.showRatingKey == rhs.showRatingKey && lhs.episodes.map(\.id) == rhs.episodes.map(\.id)
    }
}

/// A title from the viewer's Plex watchlist that is now on their server.
package struct WatchlistArrival: Sendable, Equatable {
    package let ratingKey: String
    package let mediaType: String
    package let title: String
    package let posterPath: String?
}

/// What arrived on the server since the last check that is worth a notification.
package struct LibraryNews: Sendable, Equatable {
    package var shows: [ShowNews] = []
    package var arrivals: [WatchlistArrival] = []
    /// The newest `addedAt` seen, where the next check starts.
    package var newestAddedAt: Int?

    package var isEmpty: Bool { shows.isEmpty && arrivals.isEmpty }

    /// The keys the notification ledger remembers, so nothing is announced twice.
    package var announcedKeys: [String] {
        shows.flatMap { $0.episodes.map { LibraryNewsCheck.episodeKey($0.id) } } + arrivals.map { LibraryNewsCheck.arrivalKey($0.ratingKey) }
    }
}

/// Looks at what was added to the server since the last look: new episodes of the shows the viewer is following and titles
/// from their watchlist. Recently Added on Plex can list an episode, its season or its show; a season or a show is opened to
/// find the episodes that are new. Episodes already watched or announced are left out.
package struct LibraryNewsCheck: Sendable {
    package var fetchRecent: @Sendable () async throws -> [PlexMetadata]
    package var fetchChildren: @Sendable (String) async throws -> [PlexMetadata]
    package var fetchLeaves: @Sendable (String) async throws -> [PlexMetadata]
    package var fetchWatchlistGuids: @Sendable () async -> Set<String>?

    package static let recentWindow = 60
    package static let maxShows = 5
    package static let maxArrivals = 5

    package init(
        fetchRecent: @escaping @Sendable () async throws -> [PlexMetadata],
        fetchChildren: @escaping @Sendable (String) async throws -> [PlexMetadata],
        fetchLeaves: @escaping @Sendable (String) async throws -> [PlexMetadata],
        fetchWatchlistGuids: @escaping @Sendable () async -> Set<String>?
    ) {
        self.fetchRecent = fetchRecent
        self.fetchChildren = fetchChildren
        self.fetchLeaves = fetchLeaves
        self.fetchWatchlistGuids = fetchWatchlistGuids
    }

    package static func live(api: APIClient, includeWatchlist: Bool) -> LibraryNewsCheck {
        LibraryNewsCheck(
            fetchRecent: { try await api.requestContainer(.recentlyAdded(start: 0, size: recentWindow)).Metadata ?? [] },
            fetchChildren: { try await api.requestContainer(.children(ratingKey: $0)).Metadata ?? [] },
            fetchLeaves: { try await api.requestContainer(.folderPath("/library/metadata/\($0)/allLeaves")).Metadata ?? [] },
            fetchWatchlistGuids: {
                guard includeWatchlist, let items = try? await WatchlistService.items(token: api.token) else { return nil }
                return Set(items.compactMap(\.guid))
            }
        )
    }

    package static func episodeKey(_ ratingKey: String) -> String { "episode.\(ratingKey)" }
    package static func arrivalKey(_ ratingKey: String) -> String { "watchlist.\(ratingKey)" }

    /// Everything added after `since` (seconds since 1970) that `followed` shows and the watchlist make worth announcing,
    /// outside the `excluded` libraries. The check still moves past what those libraries received, so it is never announced
    /// later either.
    package func run(followed: Set<String>, since: Int, announced: Set<String>, excluding excluded: Set<Int> = []) async throws -> LibraryNews {
        let wasAnnounced: (String) -> Bool = { announced.contains($0) }
        let added = try await fetchRecent().filter { ($0.addedAt ?? 0) > since }
        var news = LibraryNews(newestAddedAt: added.compactMap(\.addedAt).max())
        let fresh = LibraryVisibility.shown(added, excluding: excluded)
        guard !fresh.isEmpty else { return news }
        news.shows = await showNews(in: fresh, followed: followed, since: since, wasAnnounced: wasAnnounced)
        let announcedShows = Set(news.shows.map(\.showRatingKey))
        if let guids = await fetchWatchlistGuids(), !guids.isEmpty {
            news.arrivals = arrivals(in: fresh, watchlist: guids, skipping: announcedShows, wasAnnounced: wasAnnounced)
        }
        return news
    }

    private func showNews(in fresh: [PlexMetadata], followed: Set<String>, since: Int, wasAnnounced: (String) -> Bool) async -> [ShowNews] {
        var episodesByShow = [String: [PlexMetadata]]()
        var order = [String]()
        for item in fresh {
            let show: String?
            let episodes: [PlexMetadata]
            switch item.mediaType {
            case "episode":
                show = item.grandparentRatingKey
                episodes = [item]
            case "season":
                show = item.parentRatingKey
                episodes = show.map(followed.contains) == true ? ((try? await fetchChildren(item.id)) ?? []) : []
            case "show":
                show = item.ratingKey
                episodes = show.map(followed.contains) == true ? ((try? await fetchLeaves(item.id)) ?? []) : []
            default:
                continue
            }
            guard let show, followed.contains(show) else { continue }
            let new = episodes.filter {
                $0.mediaType == "episode" && ($0.addedAt ?? 0) > since && !$0.isWatched && !wasAnnounced(Self.episodeKey($0.id))
            }
            guard !new.isEmpty else { continue }
            if episodesByShow[show] == nil { order.append(show) }
            episodesByShow[show, default: []].append(contentsOf: new)
        }
        return order.prefix(Self.maxShows).compactMap { show in
            var seen = Set<String>()
            let episodes = (episodesByShow[show] ?? [])
                .filter { seen.insert($0.id).inserted }
                .sorted { ($0.parentIndex ?? 0, $0.index ?? 0) < ($1.parentIndex ?? 0, $1.index ?? 0) }
            guard let first = episodes.first else { return nil }
            return ShowNews(
                showRatingKey: show,
                showTitle: first.grandparentTitle ?? first.title,
                posterPath: first.grandparentThumb ?? first.thumb,
                episodes: episodes
            )
        }
    }

    private func arrivals(in fresh: [PlexMetadata], watchlist: Set<String>, skipping shows: Set<String>, wasAnnounced: (String) -> Bool) -> [WatchlistArrival] {
        var found = [WatchlistArrival]()
        var seen = Set<String>()
        for item in fresh {
            let arrival: WatchlistArrival?
            switch item.mediaType {
            case "movie":
                arrival = item.guid.map(watchlist.contains) == true
                    ? WatchlistArrival(ratingKey: item.id, mediaType: "movie", title: item.title, posterPath: item.thumb) : nil
            case "show":
                arrival = item.guid.map(watchlist.contains) == true
                    ? WatchlistArrival(ratingKey: item.id, mediaType: "show", title: item.title, posterPath: item.thumb) : nil
            case "season":
                arrival = item.parentGuid.map(watchlist.contains) == true
                    ? item.parentRatingKey.map { WatchlistArrival(ratingKey: $0, mediaType: "show", title: item.parentTitle ?? item.title, posterPath: item.parentThumb ?? item.thumb) } : nil
            case "episode":
                arrival = item.grandparentGuid.map(watchlist.contains) == true
                    ? item.grandparentRatingKey.map { WatchlistArrival(ratingKey: $0, mediaType: "show", title: item.grandparentTitle ?? item.title, posterPath: item.grandparentThumb ?? item.thumb) } : nil
            default:
                arrival = nil
            }
            guard let arrival, !shows.contains(arrival.ratingKey), !wasAnnounced(Self.arrivalKey(arrival.ratingKey)),
                  seen.insert(arrival.ratingKey).inserted else { continue }
            found.append(arrival)
            if found.count == Self.maxArrivals { break }
        }
        return found
    }
}

/// The words of every notification the iPhone app sends.
package enum NotificationCopy {
    package static func ratingTitle(for ask: RatingAsk) -> String {
        RatingAskCopy.question(for: ask)
    }

    package static func ratingBody(for ask: RatingAsk) -> String {
        switch ask.reason {
        case .finishedMovie, .watchedEpisodes:
            return String(localized: "Tap to rate it, or press and hold for quick stars.", comment: "Body of a reminder to rate a title the viewer finished")
        case .finishedSeason(let season?):
            return String(localized: "You finished season \(season). Tap to rate the show, or press and hold for quick stars.", comment: "Body of a reminder to rate a show after finishing a season")
        case .finishedSeason(nil):
            return String(localized: "You finished a season. Tap to rate the show, or press and hold for quick stars.", comment: "Body of a reminder to rate a show after finishing a season of unknown number")
        case .caughtUp:
            return String(localized: "You’re all caught up. Tap to rate the show, or press and hold for quick stars.", comment: "Body of a reminder to rate a show the viewer caught up with")
        }
    }

    /// The one reminder for every title waiting to be rated: the question itself for one title, the titles by name for several.
    package static func ratingTitle(for asks: [RatingAsk]) -> String {
        asks.count == 1 ? ratingTitle(for: asks[0]) : RatingAskCopy.rowTitle
    }

    package static func ratingBody(for asks: [RatingAsk]) -> String {
        guard asks.count > 1 else { return asks.first.map(ratingBody(for:)) ?? "" }
        return String(
            localized: "\(ratingTitleList(asks)). Tap to rate them all in one place.",
            comment: "Body of the one reminder that gathers several titles to rate, e.g. Dune, Severance and 2 more. Tap to rate them all in one place."
        )
    }

    /// The titles by name, joined the way the interface language lists things; past three, the first two and how many more.
    static func ratingTitleList(_ asks: [RatingAsk]) -> String {
        let names = asks.map(\.title)
        let shown = names.count > 3
            ? Array(names.prefix(2)) + [String(localized: "\(names.count - 2) more", comment: "Last item of a list of titles in a notification, e.g. the end of Dune, Severance and 2 more")]
            : names
        let formatter = ListFormatter()
        formatter.locale = Formatters.interfaceLocale
        return formatter.string(from: shown) ?? shown.joined(separator: ", ")
    }

    package static func newEpisodesTitle(_ news: ShowNews) -> String {
        news.episodes.count == 1
            ? String(localized: "New Episode of \(news.showTitle)", comment: "Notification title when one new episode of a show arrived, e.g. New Episode of Severance")
            : String(localized: "\(news.episodes.count) New Episodes of \(news.showTitle)", comment: "Notification title when several new episodes of a show arrived, e.g. 3 New Episodes of Severance")
    }

    package static func newEpisodesBody(_ news: ShowNews) -> String {
        let lines = news.episodes.prefix(3).map { episode in
            [Formatters.episodeCode(episode.parentIndex, episode.index), episode.title].compactMap { $0 }.joined(separator: " · ")
        }
        let rest = news.episodes.count - lines.count
        guard rest > 0 else { return lines.joined(separator: "\n") }
        return (lines + [String(localized: "and \(rest) more", comment: "Last line of a new-episodes notification, e.g. and 2 more")]).joined(separator: "\n")
    }

    package static func arrivalTitle(_ arrival: WatchlistArrival) -> String {
        String(localized: "\(arrival.title) Is Here", comment: "Notification title when a watchlisted title arrived on the server, e.g. Dune Is Here")
    }

    package static let arrivalBody = String(localized: "From your watchlist, now on your server. Tap to watch.", comment: "Body of the notification for a watchlisted title that arrived on the server")

    package static let recapTitle = String(localized: "Your Week in Crucible", comment: "Title of the Sunday weekly recap notification")

    package static func recapBody(seconds: Int, deltaPercent: Int?) -> String {
        let time = Formatters.duration(Double(seconds))
        switch deltaPercent {
        case let delta? where delta >= 5:
            return String(localized: "\(time) of watching this week, \(delta)% more than last week.", comment: "Weekly recap body with a rise, e.g. 6h 20m of watching this week, 30% more than last week.")
        case let delta? where delta <= -5:
            return String(localized: "\(time) of watching this week, \(-delta)% less than last week.", comment: "Weekly recap body with a fall")
        default:
            return String(localized: "\(time) of watching this week. Tap for your statistics.", comment: "Weekly recap body without a comparison")
        }
    }

    package static func yearInReviewTitle(year: Int) -> String {
        String(localized: "Your \(String(year)) in Review", comment: "Title of the Year in Review notification, e.g. Your 2026 in Review")
    }

    package static let yearInReviewBody = String(localized: "Your year of watching is ready: top shows, streaks and the poster to share.", comment: "Body of the Year in Review notification")
}
