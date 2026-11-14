import Foundation
import MidgarCore

/// A show the viewer has watched to the end of what the server has, whose next episode has aired but is not on it: the
/// card Up Next ends with, dimmed, until the server gets the episode.
package struct MissingNext: Codable, Hashable, Sendable, Identifiable {
    package let showRatingKey: String
    package let showTitle: String
    package let showGuid: String?
    package let posterPath: String?
    package let artPath: String?
    package let season: Int
    package let episode: Int
    package let title: String?
    package let airDate: String?
    /// The server's key for the season the episode belongs to when the server has that season, so the show opens on it.
    package let seasonRatingKey: String?

    package init(
        showRatingKey: String, showTitle: String, showGuid: String?, posterPath: String?, artPath: String?,
        season: Int, episode: Int, title: String?, airDate: String?, seasonRatingKey: String?
    ) {
        self.showRatingKey = showRatingKey
        self.showTitle = showTitle
        self.showGuid = showGuid
        self.posterPath = posterPath
        self.artPath = artPath
        self.season = season
        self.episode = episode
        self.title = title
        self.airDate = airDate
        self.seasonRatingKey = seasonRatingKey
    }

    package var id: String { "missingNext.\(showRatingKey)" }

    /// "S3 · E5 · Not on your server".
    package var caption: String {
        HomeFormat.episodeLine(season: season, episode: episode, tail: ShowGapsCopy.notOnServer)
    }

    /// The season the show page opens on: the server's when it has it, else the one it lacks.
    package var initialSeasonKey: String {
        seasonRatingKey ?? MissingSeason.id(season)
    }

    /// The show as a Plex-shaped title, for the request sheet.
    package var showMetadata: PlexMetadata {
        PlexMetadata(
            ratingKey: showRatingKey, key: "/library/metadata/\(showRatingKey)", type: "show", title: showTitle,
            grandparentTitle: nil, grandparentRatingKey: nil, grandparentThumb: nil, grandparentArt: nil, parentTitle: nil,
            parentRatingKey: nil, parentThumb: nil, parentIndex: nil, index: nil, year: nil, summary: nil, tagline: nil,
            contentRating: nil, studio: nil, rating: nil, audienceRating: nil, duration: nil, viewOffset: nil, viewCount: nil,
            lastViewedAt: nil, viewedAt: nil, accountID: nil, deviceID: nil, addedAt: nil, originallyAvailableAt: nil, thumb: posterPath,
            art: artPath, leafCount: nil, viewedLeafCount: nil, childCount: nil, librarySectionID: nil, librarySectionTitle: nil,
            Genre: nil, Role: nil, Director: nil, Writer: nil, Media: nil, Marker: nil, Related: nil,
            guid: showGuid
        )
    }
}

/// Finds the next aired episode the server lacks for shows the viewer is caught up on. The server's own episodes say where
/// the viewer is (its newest episode watched means caught up); Plex's catalogue says what aired after it, looking at that
/// season and the next one only.
package struct MissingNextCheck: Sendable {
    package var fetchLeaves: @Sendable (String) async throws -> [PlexMetadata]
    package var fetchChildren: @Sendable (String) async throws -> [PlexMetadata]
    /// The show itself, for its Plex guid when its episodes do not carry it.
    package var fetchShow: @Sendable (String) async throws -> PlexMetadata?

    /// The most shows one look goes through, most recently watched first.
    package static let maxShows = 12

    package init(
        fetchLeaves: @escaping @Sendable (String) async throws -> [PlexMetadata],
        fetchChildren: @escaping @Sendable (String) async throws -> [PlexMetadata],
        fetchShow: @escaping @Sendable (String) async throws -> PlexMetadata? = { _ in nil }
    ) {
        self.fetchLeaves = fetchLeaves
        self.fetchChildren = fetchChildren
        self.fetchShow = fetchShow
    }

    package static func live(api: APIClient) -> MissingNextCheck {
        MissingNextCheck(
            fetchLeaves: { try await api.requestContainer(.folderPath("/library/metadata/\($0)/allLeaves")).Metadata ?? [] },
            fetchChildren: WatchlistReleaseCheck.live(api: api).fetchChildren,
            fetchShow: { try await api.requestContainer(.metadata(ratingKey: $0)).Metadata?.first }
        )
    }

    /// What `shows` (server rating keys) are missing next, and the shows that could not be asked about.
    package func run(shows: [String], now: Date, calendar: Calendar = .current) async -> (found: [MissingNext], unknown: Set<String>) {
        var found = [MissingNext]()
        var unknown = Set<String>()
        await withTaskGroup(of: (key: String, next: MissingNext?, failed: Bool).self) { group in
            for key in shows.prefix(Self.maxShows) {
                group.addTask {
                    do {
                        return (key, try await next(for: key, now: now, calendar: calendar), false)
                    } catch {
                        MidgarLog.notice("Missing next: could not look at show \(key): \(error.localizedDescription)", category: .networking)
                        return (key, nil, true)
                    }
                }
            }
            for await answer in group {
                if let next = answer.next { found.append(next) }
                if answer.failed { unknown.insert(answer.key) }
            }
        }
        let order = Dictionary(shows.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return (found.sorted { (order[$0.showRatingKey] ?? .max) < (order[$1.showRatingKey] ?? .max) }, unknown)
    }

    func next(for showKey: String, now: Date, calendar: Calendar) async throws -> MissingNext? {
        let leaves = try await fetchLeaves(showKey).filter { $0.mediaType == "episode" && ($0.parentIndex ?? 0) > 0 && $0.index != nil }
        guard let newest = leaves.max(by: { ($0.parentIndex ?? 0, $0.index ?? 0) < ($1.parentIndex ?? 0, $1.index ?? 0) }),
              newest.isWatched, let lastSeason = newest.parentIndex, let lastEpisode = newest.index else { return nil }
        let showGuid: String?
        if let carried = newest.grandparentGuid {
            showGuid = carried
        } else {
            showGuid = try await fetchShow(showKey)?.guid
        }
        guard let guid = showGuid, let key = WatchlistService.discoverKey(fromGuid: guid) else { return nil }
        let seasons = try await fetchChildren(key)
            .filter { $0.mediaType == "season" && ($0.index ?? 0) >= lastSeason }
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        guard let current = seasons.first(where: { $0.index == lastSeason }) else { return nil }
        let currentChildren = try await fetchChildren(current.id)
        guard currentChildren.contains(where: { $0.mediaType == "episode" && $0.index == lastEpisode }) else {
            MidgarLog.notice("Missing next: \(guid) is numbered differently on the server", category: .networking)
            return nil
        }
        let found: (season: Int, episode: MissingEpisode)
        if let next = MissingEpisode.aired(currentChildren, season: lastSeason, now: now, calendar: calendar).first(where: { $0.episode > lastEpisode }) {
            found = (lastSeason, next)
        } else {
            guard let following = seasons.first(where: { ($0.index ?? 0) > lastSeason }), let number = following.index else { return nil }
            if let premiere = following.originallyAvailableAt.flatMap({ AirDate.daysAgo($0, now: now, calendar: calendar) }), premiere < 0 { return nil }
            guard let first = MissingEpisode.aired(try await fetchChildren(following.id), season: number, now: now, calendar: calendar).first else { return nil }
            found = (number, first)
        }
        return MissingNext(
            showRatingKey: showKey, showTitle: newest.grandparentTitle ?? newest.title, showGuid: guid,
            posterPath: newest.grandparentThumb, artPath: newest.grandparentArt,
            season: found.season, episode: found.episode.episode, title: found.episode.title, airDate: found.episode.airDate,
            seasonRatingKey: found.season == lastSeason ? newest.parentRatingKey : nil
        )
    }
}

/// What the looks at the shows the viewer is caught up on found, for whoever is watching on this server. Each show is looked
/// at again once its last look is six hours old, or on a pull to refresh, so a newly finished show is looked at on the next
/// Home load without the others; a show the server lists a next episode for again leaves at once.
@MainActor
package final class UpNextGaps {
    package static let shared = UpNextGaps(defaults: .standard)

    package static let storageKey = "upNextGaps.v2"
    package static let freshness: TimeInterval = 6 * 3_600

    private struct State: Codable {
        var owner: String
        var checked: [String: Date]
        var entries: [MissingNext]
    }

    private let defaults: UserDefaults
    private var state: State?
    private var running: (owner: String, task: Task<Void, Never>)?
    private var observers = [UUID: @MainActor () -> Void]()

    package init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            state = try? JSONDecoder().decode(State.self, from: data)
        }
    }

    /// The shows to look at: those the viewer finished an episode of lately that the server lists nothing next for
    /// (`nextUp`, its Continue Watching and On Deck).
    nonisolated package static func candidates(followed: [String], nextUp: [PlexMetadata]) -> [String] {
        let listed = shows(in: nextUp)
        var seen = Set<String>()
        return followed.filter { !listed.contains($0) && seen.insert($0).inserted }
    }

    /// The cards for `owner`, without a show the server lists something next for again (`nextUp`), such as the episode
    /// having arrived.
    package func entries(for owner: String? = WatchlistReleases.currentOwner, nextUp: [PlexMetadata] = []) -> [MissingNext] {
        guard let owner, let state, state.owner == owner else { return [] }
        let listed = Self.shows(in: nextUp)
        return state.entries.filter { !listed.contains($0.showRatingKey) }
    }

    /// The shows the episodes, seasons and shows of `items` belong to.
    nonisolated private static func shows(in items: [PlexMetadata]) -> Set<String> {
        Set(items.compactMap { item in
            switch item.mediaType {
            case "episode": item.grandparentRatingKey
            case "season": item.parentRatingKey
            case "show": item.ratingKey
            default: nil
            }
        })
    }

    package func refresh(api: APIClient, candidates: [String], force: Bool = false, now: Date = Date()) async {
        guard let owner = WatchlistReleases.currentOwner else { return }
        await refresh(owner: owner, check: .live(api: api), candidates: candidates, force: force, now: now)
    }

    package func refresh(owner: String, check: MissingNextCheck, candidates: [String], force: Bool, now: Date) async {
        if let running, running.owner != owner {
            running.task.cancel()
            self.running = nil
        }
        if let running { await running.task.value }
        let shows = Array(candidates.prefix(MissingNextCheck.maxShows))
        var current = state?.owner == owner ? state ?? State(owner: owner, checked: [:], entries: []) : State(owner: owner, checked: [:], entries: [])
        let wanted = Set(shows)
        current.checked = current.checked.filter { wanted.contains($0.key) }
        current.entries = current.entries.filter { wanted.contains($0.showRatingKey) }
        let due = shows.filter { show in
            guard !force, let checked = current.checked[show] else { return true }
            return now.timeIntervalSince(checked) >= Self.freshness || now < checked
        }
        guard !due.isEmpty else {
            adopt(current)
            return
        }
        let base = current
        let task = Task { @MainActor [weak self] in
            let (found, unknown) = await check.run(shows: due, now: now)
            guard !Task.isCancelled, let self else { return }
            var updated = base
            let looked = Set(due).subtracting(unknown)
            updated.entries = base.entries.filter { !looked.contains($0.showRatingKey) } + found
            for show in looked { updated.checked[show] = now }
            let order = Dictionary(shows.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            updated.entries.sort { (order[$0.showRatingKey] ?? .max) < (order[$1.showRatingKey] ?? .max) }
            MidgarLog.info("Missing next: looked at \(looked.count) of \(shows.count) shows, \(found.count) found, \(unknown.count) unanswered", category: .networking)
            adopt(updated)
        }
        running = (owner, task)
        await task.value
        if running?.task == task { running = nil }
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
        let changed = new.entries != state?.entries || new.owner != state?.owner
        guard changed || new.checked != state?.checked else { return }
        state = new
        if let data = try? JSONEncoder().encode(new) { defaults.set(data, forKey: Self.storageKey) }
        if changed { notify() }
    }

    private func notify() {
        observers.values.forEach { $0() }
    }
}
