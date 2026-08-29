import Foundation

struct PlexResponse: Decodable, Sendable {
    let MediaContainer: PlexMediaContainer

    enum CodingKeys: String, CodingKey {
        case MediaContainer
    }
}

/// Dedicated, fully-lenient decode for `/status/sessions/history/all`. Every field is optional and
/// type-tolerant so a single malformed/missing field (or a non-numeric id) can never fail the whole
/// sync — history responses are noisier than library metadata.
struct PlexHistoryResponse: Decodable, Sendable {
    let MediaContainer: Container

    struct Container: Decodable, Sendable {
        let totalSize: Int?
        let Metadata: [PlexHistoryEntry]?

        enum CodingKeys: String, CodingKey { case totalSize, Metadata }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            totalSize = (try? c.decodeIfPresent(Int.self, forKey: .totalSize)) ?? nil
            Metadata = (try? c.decodeIfPresent([PlexHistoryEntry].self, forKey: .Metadata)) ?? nil
        }
    }
}

struct PlexHistoryEntry: Decodable, Sendable {
    let ratingKey: String?
    let type: String?
    let title: String?
    let grandparentTitle: String?
    let grandparentRatingKey: String?
    let grandparentThumb: String?
    let thumb: String?
    let parentIndex: Int?
    let index: Int?
    let viewedAt: Int?
    let librarySectionID: Int?
    let librarySectionTitle: String?
    let accountID: Int?
    let deviceID: Int?

    enum CodingKeys: String, CodingKey {
        case ratingKey, type, title, grandparentTitle, grandparentRatingKey, grandparentThumb, thumb
        case parentIndex, index, viewedAt, librarySectionID, librarySectionTitle, accountID, deviceID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ key: CodingKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
            return nil
        }
        func int(_ key: CodingKeys) -> Int? {
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
            if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int(s) }
            return nil
        }
        ratingKey = str(.ratingKey)
        type = str(.type)
        title = str(.title)
        grandparentTitle = str(.grandparentTitle)
        grandparentRatingKey = str(.grandparentRatingKey)
        grandparentThumb = str(.grandparentThumb)
        thumb = str(.thumb)
        parentIndex = int(.parentIndex)
        index = int(.index)
        viewedAt = int(.viewedAt)
        librarySectionID = int(.librarySectionID)
        librarySectionTitle = str(.librarySectionTitle)
        accountID = int(.accountID)
        deviceID = int(.deviceID)
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
    let ratingKey: String?
    let key: String?
    let type: String?
    let title: String
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
    let tagline: String?
    let contentRating: String?
    let studio: String?
    let rating: Double?
    let audienceRating: Double?
    let duration: Int?
    let viewOffset: Int?
    let viewCount: Int?
    let lastViewedAt: Int?
    let viewedAt: Int?
    let accountID: Int?
    let deviceID: Int?
    let addedAt: Int?
    let originallyAvailableAt: String?
    let thumb: String?
    let art: String?
    let leafCount: Int?
    let viewedLeafCount: Int?
    let childCount: Int?
    let librarySectionID: Int?
    let librarySectionTitle: String?
    let Genre: [PlexTag]?
    let Role: [PlexRole]?
    let Director: [PlexTag]?
    let Writer: [PlexTag]?
    let Media: [PlexMedia]?
    let Marker: [PlexMarker]?
    let Related: PlexRelatedHubs?

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, type, title
        case grandparentTitle, grandparentRatingKey, grandparentThumb, grandparentArt
        case parentTitle, parentRatingKey, parentThumb
        case parentIndex, index, year, summary, tagline, contentRating, studio, rating, audienceRating
        case duration, viewOffset, viewCount, lastViewedAt, viewedAt, accountID, deviceID, addedAt
        case originallyAvailableAt, thumb, art
        case leafCount, viewedLeafCount, childCount, librarySectionID, librarySectionTitle
        case Genre, Role, Director, Writer, Media, Marker, Related
    }
}

extension PlexMetadata {
    init(homeCard card: HomeCardSnapshot) {
        self.init(
            ratingKey: card.ratingKey,
            key: nil,
            type: card.type,
            title: card.title,
            grandparentTitle: card.grandparentTitle,
            grandparentRatingKey: card.grandparentRatingKey,
            grandparentThumb: card.grandparentThumb,
            grandparentArt: nil,
            parentTitle: nil,
            parentRatingKey: card.parentRatingKey,
            parentThumb: nil,
            parentIndex: card.parentIndex,
            index: card.index,
            year: card.year,
            summary: nil,
            tagline: nil,
            contentRating: nil,
            studio: nil,
            rating: nil,
            audienceRating: nil,
            duration: card.duration,
            viewOffset: card.viewOffset,
            viewCount: card.viewCount,
            lastViewedAt: nil,
            viewedAt: nil,
            accountID: nil,
            deviceID: nil,
            addedAt: nil,
            originallyAvailableAt: nil,
            thumb: card.thumb,
            art: nil,
            leafCount: nil,
            viewedLeafCount: nil,
            childCount: nil,
            librarySectionID: nil,
            librarySectionTitle: nil,
            Genre: nil,
            Role: nil,
            Director: nil,
            Writer: nil,
            Media: nil,
            Marker: nil,
            Related: nil
        )
    }

    func homeCard(bucket: String) -> HomeCardSnapshot {
        HomeCardSnapshot(
            ratingKey: id,
            type: type,
            title: title,
            grandparentTitle: grandparentTitle,
            grandparentRatingKey: grandparentRatingKey,
            grandparentThumb: grandparentThumb,
            parentRatingKey: parentRatingKey,
            thumb: thumb,
            parentIndex: parentIndex,
            index: index,
            year: year,
            viewOffset: viewOffset,
            duration: duration,
            viewCount: viewCount,
            bucket: bucket
        )
    }
}

struct PlexMarker: Decodable, Sendable {
    let type: String?
    let startTimeOffset: Int?
    let endTimeOffset: Int?
    let final: Bool?

    var isIntro: Bool { type == "intro" }
    var isCredits: Bool { type == "credits" }
    var startSecs: Double { Double(startTimeOffset ?? 0) / 1000.0 }
    var endSecs: Double { Double(endTimeOffset ?? 0) / 1000.0 }
}

struct PlexRole: Decodable, Sendable, Hashable {
    let id: Int?
    let tag: String?
    let role: String?
    let thumb: String?
}

struct PlexRelatedHubs: Decodable, Sendable {
    let Hub: [PlexHub]?
}

extension PlexMetadata: Hashable {
    static func == (lhs: PlexMetadata, rhs: PlexMetadata) -> Bool {
        lhs.hashId == rhs.hashId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(hashId)
    }

    private var hashId: String {
        ratingKey ?? key ?? title
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

    var id: String { ratingKey ?? key ?? "" }
    var mediaType: String { type ?? "unknown" }

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

    var mediaContainer: String? {
        if let container = Media?.first?.container, !container.isEmpty {
            return container.lowercased()
        }
        if let file = Media?.first?.Part?.first?.file,
           let ext = file.split(separator: ".").last {
            return String(ext).lowercased()
        }
        return nil
    }

    var genres: [String] {
        Genre?.map(\.tag) ?? []
    }

    var cast: [PlexRole] { Role ?? [] }
    var directors: [String] { Director?.map(\.tag) ?? [] }
    var writers: [String] { Writer?.map(\.tag) ?? [] }
    var relatedHubs: [PlexHub] { (Related?.Hub ?? []).filter { !($0.Metadata?.isEmpty ?? true) } }
    var introMarker: PlexMarker? { Marker?.first { $0.isIntro } }
    var firstCreditsMarker: PlexMarker? { Marker?.first { $0.isCredits } }
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
    let container: String?
    let Part: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case id, videoCodec, audioCodec, videoResolution
        case width, height, audioChannels, bitrate, videoProfile, container
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
    let id: Int?
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

    enum CodingKeys: String, CodingKey {
        case id, streamType, codec, language, languageCode, languageTag
        case channels, bitrate, title, selected
        case isDefault = "default"
        case forced, format, key, displayTitle
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
            && lhs.streamType == rhs.streamType
            && lhs.codec == rhs.codec
            && lhs.language == rhs.language
            && lhs.displayTitle == rhs.displayTitle
            && lhs.channels == rhs.channels
            && lhs.bitrate == rhs.bitrate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(streamType)
        hasher.combine(codec)
        hasher.combine(language)
        hasher.combine(displayTitle)
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
    let key: String?
    let type: String?
    let title: String?
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
