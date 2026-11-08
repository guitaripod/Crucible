import Foundation

/// Whether a title is a movie or a show, in Seerr's words.
package enum SeerrMediaKind: String, Codable, Sendable {
    case movie
    case tv

    package init?(plexType: String?) {
        switch plexType {
        case "movie": self = .movie
        case "show", "season", "episode": self = .tv
        default: return nil
        }
    }
}

/// How far a title is from being on the server, as Seerr tracks it.
package enum SeerrMediaStatus: Int, Codable, Sendable {
    case unknown = 1
    case pending
    case processing
    case partiallyAvailable
    case available
    case blocklisted
    case deleted
}

/// Where a request stands with whoever approves requests.
package enum SeerrRequestStatus: Int, Codable, Sendable {
    case pending = 1
    case approved
    case declined
    case failed
    case completed
}

/// What a Seerr user may do, as Seerr's permission bits.
package struct SeerrPermissions: OptionSet, Codable, Sendable, Hashable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let admin = SeerrPermissions(rawValue: 2)
    package static let manageRequests = SeerrPermissions(rawValue: 16)
    package static let request = SeerrPermissions(rawValue: 32)
    package static let autoApprove = SeerrPermissions(rawValue: 128)
    package static let autoApproveMovie = SeerrPermissions(rawValue: 256)
    package static let autoApproveTV = SeerrPermissions(rawValue: 512)
    package static let requestView = SeerrPermissions(rawValue: 16_384)
    package static let requestMovie = SeerrPermissions(rawValue: 262_144)
    package static let requestTV = SeerrPermissions(rawValue: 524_288)

    package func canRequest(_ kind: SeerrMediaKind) -> Bool {
        if contains(.admin) || contains(.request) { return true }
        return contains(kind == .movie ? .requestMovie : .requestTV)
    }

    package func autoApproves(_ kind: SeerrMediaKind) -> Bool {
        if contains(.admin) || contains(.autoApprove) { return true }
        return contains(kind == .movie ? .autoApproveMovie : .autoApproveTV)
    }

    /// Approves, declines and sees everyone's requests.
    package var managesRequests: Bool { contains(.admin) || contains(.manageRequests) }
}

package struct SeerrUser: Codable, Equatable, Sendable {
    package let id: Int
    package let displayName: String?
    package let username: String?
    package let plexUsername: String?
    package let email: String?
    package let permissions: Int?
    package let requestCount: Int?

    package init(id: Int, displayName: String? = nil, username: String? = nil, plexUsername: String? = nil, email: String? = nil, permissions: Int? = nil, requestCount: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.username = username
        self.plexUsername = plexUsername
        self.email = email
        self.permissions = permissions
        self.requestCount = requestCount
    }

    package var name: String {
        [displayName, username, plexUsername, email].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "#\(id)"
    }

    package var rights: SeerrPermissions { SeerrPermissions(rawValue: permissions ?? 0) }
}

/// A download Sonarr or Radarr is running for a title, as Seerr relays it.
package struct SeerrDownload: Codable, Equatable, Sendable {
    package struct Episode: Codable, Equatable, Sendable {
        package let seasonNumber: Int?
        package let episodeNumber: Int?
    }

    package let size: Double?
    package let sizeLeft: Double?
    package let status: String?
    package let estimatedCompletionTime: String?
    package let title: String?
    package let episode: Episode?

    package init(size: Double?, sizeLeft: Double?, status: String? = nil, estimatedCompletionTime: String? = nil, title: String? = nil, episode: Episode? = nil) {
        self.size = size
        self.sizeLeft = sizeLeft
        self.status = status
        self.estimatedCompletionTime = estimatedCompletionTime
        self.title = title
        self.episode = episode
    }
}

package struct SeerrSeasonStatus: Codable, Equatable, Sendable {
    package let seasonNumber: Int
    package let status: Int?

    package init(seasonNumber: Int, status: Int?) {
        self.seasonNumber = seasonNumber
        self.status = status
    }
}

/// What Seerr knows of a title it has seen: its availability, its requests, its downloads and, once it is on the server,
/// the Plex rating key it plays under.
package struct SeerrMediaInfo: Codable, Equatable, Sendable {
    package let id: Int?
    package let tmdbId: Int?
    package let tvdbId: Int?
    package let mediaType: String?
    package let status: Int?
    package let requests: [SeerrRequest]?
    package let seasons: [SeerrSeasonStatus]?
    package let downloadStatus: [SeerrDownload]?
    package let ratingKey: String?

    package init(
        id: Int? = nil, tmdbId: Int? = nil, tvdbId: Int? = nil, mediaType: String? = nil, status: Int? = nil, requests: [SeerrRequest]? = nil,
        seasons: [SeerrSeasonStatus]? = nil, downloadStatus: [SeerrDownload]? = nil, ratingKey: String? = nil
    ) {
        self.id = id
        self.tmdbId = tmdbId
        self.tvdbId = tvdbId
        self.mediaType = mediaType
        self.status = status
        self.requests = requests
        self.seasons = seasons
        self.downloadStatus = downloadStatus
        self.ratingKey = ratingKey
    }

    package var mediaStatus: SeerrMediaStatus { status.flatMap(SeerrMediaStatus.init(rawValue:)) ?? .unknown }
}

package struct SeerrRequestSeason: Codable, Equatable, Sendable {
    package let seasonNumber: Int
    package let status: Int?

    package init(seasonNumber: Int, status: Int?) {
        self.seasonNumber = seasonNumber
        self.status = status
    }
}

package struct SeerrRequest: Codable, Equatable, Sendable {
    package let id: Int
    package let status: Int
    package let type: String?
    package let media: SeerrMediaInfo?
    package let createdAt: String?
    package let updatedAt: String?
    package let requestedBy: SeerrUser?
    package let is4k: Bool?
    package let seasons: [SeerrRequestSeason]?

    package init(
        id: Int, status: Int, type: String? = nil, media: SeerrMediaInfo? = nil, createdAt: String? = nil, updatedAt: String? = nil,
        requestedBy: SeerrUser? = nil, is4k: Bool? = false, seasons: [SeerrRequestSeason]? = nil
    ) {
        self.id = id
        self.status = status
        self.type = type
        self.media = media
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.requestedBy = requestedBy
        self.is4k = is4k
        self.seasons = seasons
    }

    package var requestStatus: SeerrRequestStatus { SeerrRequestStatus(rawValue: status) ?? .pending }
    package var kind: SeerrMediaKind? { (type ?? media?.mediaType).flatMap(SeerrMediaKind.init(rawValue:)) }
    package var created: Date? { createdAt.flatMap(SeerrDate.parse) }
}

package struct SeerrSeason: Decodable, Equatable, Sendable {
    package let seasonNumber: Int
    package let name: String?
    package let episodeCount: Int?
    package let airDate: String?

    package init(seasonNumber: Int, name: String? = nil, episodeCount: Int? = nil, airDate: String? = nil) {
        self.seasonNumber = seasonNumber
        self.name = name
        self.episodeCount = episodeCount
        self.airDate = airDate
    }
}

/// A movie or a show as Seerr describes it, with what Seerr knows of it.
package struct SeerrTitleDetails: Decodable, Equatable, Sendable {
    package struct ExternalIDs: Decodable, Equatable, Sendable {
        package let tvdbId: Int?
        package let imdbId: String?
    }

    package let id: Int
    package let title: String?
    package let name: String?
    package let overview: String?
    package let posterPath: String?
    package let backdropPath: String?
    package let releaseDate: String?
    package let firstAirDate: String?
    package let seasons: [SeerrSeason]?
    package let externalIds: ExternalIDs?
    package let mediaInfo: SeerrMediaInfo?

    package init(
        id: Int, title: String? = nil, name: String? = nil, overview: String? = nil, posterPath: String? = nil, backdropPath: String? = nil,
        releaseDate: String? = nil, firstAirDate: String? = nil, seasons: [SeerrSeason]? = nil, externalIds: ExternalIDs? = nil, mediaInfo: SeerrMediaInfo? = nil
    ) {
        self.id = id
        self.title = title
        self.name = name
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.releaseDate = releaseDate
        self.firstAirDate = firstAirDate
        self.seasons = seasons
        self.externalIds = externalIds
        self.mediaInfo = mediaInfo
    }

    package var displayTitle: String { title ?? name ?? "" }

    package var year: Int? {
        guard let date = releaseDate ?? firstAirDate, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }
}

/// One result of a Seerr search: a movie, a show or a person, with what Seerr knows of the title.
package struct SeerrSearchResult: Decodable, Sendable {
    package let id: Int
    package let mediaType: String
    package let title: String?
    package let name: String?
    package let releaseDate: String?
    package let firstAirDate: String?
    package let posterPath: String?
    package let overview: String?
    package let mediaInfo: SeerrMediaInfo?
}

/// A title a search found that the server does not have, offered for request.
package struct SeerrSearchHit: Hashable, Sendable {
    package let tmdbID: Int
    package let kind: SeerrMediaKind
    package let title: String
    package let year: Int?
    package let posterPath: String?
    package let overview: String?
    package let availability: SeerrAvailability

    package init(tmdbID: Int, kind: SeerrMediaKind, title: String, year: Int?, posterPath: String?, overview: String?, availability: SeerrAvailability) {
        self.tmdbID = tmdbID
        self.kind = kind
        self.title = title
        self.year = year
        self.posterPath = posterPath
        self.overview = overview
        self.availability = availability
    }

    /// The hit as a Plex-shaped title, carrying its TMDB id, for the screens that request titles.
    package var asMetadata: PlexMetadata {
        PlexMetadata(
            ratingKey: "seerr-\(kind.rawValue)-\(tmdbID)", key: nil, type: kind == .tv ? "show" : "movie", title: title,
            grandparentTitle: nil, grandparentRatingKey: nil, grandparentThumb: nil, grandparentArt: nil, parentTitle: nil,
            parentRatingKey: nil, parentThumb: nil, parentIndex: nil, index: nil, year: year, summary: overview, tagline: nil,
            contentRating: nil, studio: nil, rating: nil, audienceRating: nil, duration: nil, viewOffset: nil, viewCount: nil,
            lastViewedAt: nil, viewedAt: nil, accountID: nil, deviceID: nil, addedAt: nil, originallyAvailableAt: nil, thumb: nil,
            art: nil, leafCount: nil, viewedLeafCount: nil, childCount: nil, librarySectionID: nil, librarySectionTitle: nil,
            Genre: nil, Role: nil, Director: nil, Writer: nil, Media: nil, Marker: nil, Related: nil,
            externalGuids: [PlexGuid(id: "tmdb://\(tmdbID)")]
        )
    }
}

package struct SeerrPage<Item: Decodable & Sendable>: Decodable, Sendable {
    package struct PageInfo: Decodable, Sendable {
        package let pages: Int?
        package let page: Int?
        package let results: Int?
    }

    package let pageInfo: PageInfo?
    package let results: [Item]
}

package struct SeerrServerStatus: Decodable, Equatable, Sendable {
    package let version: String
}

/// The settings Seerr shows anyone, before signing in.
package struct SeerrPublicSettings: Codable, Equatable, Sendable {
    package let initialized: Bool?
    package let applicationTitle: String?
    package let applicationUrl: String?
    package let mediaServerType: Int?
    package let mediaServerLogin: Bool?
    package let partialRequestsEnabled: Bool?

    package init(initialized: Bool? = true, applicationTitle: String? = nil, applicationUrl: String? = nil, mediaServerType: Int? = 1, mediaServerLogin: Bool? = true, partialRequestsEnabled: Bool? = true) {
        self.initialized = initialized
        self.applicationTitle = applicationTitle
        self.applicationUrl = applicationUrl
        self.mediaServerType = mediaServerType
        self.mediaServerLogin = mediaServerLogin
        self.partialRequestsEnabled = partialRequestsEnabled
    }

    /// Seerr set up for Plex; Jellyfin and Emby setups cannot take a Plex sign-in.
    package var servesPlex: Bool { mediaServerType == nil || mediaServerType == 1 }
}

/// How many requests the viewer has left, when Seerr limits them.
package struct SeerrQuota: Decodable, Equatable, Sendable {
    package struct Limit: Decodable, Equatable, Sendable {
        package let days: Int?
        package let limit: Int?
        package let used: Int?
        package let remaining: Int?
        package let restricted: Bool?
    }

    package let movie: Limit?
    package let tv: Limit?
}

/// Seerr's dates: ISO 8601 with or without fractional seconds.
package enum SeerrDate {
    package static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
