import Foundation

struct PlexResponse: Decodable, Sendable {
    let MediaContainer: PlexMediaContainer

    enum CodingKeys: String, CodingKey {
        case MediaContainer
    }
}

struct PlexMediaContainer: Decodable, Sendable {
    let size: Int?
    let totalSize: Int?
    let offset: Int?
    let title1: String?
    let title2: String?
    let viewGroup: String?
    let librarySectionID: Int?
    let librarySectionTitle: String?
    let Metadata: [PlexMetadata]?
    let Hub: [PlexHub]?
    let Directory: [PlexDirectory]?

    enum CodingKeys: String, CodingKey {
        case size, totalSize, offset, title1, title2, viewGroup
        case librarySectionID, librarySectionTitle
        case Metadata, Hub, Directory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        totalSize = try container.decodeIfPresent(Int.self, forKey: .totalSize)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset)
        title1 = try container.decodeIfPresent(String.self, forKey: .title1)
        title2 = try container.decodeIfPresent(String.self, forKey: .title2)
        viewGroup = try container.decodeIfPresent(String.self, forKey: .viewGroup)
        librarySectionID = try container.decodeIfPresent(Int.self, forKey: .librarySectionID)
        librarySectionTitle = try container.decodeIfPresent(String.self, forKey: .librarySectionTitle)
        Metadata = try container.decodeIfPresent([PlexMetadata].self, forKey: .Metadata)
        Hub = try container.decodeIfPresent([PlexHub].self, forKey: .Hub)
        Directory = try container.decodeIfPresent([PlexDirectory].self, forKey: .Directory)
    }
}

struct PlexMetadata: Decodable, Sendable {
    let ratingKey: String
    let key: String?
    let type: String
    let title: String
    let originalTitle: String?
    let grandparentTitle: String?
    let grandparentRatingKey: String?
    let grandparentThumb: String?
    let grandparentArt: String?
    let parentTitle: String?
    let parentRatingKey: String?
    let parentThumb: String?
    let parentIndex: Int?
    let index: Int?
    let year: Int?
    let summary: String?
    let rating: Double?
    let audienceRating: Double?
    let contentRating: String?
    let duration: Int?
    let viewOffset: Int?
    let viewCount: Int?
    let lastViewedAt: Int?
    let addedAt: Int?
    let updatedAt: Int?
    let originallyAvailableAt: String?
    let thumb: String?
    let art: String?
    let leafCount: Int?
    let viewedLeafCount: Int?
    let childCount: Int?
    let skipChildren: Bool?
    let Genre: [PlexTag]?
    let Media: [PlexMedia]?

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title, originalTitle
        case grandparentTitle, grandparentRatingKey, grandparentThumb, grandparentArt
        case parentTitle, parentRatingKey, parentThumb
        case parentIndex, index, year, summary, rating, audienceRating, contentRating
        case duration, viewOffset, viewCount, lastViewedAt, addedAt, updatedAt
        case originallyAvailableAt, thumb, art
        case leafCount, viewedLeafCount, childCount, skipChildren
        case Genre, Media
    }
}

extension PlexMetadata: Hashable {
    static func == (lhs: PlexMetadata, rhs: PlexMetadata) -> Bool {
        lhs.ratingKey == rhs.ratingKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ratingKey)
    }
}

extension PlexMetadata {
    var durationSecs: Double {
        Double(duration ?? 0) / 1000.0
    }

    var positionSecs: Double {
        Double(viewOffset ?? 0) / 1000.0
    }

    var isWatched: Bool {
        (viewCount ?? 0) > 0
    }

    var progressPercent: Double {
        guard let offset = viewOffset, let dur = duration, dur > 0 else { return 0 }
        return Double(offset) / Double(dur)
    }

    var mediaType: String { type }

    var posterPath: String? { thumb }
    var backdropPath: String? { art }
    var showName: String? { grandparentTitle }
    var showRatingKey: String? { grandparentRatingKey }
    var seasonNumber: Int? { parentIndex }
    var episodeNumber: Int? { index }

    var videoWidth: Int? { Media?.first?.width }
    var videoHeight: Int? { Media?.first?.height }
    var videoCodec: String? { Media?.first?.videoCodec }
    var audioCodec: String? { Media?.first?.audioCodec }
    var audioChannels: Int? { Media?.first?.audioChannels }
    var videoResolution: String? { Media?.first?.videoResolution }
    var fileSize: Int64? { Media?.first?.Part?.first?.size }

    var subtitleStreams: [PlexStream] {
        Media?.first?.Part?.first?.Stream?.filter { $0.streamType == 3 } ?? []
    }

    var audioStreams: [PlexStream] {
        Media?.first?.Part?.first?.Stream?.filter { $0.streamType == 2 } ?? []
    }

    var directPlayPath: String? {
        Media?.first?.Part?.first?.key
    }

    var genres: [String] {
        Genre?.map(\.tag) ?? []
    }
}

struct PlexMedia: Decodable, Sendable {
    let id: Int?
    let videoCodec: String?
    let audioCodec: String?
    let videoResolution: String?
    let width: Int?
    let height: Int?
    let audioChannels: Int?
    let bitrate: Int?
    let videoProfile: String?
    let Part: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case id, videoCodec, audioCodec, videoResolution
        case width, height, audioChannels, bitrate, videoProfile
        case Part
    }
}

struct PlexPart: Decodable, Sendable {
    let id: Int
    let key: String
    let file: String?
    let size: Int64?
    let duration: Int?
    let Stream: [PlexStream]?

    enum CodingKeys: String, CodingKey {
        case id, key, file, size, duration
        case Stream
    }
}

struct PlexStream: Decodable, Sendable, Identifiable {
    let id: Int
    let streamType: Int
    let codec: String?
    let language: String?
    let languageCode: String?
    let languageTag: String?
    let channels: Int?
    let bitrate: Int?
    let title: String?
    let selected: Bool?
    let isDefault: Bool?
    let forced: Bool?
    let format: String?
    let key: String?
    let displayTitle: String?
    let extendedDisplayTitle: String?

    enum CodingKeys: String, CodingKey {
        case id, streamType, codec, language, languageCode, languageTag
        case channels, bitrate, title, selected
        case isDefault = "default"
        case forced, format, key, displayTitle, extendedDisplayTitle
    }

    var isBitmap: Bool {
        guard let codec else { return false }
        let bitmapCodecs = ["dvd_subtitle", "hdmv_pgs_subtitle", "pgssub", "vobsub", "dvb_subtitle"]
        return bitmapCodecs.contains(codec)
    }

    var channelDescription: String {
        Formatters.channelDescription(channels)
    }
}

extension PlexStream: Hashable {
    static func == (lhs: PlexStream, rhs: PlexStream) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct PlexTag: Decodable, Sendable {
    let tag: String
}

struct PlexHub: Decodable, Sendable {
    let type: String?
    let hubIdentifier: String?
    let title: String?
    let size: Int?
    let promoted: Bool?
    let Metadata: [PlexMetadata]?

    enum CodingKeys: String, CodingKey {
        case type, hubIdentifier, title, size, promoted
        case Metadata
    }
}

struct PlexDirectory: Decodable, Sendable {
    let key: String
    let type: String?
    let title: String
    let uuid: String?
    let agent: String?
    let scanner: String?
    let language: String?
}

struct PlexResource: Decodable, Sendable {
    let name: String
    let provides: String
    let clientIdentifier: String
    let owned: Bool?
    let connections: [PlexResourceConnection]
}

struct PlexResourceConnection: Decodable, Sendable {
    let uri: String
    let address: String?
    let port: Int?
    let `protocol`: String?
    let local: Bool?
    let relay: Bool?
}

struct PlexPin: Decodable, Sendable {
    let id: Int
    let code: String
    let authToken: String?
}

struct PlexIdentity: Decodable, Sendable {
    let MediaContainer: PlexIdentityContainer

    struct PlexIdentityContainer: Decodable, Sendable {
        let machineIdentifier: String?
        let version: String?
    }
}
