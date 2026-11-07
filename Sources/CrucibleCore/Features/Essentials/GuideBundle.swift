import Foundation

/// Crucible Guides as the dataset publishes it (github.com/guitaripod/crucible-guides, CC BY-SA 4.0): for each
/// long show, which episodes adapt the source and which the anime made up, with the evidence for each.
package struct GuideBundle: Decodable, Sendable, Equatable {
    package let format: Int
    package let generated: String
    package let licence: String
    package let shows: [GuideShow]

    /// The guide whose ids include one of the Plex show's external ids.
    package func show(matching ids: ExternalIDs) -> GuideShow? {
        shows.first { $0.ids.matches(ids) }
    }
}

package struct GuideShow: Decodable, Sendable, Equatable {
    package let slug: String
    package let title: String
    package let titles: [String]
    package let ids: GuideIDs
    package let episodes: [GuideEpisode]
    package let ranges: [GuideRange]
    package let arcs: [GuideArc]
    package let sources: [GuideSource]

    enum CodingKeys: String, CodingKey {
        case slug, title, titles, ids, episodes, ranges, arcs, sources
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decode(String.self, forKey: .title)
        titles = try c.decodeIfPresent([String].self, forKey: .titles) ?? []
        ids = try c.decode(GuideIDs.self, forKey: .ids)
        episodes = try c.decode([GuideEpisode].self, forKey: .episodes)
        ranges = try c.decodeIfPresent([GuideRange].self, forKey: .ranges) ?? []
        arcs = try c.decodeIfPresent([GuideArc].self, forKey: .arcs) ?? []
        sources = try c.decodeIfPresent([GuideSource].self, forKey: .sources) ?? []
    }

    package init(slug: String, title: String, ids: GuideIDs, episodes: [GuideEpisode], ranges: [GuideRange] = [], arcs: [GuideArc] = [], sources: [GuideSource] = []) {
        self.slug = slug
        self.title = title
        self.titles = [title]
        self.ids = ids
        self.episodes = episodes
        self.ranges = ranges
        self.arcs = arcs
        self.sources = sources
    }
}

package struct GuideIDs: Decodable, Sendable, Equatable {
    package let tvdb: Int?
    package let tmdb: Int?
    package let imdb: String?
    package let anidb: Int?
    package let mal: Int?

    package init(tvdb: Int? = nil, tmdb: Int? = nil, imdb: String? = nil, anidb: Int? = nil, mal: Int? = nil) {
        self.tvdb = tvdb
        self.tmdb = tmdb
        self.imdb = imdb
        self.anidb = anidb
        self.mal = mal
    }

    package func matches(_ other: ExternalIDs) -> Bool {
        if let tvdb, tvdb == other.tvdb { return true }
        if let tmdb, tmdb == other.tmdb { return true }
        if let imdb, imdb == other.imdb { return true }
        return false
    }
}

package enum GuideKind: String, Sendable, Equatable {
    case canon, mixed, animeOnly = "anime-only", filler, recap, unknown

    /// The kinds Skip Anime-Only hides. Each was called so by two independent signals in the guide's sources.
    package var isAnimeOnly: Bool { self == .animeOnly || self == .filler || self == .recap }
}

extension GuideKind: Decodable {
    package init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = GuideKind(rawValue: raw) ?? .unknown
    }
}

package struct GuideEpisode: Decodable, Sendable, Equatable {
    package let n: Int
    package let aired: String?
    package let title: String
    package let kind: GuideKind

    package init(n: Int, aired: String? = nil, title: String = "", kind: GuideKind) {
        self.n = n
        self.aired = aired
        self.title = title
        self.kind = kind
    }
}

/// A stretch of episodes a source says retells something the viewer may already have seen.
package struct GuideRange: Decodable, Sendable, Equatable {
    package let from: Int
    package let to: Int
    package let retells: [String]
    package let source: String
    package let url: String
    package let quote: String

    package func contains(_ n: Int) -> Bool { (from...to).contains(n) }
}

package struct GuideArc: Decodable, Sendable, Equatable {
    package let name: String
    package let from: Int
    package let to: Int
}

package struct GuideSource: Decodable, Sendable, Equatable {
    package let id: String
    package let name: String
    package let licence: String
    package let licenceUrl: String
    package let url: String
}

/// The external ids Plex's agents attach to a show (`Guid` entries such as `tvdb://295068`).
package struct ExternalIDs: Sendable, Equatable {
    package var tvdb: Int?
    package var tmdb: Int?
    package var imdb: String?

    package init(tvdb: Int? = nil, tmdb: Int? = nil, imdb: String? = nil) {
        self.tvdb = tvdb
        self.tmdb = tmdb
        self.imdb = imdb
    }

    package init(guids: [String]) {
        for guid in guids {
            let parts = guid.components(separatedBy: "://")
            guard parts.count == 2 else { continue }
            let value = parts[1].components(separatedBy: CharacterSet(charactersIn: "?/")).first ?? parts[1]
            switch parts[0].lowercased() {
            case "tvdb": tvdb = Int(value)
            case "tmdb": tmdb = Int(value)
            case "imdb": imdb = value
            default: break
            }
        }
    }

    package var isEmpty: Bool { tvdb == nil && tmdb == nil && imdb == nil }
}
