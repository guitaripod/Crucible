import Foundation
import MidgarCore

/// An episode that has aired, as Plex's catalogue lists it, that the server does not have.
package struct MissingEpisode: Codable, Hashable, Sendable, Identifiable {
    package let season: Int
    package let episode: Int
    package let title: String
    package let airDate: String
    package let summary: String?
    package let thumb: String?

    package init(season: Int, episode: Int, title: String, airDate: String, summary: String? = nil, thumb: String? = nil) {
        self.season = season
        self.episode = episode
        self.title = title
        self.airDate = airDate
        self.summary = summary
        self.thumb = thumb
    }

    package var id: String { "missing.s\(season)e\(episode)" }

    /// The catalogue's aired episodes of one season, numbered and dated, oldest first.
    static func aired(_ children: [PlexMetadata], season: Int, now: Date, calendar: Calendar) -> [MissingEpisode] {
        children.compactMap { item -> MissingEpisode? in
            guard item.mediaType == "episode", let number = item.index, let date = item.originallyAvailableAt,
                  let days = AirDate.daysAgo(date, now: now, calendar: calendar), days >= 0 else { return nil }
            return MissingEpisode(season: item.parentIndex ?? season, episode: number, title: item.title, airDate: date, summary: item.summary, thumb: item.thumb)
        }
        .sorted { $0.episode < $1.episode }
    }
}

/// A season that has begun airing, as the catalogue lists it, that the server has none of.
package struct MissingSeason: Hashable, Sendable, Identifiable {
    package let index: Int
    package let title: String
    package let catalogueKey: String

    package init(index: Int, title: String, catalogueKey: String) {
        self.index = index
        self.title = title
        self.catalogueKey = catalogueKey
    }

    package var id: String { Self.id(index) }

    package static func id(_ index: Int) -> String { "missing.s\(index)" }

    package static func isMissing(_ key: String?) -> Bool { key?.hasPrefix("missing.") == true }

    /// The season number a missing season's id carries.
    package static func index(ofID key: String?) -> Int? {
        guard let key, key.hasPrefix("missing.s") else { return nil }
        return Int(key.dropFirst("missing.s".count))
    }
}

/// What a show on the server lacks of what has aired: whole seasons, and episodes of the seasons it has. Episodes of a
/// missing season are looked up only when that season is opened.
package struct ShowGaps: Equatable, Sendable {
    package var seasons: [MissingSeason] = []
    /// Aired episodes the server lacks, by season number; a missing season's appear once it has been opened.
    package var episodes: [Int: [MissingEpisode]] = [:]

    package static let none = ShowGaps()

    package init(seasons: [MissingSeason] = [], episodes: [Int: [MissingEpisode]] = [:]) {
        self.seasons = seasons
        self.episodes = episodes
    }

    package var isEmpty: Bool { seasons.isEmpty && episodes.values.allSatisfy(\.isEmpty) }

    package func season(id: String?) -> MissingSeason? {
        seasons.first { $0.id == id }
    }

    package func missing(inSeason index: Int?) -> [MissingEpisode] {
        index.flatMap { episodes[$0] } ?? []
    }

    /// These gaps with the episodes `older` had already fetched for a season that is still missing, since a new look lists a
    /// missing season without its episodes.
    package func keepingOpened(from older: ShowGaps) -> ShowGaps {
        var kept = self
        for season in seasons where kept.episodes[season.index] == nil && older.season(id: season.id) != nil {
            kept.episodes[season.index] = older.episodes[season.index]
        }
        return kept
    }
}

/// Compares a show on the server with Plex's catalogue. A season the server has is opened in the catalogue only when the
/// catalogue counts more episodes than the server has of it, so a complete show costs one request; a season numbered
/// differently on the server (an episode the catalogue does not list) is left alone rather than shown full of gaps.
package struct ShowGapsCheck: Sendable {
    package var fetchChildren: @Sendable (String) async throws -> [PlexMetadata]

    /// The most seasons of a show opened in one look, newest first.
    package static let maxSeasonLooks = 8

    package init(fetchChildren: @escaping @Sendable (String) async throws -> [PlexMetadata]) {
        self.fetchChildren = fetchChildren
    }

    package static func live(api: APIClient) -> ShowGapsCheck {
        ShowGapsCheck(fetchChildren: WatchlistReleaseCheck.live(api: api).fetchChildren)
    }

    /// The gaps between `serverEpisodes` (every episode of `show` on the server) and the catalogue. A show with no Plex
    /// guid, from a legacy or local agent, has no catalogue entry to compare and so no gaps.
    package func run(show: PlexMetadata, serverEpisodes: [PlexMetadata], now: Date, calendar: Calendar = .current) async throws -> ShowGaps {
        guard let guid = show.guid, let key = WatchlistService.discoverKey(fromGuid: guid) else { return .none }
        var owned = [Int: Set<Int>]()
        for episode in serverEpisodes where episode.mediaType == "episode" {
            guard let season = episode.parentIndex, let number = episode.index else { continue }
            owned[season, default: []].insert(number)
        }
        let seasons = try await fetchChildren(key)
            .filter { $0.mediaType == "season" && ($0.index ?? 0) > 0 }
            .sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        var gaps = ShowGaps()
        var looks = 0
        for season in seasons.reversed() {
            guard let number = season.index else { continue }
            let premiere = season.originallyAvailableAt.flatMap { AirDate.daysAgo($0, now: now, calendar: calendar) }
            if let premiere, premiere < 0 { continue }
            let have = owned[number] ?? []
            if have.isEmpty {
                if premiere != nil || season.id != seasons.last?.id {
                    gaps.seasons.append(MissingSeason(index: number, title: ShowDetailModel.seasonTitle(season), catalogueKey: season.id))
                } else if looks < Self.maxSeasonLooks {
                    looks += 1
                    let aired = MissingEpisode.aired(try await fetchChildren(season.id), season: number, now: now, calendar: calendar)
                    if !aired.isEmpty {
                        gaps.seasons.append(MissingSeason(index: number, title: ShowDetailModel.seasonTitle(season), catalogueKey: season.id))
                        gaps.episodes[number] = aired
                    }
                }
                continue
            }
            if let total = season.leafCount, total <= have.count { continue }
            guard looks < Self.maxSeasonLooks else { continue }
            looks += 1
            let children = try await fetchChildren(season.id)
            let listed = Set(children.compactMap { $0.mediaType == "episode" ? $0.index : nil })
            guard have.isSubset(of: listed) else {
                MidgarLog.notice("Show gaps: season \(number) of \(guid) is numbered differently on the server", category: .networking)
                continue
            }
            let missing = MissingEpisode.aired(children, season: number, now: now, calendar: calendar).filter { !have.contains($0.episode) }
            if !missing.isEmpty { gaps.episodes[number] = missing }
        }
        gaps.seasons.sort { $0.index < $1.index }
        return gaps
    }

    /// The aired episodes of a season the server lacks, for when it is opened.
    package func episodes(of season: MissingSeason, now: Date, calendar: Calendar = .current) async throws -> [MissingEpisode] {
        MissingEpisode.aired(try await fetchChildren(season.catalogueKey), season: season.index, now: now, calendar: calendar)
    }
}

/// The gaps of the shows opened lately, kept for an hour so moving between seasons or coming back to a show does not ask
/// the catalogue again; a change in what the server has of the show starts a new look.
@MainActor
package final class ShowGapsCenter {
    package static let shared = ShowGapsCenter()

    package static let lifetime: TimeInterval = 3_600
    private static let keep = 30

    private struct Entry {
        let signature: Int
        var gaps: ShowGaps
        let at: Date
    }

    private var entries: [String: Entry] = [:]

    /// The show's gaps, or nil when the catalogue could not be asked.
    package func gaps(show: PlexMetadata, serverEpisodes: [PlexMetadata], check: ShowGapsCheck, now: Date = Date()) async -> ShowGaps? {
        guard let guid = show.guid else { return ShowGaps.none }
        let signature = Self.signature(serverEpisodes)
        if let cached = entries[guid], cached.signature == signature, now.timeIntervalSince(cached.at) < Self.lifetime, now >= cached.at {
            return cached.gaps
        }
        do {
            var gaps = try await check.run(show: show, serverEpisodes: serverEpisodes, now: now)
            if let older = entries[guid]?.gaps { gaps = gaps.keepingOpened(from: older) }
            remember(guid, Entry(signature: signature, gaps: gaps, at: now))
            return gaps
        } catch {
            MidgarLog.notice("Show gaps: no answer for \(guid): \(error.localizedDescription)", category: .networking)
            return nil
        }
    }

    /// `gaps` with the aired episodes of `season` filled in, fetched once and kept with the show's other gaps.
    package func opening(_ season: MissingSeason, of show: PlexMetadata, in gaps: ShowGaps, check: ShowGapsCheck, now: Date = Date()) async -> ShowGaps? {
        guard gaps.episodes[season.index] == nil else { return gaps }
        do {
            var filled = gaps
            filled.episodes[season.index] = try await check.episodes(of: season, now: now)
            if let guid = show.guid, var cached = entries[guid] {
                cached.gaps.episodes[season.index] = filled.episodes[season.index]
                entries[guid] = cached
            }
            return filled
        } catch {
            MidgarLog.notice("Show gaps: season \(season.index) unavailable: \(error.localizedDescription)", category: .networking)
            return nil
        }
    }

    package func forgetAll() {
        entries = [:]
    }

    private func remember(_ guid: String, _ entry: Entry) {
        entries[guid] = entry
        guard entries.count > Self.keep, let oldest = entries.min(by: { $0.value.at < $1.value.at })?.key else { return }
        entries[oldest] = nil
    }

    /// Which episodes the server has, so a newly arrived one makes the cached look stale.
    private static func signature(_ episodes: [PlexMetadata]) -> Int {
        var hasher = Hasher()
        for code in episodes.compactMap({ episode -> Int? in
            guard let season = episode.parentIndex, let number = episode.index else { return nil }
            return season * 100_000 + number
        }).sorted() {
            hasher.combine(code)
        }
        return hasher.finalize()
    }
}

/// The words for what the server lacks.
package enum ShowGapsCopy {
    /// Under a season or beside an episode the server does not have.
    package static var notOnServer: String { SeerrCopy.seasonStatus(.missing) }

    package static func eyebrow(episode: Int) -> String {
        let number = "E\(episode)"
        return String(localized: "\(number) · NOT ON YOUR SERVER", comment: "Label above an episode that has aired but is not on the viewer's server, e.g. E5 · NOT ON YOUR SERVER")
    }

    /// When an episode first aired, e.g. Aired 7 Nov 2026.
    package static func aired(_ airDate: String) -> String? {
        let parts = airDate.prefix(10).split(separator: "-").compactMap { Int($0) }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        guard parts.count == 3, let date = gregorian.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return nil }
        let text = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Formatters.interfaceLocale))
        return String(localized: "Aired \(text)", comment: "When an episode the server lacks first aired, e.g. Aired Nov 7, 2026")
    }
}
