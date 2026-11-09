import Foundation
import MidgarCore

/// A Plex item as Trakt knows it: the kind and ids a scrobble, a rating or a play is sent with.
package struct TraktTarget: Codable, Equatable, Sendable {
    package let kind: TraktMediaKind
    package let ids: TraktIDs
    /// The show of an episode or of a season, and the season and episode numbers inside it.
    package let showIDs: TraktIDs?
    package let season: Int?
    package let number: Int?

    package init(kind: TraktMediaKind, ids: TraktIDs, showIDs: TraktIDs? = nil, season: Int? = nil, number: Int? = nil) {
        self.kind = kind
        self.ids = ids
        self.showIDs = showIDs
        self.season = season
        self.number = number
    }
}

/// What a lookup came to: the Trakt item, no Trakt item for any id the Plex item carries, or no answer yet because Plex or
/// Trakt could not be reached.
package enum TraktResolution: Equatable, Sendable {
    case found(TraktTarget)
    case unmatched
    case unknown

    package var target: TraktTarget? {
        if case .found(let target) = self { return target }
        return nil
    }
}

/// How a Plex item maps to Trakt: found, or not found by any id it carries.
package enum TraktMatch: Codable, Equatable, Sendable {
    case matched(TraktTarget)
    case unmatched(title: String, at: Date)
}

/// Finds the Trakt item for a Plex movie, show, season or episode by the outside ids Plex's agents matched it to, never by
/// title: a lookup is only accepted when Trakt answers with the same kind and the very id it was asked for. Episodes try
/// their own ids first and then the show's season and episode numbers. What cannot be matched is never sent to Trakt and
/// is listed for the viewer instead. Answers are kept per server and item.
@MainActor
package final class TraktResolver {
    package static let shared = TraktResolver()

    package struct Lookup: Sendable {
        package var search: @Sendable (TraktLookupID, TraktMediaKind) async throws -> [TraktSearchResult]
        package var episode: @Sendable (_ showID: Int, _ season: Int, _ number: Int) async throws -> TraktEpisode
        package var plexItem: @Sendable (_ ratingKey: String, _ api: APIClient) async throws -> PlexMetadata?

        package init(
            search: @escaping @Sendable (TraktLookupID, TraktMediaKind) async throws -> [TraktSearchResult],
            episode: @escaping @Sendable (Int, Int, Int) async throws -> TraktEpisode,
            plexItem: @escaping @Sendable (String, APIClient) async throws -> PlexMetadata?
        ) {
            self.search = search
            self.episode = episode
            self.plexItem = plexItem
        }

        package static let live = Lookup(
            search: { id, kind in try await TraktClient.shared.send(.lookup(id, kind: kind), as: [TraktSearchResult].self) },
            episode: { show, season, number in try await TraktClient.shared.send(.episode(showID: show, season: season, number: number), as: TraktEpisode.self) },
            plexItem: { ratingKey, api in try await api.requestContainer(.metadata(ratingKey: ratingKey)).Metadata?.first }
        )
    }

    /// An unmatched item is looked up again after this long, in case its Plex match was fixed.
    static let retryUnmatchedAfter: TimeInterval = 86_400

    private let lookup: Lookup
    private let storage: URL?
    private var writes = 0
    private var matches: [String: TraktMatch]
    private var inFlight: [String: Task<TraktResolution, Never>] = [:]

    package init(lookup: Lookup = .live, storage: URL? = TraktResolver.defaultStorage) {
        self.lookup = lookup
        self.storage = storage
        matches = storage.flatMap { try? JSONDecoder().decode([String: TraktMatch].self, from: Data(contentsOf: $0)) } ?? [:]
    }

    package static var defaultStorage: URL {
        AppPlatform.persistentDirectory.appendingPathComponent("trakt-matches.json")
    }

    private static func key(server: String, ratingKey: String) -> String { "\(server)/\(ratingKey)" }

    /// The Trakt item for `ratingKey` on `server`, from memory when known.
    package func resolve(ratingKey: String, server: String, api: APIClient, now: Date = Date()) async -> TraktResolution {
        let key = Self.key(server: server, ratingKey: ratingKey)
        switch matches[key] {
        case .matched(let target): return .found(target)
        case .unmatched(_, let at) where now.timeIntervalSince(at) < Self.retryUnmatchedAfter: return .unmatched
        default: break
        }
        if let running = inFlight[key] { return await running.value }
        let lookup = lookup
        let task = Task<TraktResolution, Never> { [weak self] in
            do {
                guard let item = try await lookup.plexItem(ratingKey, api) else { return .unknown }
                let found = try await Self.resolve(item, api: api, lookup: lookup)
                self?.remember(key, found.map(TraktMatch.matched) ?? .unmatched(title: Self.displayTitle(item), at: now))
                return found.map(TraktResolution.found) ?? .unmatched
            } catch {
                MidgarLog.notice("Trakt match for \(ratingKey) not resolved now: \(error.localizedDescription)", category: .trakt)
                return .unknown
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// The Trakt item for `ratingKey`, or nil when there is none or no answer yet.
    package func target(ratingKey: String, server: String, api: APIClient) async -> TraktTarget? {
        await resolve(ratingKey: ratingKey, server: server, api: api).target
    }

    /// Remembers the Trakt item the viewer picked for a title Crucible could not match.
    package func fix(ratingKey: String, server: String, as target: TraktTarget) {
        remember(Self.key(server: server, ratingKey: ratingKey), .matched(target))
    }

    /// The titles Crucible could not match, for Settings.
    package var unmatchedTitles: [String] {
        matches.values.compactMap { match in
            if case .unmatched(let title, _) = match { return title }
            return nil
        }.sorted()
    }

    package func forgetAll() {
        matches = [:]
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        guard let storage else { return }
        writes += 1
        let order = writes
        Task { await StateFileWriter.shared.remove(storage, order: order) }
    }

    private func remember(_ key: String, _ match: TraktMatch) {
        matches[key] = match
        guard let storage else { return }
        writes += 1
        let order = writes
        let snapshot = matches
        Task { await StateFileWriter.shared.write(snapshot, to: storage, order: order) }
    }

    private static func displayTitle(_ item: PlexMetadata) -> String {
        guard item.type == "episode", let show = item.grandparentTitle else { return item.title }
        return "\(show) · \(item.title)"
    }

    /// The outside ids of `item`: the agent ids Plex lists, else the ones a legacy agent's guid spells out.
    package nonisolated static func ids(of item: PlexMetadata) -> ExternalIDs {
        var ids = item.externalIDs
        guard ids.isEmpty, let guid = item.guid else { return ids }
        let legacy = LegacyGuid(guid)
        ids.imdb = legacy.imdb
        ids.tmdb = legacy.tmdb
        if item.type != "episode" { ids.tvdb = legacy.tvdb }
        return ids
    }

    private static func resolve(_ item: PlexMetadata, api: APIClient, lookup: Lookup) async throws -> TraktTarget? {
        switch item.type {
        case "movie":
            let ids = Self.ids(of: item)
            let candidates: [TraktLookupID] = [ids.imdb.map(TraktLookupID.imdb), ids.tmdb.map(TraktLookupID.tmdb)].compactMap { $0 }
            guard let found = try await first(candidates, kind: .movie, lookup: lookup) else { return nil }
            return TraktTarget(kind: .movie, ids: found)
        case "show":
            guard let show = try await showIDs(of: item, lookup: lookup) else { return nil }
            return TraktTarget(kind: .show, ids: show)
        case "season":
            guard let showKey = item.parentRatingKey, let showItem = try await lookup.plexItem(showKey, api),
                  let show = try await showIDs(of: showItem, lookup: lookup), let season = item.index else { return nil }
            return TraktTarget(kind: .show, ids: show, showIDs: show, season: season)
        case "episode":
            return try await resolveEpisode(item, api: api, lookup: lookup)
        default:
            return nil
        }
    }

    private static func resolveEpisode(_ item: PlexMetadata, api: APIClient, lookup: Lookup) async throws -> TraktTarget? {
        let ids = Self.ids(of: item)
        let own: [TraktLookupID] = [ids.tvdb.map(TraktLookupID.tvdb), ids.tmdb.map(TraktLookupID.tmdb), ids.imdb.map(TraktLookupID.imdb)].compactMap { $0 }
        var show: TraktIDs?
        if let showKey = item.grandparentRatingKey, let showItem = try await lookup.plexItem(showKey, api) {
            show = try await showIDs(of: showItem, lookup: lookup)
        }
        if let season = item.parentIndex, let number = item.index, let showID = show?.trakt {
            if let episode = try? await lookup.episode(showID, season, number) {
                let confirmed = own.isEmpty || own.contains { $0.matches(episode.ids) }
                if confirmed {
                    return TraktTarget(kind: .episode, ids: episode.ids, showIDs: show, season: season, number: number)
                }
            }
        }
        for id in own {
            let results = try await lookup.search(id, .episode)
            if let hit = results.first(where: { $0.type == "episode" && $0.episode.map { id.matches($0.ids) } == true }), let episode = hit.episode {
                return TraktTarget(
                    kind: .episode,
                    ids: episode.ids,
                    showIDs: hit.show?.ids ?? show,
                    season: episode.season ?? item.parentIndex,
                    number: episode.number ?? item.index
                )
            }
        }
        if own.isEmpty, let season = item.parentIndex, let number = item.index, let showID = show?.trakt,
           let episode = try? await lookup.episode(showID, season, number) {
            return TraktTarget(kind: .episode, ids: episode.ids, showIDs: show, season: season, number: number)
        }
        return nil
    }

    private static func showIDs(of item: PlexMetadata, lookup: Lookup) async throws -> TraktIDs? {
        let ids = Self.ids(of: item)
        let candidates: [TraktLookupID] = [ids.tvdb.map(TraktLookupID.tvdb), ids.tmdb.map(TraktLookupID.tmdb), ids.imdb.map(TraktLookupID.imdb)].compactMap { $0 }
        return try await first(candidates, kind: .show, lookup: lookup)
    }

    /// The first candidate Trakt answers with an item of the right kind carrying that same id.
    private static func first(_ candidates: [TraktLookupID], kind: TraktMediaKind, lookup: Lookup) async throws -> TraktIDs? {
        for id in candidates {
            let results = try await lookup.search(id, kind)
            for result in results where result.type == kind.rawValue {
                let ids: TraktIDs?
                switch kind {
                case .movie: ids = result.movie?.ids
                case .show: ids = result.show?.ids
                case .episode: ids = result.episode?.ids
                }
                if let ids, id.matches(ids), ids.trakt != nil { return ids }
            }
        }
        return nil
    }
}

/// The ids a legacy Plex agent writes into an item's guid, such as `com.plexapp.agents.imdb://tt0111161?lang=en` or
/// `com.plexapp.agents.thetvdb://81189/1/1?lang=en`.
struct LegacyGuid {
    var imdb: String?
    var tmdb: Int?
    var tvdb: Int?

    init(_ guid: String) {
        let parts = guid.components(separatedBy: "://")
        guard parts.count == 2 else { return }
        let agent = parts[0].lowercased()
        let value = parts[1].components(separatedBy: CharacterSet(charactersIn: "?/")).first ?? ""
        if agent.hasSuffix("imdb"), value.hasPrefix("tt") {
            imdb = value
        } else if agent.hasSuffix("themoviedb") || agent.hasSuffix("tmdb") {
            tmdb = Int(value)
        } else if agent.hasSuffix("thetvdb") || agent.hasSuffix("tvdb") {
            tvdb = Int(value)
        }
    }
}
