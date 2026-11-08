import Foundation
import MidgarCore

/// Where a title stands between being asked for and playing, the one state every Request button and badge shows.
package enum SeerrAvailability: Hashable, Sendable {
    case notRequested
    case pending
    case approved
    case downloading(progress: Double?, eta: Date?)
    case partiallyAvailable
    case available
    case declined
    case failed
    case blocklisted

    /// From what Seerr knows of a title: a running download first, then its availability, then its latest request.
    package init(media: SeerrMediaInfo?) {
        guard let media else { self = .notRequested; return }
        if let downloads = media.downloadStatus, !downloads.isEmpty {
            self = .downloading(progress: Self.progress(of: downloads), eta: downloads.compactMap { $0.estimatedCompletionTime.flatMap(SeerrDate.parse) }.max())
            return
        }
        let latest = (media.requests ?? []).filter { $0.is4k != true }.max { $0.id < $1.id }?.requestStatus
        switch media.mediaStatus {
        case .available: self = .available
        case .partiallyAvailable: self = .partiallyAvailable
        case .processing: self = latest == .failed ? .failed : .approved
        case .pending: self = .pending
        case .blocklisted: self = .blocklisted
        case .unknown, .deleted:
            switch latest {
            case .pending: self = .pending
            case .approved: self = .approved
            case .declined: self = .declined
            case .failed: self = .failed
            case .completed, nil: self = .notRequested
            }
        }
    }

    /// How much of the downloads is done, from 0 to 1, when their sizes are known.
    static func progress(of downloads: [SeerrDownload]) -> Double? {
        let sized = downloads.filter { ($0.size ?? 0) > 0 }
        guard !sized.isEmpty else { return nil }
        let total = sized.reduce(0) { $0 + ($1.size ?? 0) }
        let left = sized.reduce(0) { $0 + min($1.size ?? 0, max(0, $1.sizeLeft ?? 0)) }
        return max(0, min(1, (total - left) / total))
    }

    /// On its way: asked for and not refused, not yet all there.
    package var isOnItsWay: Bool {
        switch self {
        case .pending, .approved, .downloading: return true
        default: return false
        }
    }
}

/// One season of a show and how much of it the server has or will have.
package struct SeerrSeasonState: Equatable, Sendable {
    package enum Status: Equatable, Sendable {
        case missing
        case requested
        case processing
        case partiallyAvailable
        case available
    }

    package let number: Int
    package let name: String?
    package let episodeCount: Int?
    package let status: Status

    package init(number: Int, name: String?, episodeCount: Int?, status: Status) {
        self.number = number
        self.name = name
        self.episodeCount = episodeCount
        self.status = status
    }
}

/// A movie or show as the Request sheet shows it: what it is, where it stands, and what the viewer may still ask for.
package struct SeerrTitleState: Equatable, Sendable {
    package let tmdbID: Int
    package let kind: SeerrMediaKind
    package let tvdbID: Int?
    package let title: String
    package let year: Int?
    package let overview: String?
    package let posterPath: String?
    package let availability: SeerrAvailability
    package let seasons: [SeerrSeasonState]
    /// The Plex rating key Seerr saw the title under once it arrived.
    package let ratingKey: String?
    /// The viewer's own request while it waits for approval, which they may still withdraw.
    package let ownPendingRequest: SeerrRequest?

    package init(details: SeerrTitleDetails, kind: SeerrMediaKind, viewerID: Int?) {
        tmdbID = details.id
        self.kind = kind
        tvdbID = details.externalIds?.tvdbId ?? details.mediaInfo?.tvdbId
        title = details.displayTitle
        year = details.year
        overview = details.overview
        posterPath = details.posterPath
        availability = SeerrAvailability(media: details.mediaInfo)
        ratingKey = details.mediaInfo?.ratingKey
        let requests = (details.mediaInfo?.requests ?? []).filter { $0.is4k != true }
        ownPendingRequest = viewerID.flatMap { id in requests.first { $0.requestedBy?.id == id && $0.requestStatus == .pending } }
        seasons = kind == .tv ? Self.seasons(details: details, requests: requests) : []
    }

    static func seasons(details: SeerrTitleDetails, requests: [SeerrRequest]) -> [SeerrSeasonState] {
        let known = Dictionary((details.mediaInfo?.seasons ?? []).map { ($0.seasonNumber, $0.status) }, uniquingKeysWith: { first, _ in first })
        let live = requests.filter { $0.requestStatus == .pending || $0.requestStatus == .approved }
        return (details.seasons ?? []).filter { $0.seasonNumber > 0 }.sorted { $0.seasonNumber < $1.seasonNumber }.map { season in
            let asked = live.filter { $0.seasons?.contains { $0.seasonNumber == season.seasonNumber } == true }
            let status: SeerrSeasonState.Status
            switch known[season.seasonNumber].flatMap({ $0 }).flatMap(SeerrMediaStatus.init(rawValue:)) {
            case .available: status = .available
            case .partiallyAvailable: status = .partiallyAvailable
            case .processing: status = .processing
            case .pending: status = .requested
            default:
                if asked.contains(where: { $0.requestStatus == .approved }) { status = .processing }
                else if !asked.isEmpty { status = .requested }
                else { status = .missing }
            }
            return SeerrSeasonState(number: season.seasonNumber, name: season.name, episodeCount: season.episodeCount, status: status)
        }
    }

    /// The seasons nobody has asked for that the server does not have.
    package var requestableSeasons: [Int] { seasons.filter { $0.status == .missing }.map(\.number) }

    /// Whether the viewer may ask for this title, or for more of it, now.
    package func canRequest(with permissions: SeerrPermissions) -> Bool {
        guard permissions.canRequest(kind) else { return false }
        switch kind {
        case .movie:
            return availability == .notRequested || availability == .declined
        case .tv:
            return availability != .blocklisted && !requestableSeasons.isEmpty
        }
    }
}

extension Notification.Name {
    /// Posted on the main thread when the viewer asked for a title, withdrew a request or approved or declined one.
    package static let seerrRequestsChanged = Notification.Name("crucible.seerrRequestsChanged")
}

/// Finds the Seerr title behind a Plex item and asks for it. Plex items carry TMDB ids; a title the server does not have
/// is looked up in Plex's own catalogue first.
@MainActor
package final class SeerrTitles {
    package static let shared = SeerrTitles()

    private let client: SeerrClient
    private let account: SeerrAccount
    private let catalog: @Sendable (String) async throws -> PlexMetadata?
    private var tmdbIDs: [String: Int] = [:]
    private var details: [String: (details: SeerrTitleDetails, at: Date)] = [:]
    static let lifetime: TimeInterval = 60

    package init(
        client: SeerrClient = .shared,
        account: SeerrAccount = .shared,
        catalog: @escaping @Sendable (String) async throws -> PlexMetadata? = SeerrTitles.catalogLookup
    ) {
        self.client = client
        self.account = account
        self.catalog = catalog
    }

    /// The entry Plex's catalogue keeps for the title with `key`, with its external ids.
    package static let catalogLookup: @Sendable (String) async throws -> PlexMetadata? = { key in
        let token = ServerBootstrap.plexTVToken
        let response: PlexResponse = try await APIClient.plexTVRequest(.catalogMetadata(key: key), token: token)
        return response.MediaContainer.Metadata?.first
    }

    /// The TMDB id and kind of `item`: from its own ids, from the server's full record of it when `api` is the server it is
    /// on, or from Plex's catalogue for a title no server has (pass no `api`).
    package func identify(_ item: PlexMetadata, api: APIClient?) async -> (tmdbID: Int, kind: SeerrMediaKind)? {
        guard let kind = SeerrMediaKind(plexType: item.mediaType), item.mediaType == "movie" || item.mediaType == "show" else { return nil }
        if let tmdb = item.externalIDs.tmdb { return (tmdb, kind) }
        guard let cacheKey = item.guid ?? item.ratingKey else { return nil }
        if let known = tmdbIDs[cacheKey] { return (known, kind) }
        let found: Int?
        if let api, let ratingKey = item.ratingKey {
            found = (try? await api.requestContainer(.metadata(ratingKey: ratingKey)))?.Metadata?.first?.externalIDs.tmdb
        } else if let key = item.guid.flatMap(WatchlistService.discoverKey(fromGuid:)) {
            found = (try? await catalog(key))?.externalIDs.tmdb
        } else {
            found = nil
        }
        guard let found else {
            MidgarLog.notice("Seerr: no TMDB id for \(item.mediaType) \(cacheKey)", category: .seerr)
            return nil
        }
        tmdbIDs[cacheKey] = found
        return (found, kind)
    }

    /// Where `item` stands in Seerr, or nil when Seerr is not connected or the title cannot be identified.
    package func state(for item: PlexMetadata, api: APIClient?, refresh: Bool = false) async throws -> SeerrTitleState? {
        guard account.isConnected, let (tmdbID, kind) = await identify(item, api: api) else { return nil }
        return try await state(tmdbID: tmdbID, kind: kind, refresh: refresh)
    }

    package func state(tmdbID: Int, kind: SeerrMediaKind, refresh: Bool = false, now: Date = Date()) async throws -> SeerrTitleState {
        let details = try await self.details(tmdbID: tmdbID, kind: kind, refresh: refresh, now: now)
        return SeerrTitleState(details: details, kind: kind, viewerID: account.connection?.user?.id)
    }

    package func details(tmdbID: Int, kind: SeerrMediaKind, refresh: Bool = false, now: Date = Date()) async throws -> SeerrTitleDetails {
        let key = "\(kind.rawValue)/\(tmdbID)"
        if !refresh, let cached = details[key], now.timeIntervalSince(cached.at) < Self.lifetime { return cached.details }
        let fetched = try await client.send(kind == .movie ? .movie(tmdbID: tmdbID) : .show(tmdbID: tmdbID), as: SeerrTitleDetails.self)
        details[key] = (fetched, now)
        return fetched
    }

    /// Where each of `items` stands, for titles from Plex's catalogue such as the watchlist, looked up four at a time; `update`
    /// hears each batch as it lands, keyed by the item's entry id, so a list fills in without waiting for the last title.
    package func states(for items: [PlexMetadata], update: @escaping @MainActor ([String: SeerrTitleState]) -> Void) async {
        guard account.isConnected else { return }
        let candidates = items.filter { $0.mediaType == "movie" || $0.mediaType == "show" }
        var start = 0
        while start < candidates.count, !Task.isCancelled {
            let chunk = candidates[start..<min(start + 4, candidates.count)]
            start += 4
            let lookups = chunk.map { item in (item.entryID, Task { try? await self.state(for: item, api: nil) }) }
            var batch: [String: SeerrTitleState] = [:]
            for (id, lookup) in lookups {
                if let state = await lookup.value { batch[id] = state }
            }
            if !batch.isEmpty, !Task.isCancelled { update(batch) }
        }
    }

    /// Asks for `state`'s title, or for `seasons` of a show (every missing one when nil), and returns where it stands now.
    package func request(_ state: SeerrTitleState, seasons: [Int]? = nil) async throws -> SeerrTitleState {
        let wanted: [Int]?
        if state.kind == .tv {
            let missing = state.requestableSeasons
            wanted = (seasons ?? missing).filter(missing.contains)
            guard wanted?.isEmpty == false else { throw SeerrError.nothingToRequest }
        } else {
            wanted = nil
        }
        let partial = account.connection?.partialRequests ?? true
        let asked = state.kind == .tv && (!partial || wanted?.count == state.seasons.count) ? nil : wanted
        try await client.sendVoid(.createRequest(kind: state.kind, tmdbID: state.tmdbID, tvdbID: state.tvdbID, seasons: asked))
        MidgarLog.notice("Seerr request sent for \(state.kind.rawValue) \(state.tmdbID) (\(asked.map { "\($0.count) seasons" } ?? "all"))", category: .seerr)
        NotificationCenter.default.post(name: .seerrRequestsChanged, object: nil)
        return try await self.state(tmdbID: state.tmdbID, kind: state.kind, refresh: true)
    }

    /// Movies and shows Seerr finds for `query` that the server does not have, best matches first, at most `limit`.
    package func search(_ query: String, limit: Int = 12) async -> [SeerrSearchHit] {
        guard account.isConnected else { return [] }
        do {
            let page = try await client.send(.search(query: query), as: SeerrPage<SeerrSearchResult>.self)
            return Array(page.results.compactMap(Self.hit).prefix(limit))
        } catch {
            MidgarLog.notice("Seerr search failed: \(error.localizedDescription)", category: .seerr)
            return []
        }
    }

    static func hit(_ result: SeerrSearchResult) -> SeerrSearchHit? {
        guard let kind = SeerrMediaKind(rawValue: result.mediaType), let title = result.title ?? result.name else { return nil }
        let availability = SeerrAvailability(media: result.mediaInfo)
        guard availability != .available, availability != .partiallyAvailable, availability != .blocklisted else { return nil }
        let date = result.releaseDate ?? result.firstAirDate
        return SeerrSearchHit(
            tmdbID: result.id, kind: kind, title: title, year: date.flatMap { $0.count >= 4 ? Int($0.prefix(4)) : nil },
            posterPath: result.posterPath, overview: result.overview, availability: availability
        )
    }

    /// Withdraws the viewer's own request while it still waits for approval.
    package func withdraw(_ request: SeerrRequest, of state: SeerrTitleState) async throws -> SeerrTitleState {
        try await client.sendVoid(.cancelRequest(id: request.id))
        MidgarLog.notice("Seerr request \(request.id) withdrawn", category: .seerr)
        NotificationCenter.default.post(name: .seerrRequestsChanged, object: nil)
        return try await self.state(tmdbID: state.tmdbID, kind: state.kind, refresh: true)
    }

    package func forgetAll() {
        tmdbIDs = [:]
        details = [:]
    }
}

/// Where each title of a list stands in Seerr, for a screen that shows it on its cards: filled in batches after the list
/// loads, a newer load replacing an older one.
@MainActor
package final class SeerrStateBook {
    package private(set) var states: [String: SeerrTitleState] = [:]
    private var task: Task<Void, Never>?
    private var items: [PlexMetadata] = []
    private var changed: (@MainActor ([String]) -> Void)?
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    package init() {
        observer = NotificationCenter.default.addObserver(forName: .seerrRequestsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let changed = self.changed else { return }
                self.load(self.items, changed: changed)
            }
        }
    }

    deinit {
        task?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The line a card shows under its title: where the title stands once Seerr has said, otherwise `fallback`.
    package func cardSubtitle(for item: PlexMetadata, fallback: String?) -> String? {
        guard let state = states[item.entryID] else { return fallback }
        return SeerrCopy.cardLabel(state.availability)
    }

    /// Looks `items` up when Seerr is connected and reports the entry ids whose cards changed.
    package func load(_ items: [PlexMetadata], changed: @escaping @MainActor ([String]) -> Void) {
        self.items = items
        self.changed = changed
        task?.cancel()
        guard SeerrAccount.shared.isConnected else {
            let had = Array(states.keys)
            states = [:]
            if !had.isEmpty { changed(had) }
            return
        }
        task = Task { [weak self] in
            await SeerrTitles.shared.states(for: items) { batch in
                guard let self else { return }
                let moved = batch.filter { self.states[$0.key] != $0.value }.map(\.key)
                self.states.merge(batch) { _, new in new }
                if !moved.isEmpty { changed(moved) }
            }
        }
    }
}
