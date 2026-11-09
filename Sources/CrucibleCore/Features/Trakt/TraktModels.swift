import Foundation

/// The identifiers Trakt keeps for a movie, show, season, episode or person. Every field is optional because each kind
/// carries a different subset, and a request needs only one of them.
package struct TraktIDs: Codable, Hashable, Sendable {
    package var trakt: Int?
    package var slug: String?
    package var imdb: String?
    package var tmdb: Int?
    package var tvdb: Int?

    package init(trakt: Int? = nil, slug: String? = nil, imdb: String? = nil, tmdb: Int? = nil, tvdb: Int? = nil) {
        self.trakt = trakt
        self.slug = slug
        self.imdb = imdb
        self.tmdb = tmdb
        self.tvdb = tvdb
    }

    /// Only the Trakt id, which is what writes are best keyed by once it is known.
    package var traktOnly: TraktIDs { trakt.map { TraktIDs(trakt: $0) } ?? self }
}

package struct TraktMovie: Codable, Hashable, Sendable {
    package var title: String?
    package var year: Int?
    package var ids: TraktIDs

    package init(title: String? = nil, year: Int? = nil, ids: TraktIDs) {
        self.title = title
        self.year = year
        self.ids = ids
    }
}

package struct TraktShow: Codable, Hashable, Sendable {
    package var title: String?
    package var year: Int?
    package var ids: TraktIDs

    package init(title: String? = nil, year: Int? = nil, ids: TraktIDs) {
        self.title = title
        self.year = year
        self.ids = ids
    }
}

package struct TraktEpisode: Codable, Hashable, Sendable {
    package var season: Int?
    package var number: Int?
    package var title: String?
    package var ids: TraktIDs

    package init(season: Int? = nil, number: Int? = nil, title: String? = nil, ids: TraktIDs) {
        self.season = season
        self.number = number
        self.title = title
        self.ids = ids
    }
}

/// One hit of a search, by text or by an outside id.
package struct TraktSearchResult: Decodable, Sendable {
    package let type: String
    package let movie: TraktMovie?
    package let show: TraktShow?
    package let episode: TraktEpisode?
}

/// What Trakt hands back for a device sign-in: the code the viewer types and how to wait for it.
package struct TraktDeviceCode: Decodable, Equatable, Sendable {
    package let deviceCode: String
    package let userCode: String
    package let verificationURL: String
    package let expiresIn: Int
    package let interval: Int

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }

    package init(deviceCode: String, userCode: String, verificationURL: String, expiresIn: Int, interval: Int) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

/// An access token and the single-use refresh token that replaces it.
package struct TraktToken: Codable, Equatable, Sendable {
    package let accessToken: String
    package let refreshToken: String
    package let expiresIn: Int
    package let createdAt: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case createdAt = "created_at"
    }

    package init(accessToken: String, refreshToken: String, expiresIn: Int, createdAt: Int) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.createdAt = createdAt
    }

    package var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(createdAt + expiresIn)) }

    /// Refresh a day before the seven days run out, so a token is never used at its last moment.
    package func needsRefresh(now: Date = Date()) -> Bool {
        now.addingTimeInterval(86_400) >= expiresAt
    }
}

/// The signed-in Trakt account as Crucible shows it: who it is, and the limits Trakt sets on it.
package struct TraktUserSettings: Decodable, Sendable {
    package struct User: Decodable, Sendable {
        package let username: String
        package let name: String?
        package let vip: Bool?
        package let isPrivate: Bool?
        package let images: Images?

        package struct Images: Decodable, Sendable {
            package let avatar: Avatar?
            package struct Avatar: Decodable, Sendable { package let full: String? }
        }

        private enum CodingKeys: String, CodingKey {
            case username, name, vip, images
            case isPrivate = "private"
        }
    }

    package struct Limits: Decodable, Sendable {
        package struct Count: Decodable, Sendable { package let itemCount: Int?; private enum CodingKeys: String, CodingKey { case itemCount = "item_count" } }
        package let watchlist: Count?
    }

    package let user: User
    package let limits: Limits?
}

/// Whether Trakt's own Plex link is recording plays: the toggles of its real-time scrobbler and of its batch sync, and the
/// servers it reaches.
package struct TraktPlexSettings: Decodable, Sendable {
    package struct Toggles: Decodable, Sendable {
        package struct Play: Decodable, Sendable { package let watched: Bool? }
        package let movie: Play?
        package let episode: Play?

        package var recordsPlays: Bool { movie?.watched == true || episode?.watched == true }
    }

    package struct Connection: Decodable, Sendable { package let connected: Bool }
    package struct Scrobbler: Decodable, Sendable { package let toggles: Toggles? }
    package struct Sync: Decodable, Sendable {
        package struct Selection: Decodable, Sendable {
            package let serverIDs: [String]?
            private enum CodingKeys: String, CodingKey { case serverIDs = "server_ids" }
        }
        package let configured: Bool?
        package let selection: Selection?
        package let toggles: Toggles?
    }

    package let connection: Connection?
    package let scrobbler: Scrobbler?
    package let sync: Sync?
}

/// What Trakt answers a scrobble with: the action it took and the progress it recorded.
package struct TraktScrobbleResult: Decodable, Sendable {
    package let action: String
    package let progress: Double?
}

/// One source's score for a title, as the ratings strip shows it.
package struct TraktScore: Hashable, Sendable {
    package enum Source: String, CaseIterable, Sendable {
        case trakt, imdb, tmdb, rottenTomatoes, metascore, letterboxd, myAnimeList
    }

    package let source: Source
    package let value: Double
    package let votes: Int?
    package let link: URL?
}

/// Every score Trakt knows for a title (`/…/ratings?extended=all`).
package struct TraktRatings: Decodable, Sendable {
    package struct Entry: Decodable, Sendable {
        package let rating: Double?
        package let votes: Int?
        package let link: String?
    }

    package let trakt: Entry?
    package let imdb: Entry?
    package let tmdb: Entry?
    package let metascore: Entry?
    package let rottenTomatoes: Entry?
    package let letterboxd: Entry?
    package let mal: Entry?

    private enum CodingKeys: String, CodingKey {
        case trakt, imdb, tmdb, metascore, letterboxd, mal
        case rottenTomatoes = "rotten_tomatoes"
    }

    /// The scores in the order the strip shows them, each only when Trakt has a value for it.
    package var scores: [TraktScore] {
        let entries: [(TraktScore.Source, Entry?)] = [
            (.trakt, trakt), (.imdb, imdb), (.rottenTomatoes, rottenTomatoes), (.metascore, metascore),
            (.letterboxd, letterboxd), (.tmdb, tmdb), (.myAnimeList, mal),
        ]
        return entries.compactMap { source, entry in
            guard let entry, let rating = entry.rating, rating > 0 else { return nil }
            if source == .trakt, (entry.votes ?? 0) == 0 { return nil }
            return TraktScore(source: source, value: rating, votes: entry.votes, link: entry.link.flatMap(URL.init(string:)))
        }
    }
}

/// The items one write to `/sync/history`, `/sync/ratings` or `/checkin` names.
package struct TraktSyncItems: Encodable, Sendable {
    package struct Movie: Encodable, Sendable {
        package let ids: TraktIDs
        package let watchedAt: String?
        package let rating: Int?
        package let ratedAt: String?
        private enum CodingKeys: String, CodingKey { case ids, rating; case watchedAt = "watched_at"; case ratedAt = "rated_at" }
    }

    package struct Episode: Encodable, Sendable {
        package let ids: TraktIDs
        package let watchedAt: String?
        package let rating: Int?
        package let ratedAt: String?
        private enum CodingKeys: String, CodingKey { case ids, rating; case watchedAt = "watched_at"; case ratedAt = "rated_at" }
    }

    package struct Season: Encodable, Sendable {
        package let number: Int
        package let watchedAt: String?
        package let rating: Int?
        package let ratedAt: String?
        private enum CodingKeys: String, CodingKey { case number, rating; case watchedAt = "watched_at"; case ratedAt = "rated_at" }
    }

    package struct Show: Encodable, Sendable {
        package let ids: TraktIDs
        package let watchedAt: String?
        package let rating: Int?
        package let ratedAt: String?
        package let seasons: [Season]?
        private enum CodingKeys: String, CodingKey { case ids, rating, seasons; case watchedAt = "watched_at"; case ratedAt = "rated_at" }
    }

    package var movies: [Movie] = []
    package var shows: [Show] = []
    package var episodes: [Episode] = []

    package init(movies: [Movie] = [], shows: [Show] = [], episodes: [Episode] = []) {
        self.movies = movies
        self.shows = shows
        self.episodes = episodes
    }

    package var isEmpty: Bool { movies.isEmpty && shows.isEmpty && episodes.isEmpty }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !movies.isEmpty { try container.encode(movies, forKey: .movies) }
        if !shows.isEmpty { try container.encode(shows, forKey: .shows) }
        if !episodes.isEmpty { try container.encode(episodes, forKey: .episodes) }
    }

    private enum CodingKeys: String, CodingKey { case movies, shows, episodes }
}

/// The dates Trakt reads and writes: ISO 8601 in UTC with milliseconds.
package enum TraktDate {
    package static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// One entry of the viewer's Trakt history (`GET /sync/history?extended=full,images`): a movie or an episode with its show,
/// and when it was watched.
package struct TraktHistoryEntry: Decodable, Sendable {
    package struct Images: Decodable, Sendable {
        package let poster: [String]?
        package let thumb: [String]?
        package let screenshot: [String]?

        /// The first poster as a loadable URL; Trakt sends them without a scheme.
        package var posterURL: String? { Self.url(poster?.first) }
        /// An episode's still, else its thumb.
        package var stillURL: String? { Self.url(screenshot?.first ?? thumb?.first) }

        private static func url(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            return raw.hasPrefix("http") ? raw : "https://" + raw
        }
    }

    package struct Movie: Decodable, Sendable {
        package let title: String?
        package let year: Int?
        package let ids: TraktIDs
        package let runtime: Int?
        package let genres: [String]?
        package let images: Images?
    }

    package struct Show: Decodable, Sendable {
        package let title: String?
        package let year: Int?
        package let ids: TraktIDs
        package let genres: [String]?
        package let images: Images?
    }

    package struct Episode: Decodable, Sendable {
        package let season: Int?
        package let number: Int?
        package let title: String?
        package let ids: TraktIDs
        package let runtime: Int?
        package let images: Images?
    }

    package let id: Int64
    package let watchedAt: String
    package let type: String
    package let movie: Movie?
    package let show: Show?
    package let episode: Episode?

    private enum CodingKeys: String, CodingKey {
        case id, type, movie, show, episode
        case watchedAt = "watched_at"
    }

    /// When it was watched, as Unix seconds; nil when Trakt sent a date Crucible can't read.
    package var watchedAtSeconds: Int? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return (fractional.date(from: watchedAt) ?? plain.date(from: watchedAt)).map { Int($0.timeIntervalSince1970) }
    }
}
