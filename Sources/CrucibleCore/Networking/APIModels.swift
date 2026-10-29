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
package struct PlexHistoryResponse: Decodable, Sendable {
    package let MediaContainer: Container

    package struct Container: Decodable, Sendable {
        package let totalSize: Int?
        package let Metadata: [PlexHistoryEntry]?

        enum CodingKeys: String, CodingKey { case totalSize, Metadata }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            totalSize = (try? c.decodeIfPresent(Int.self, forKey: .totalSize)) ?? nil
            Metadata = (try? c.decodeIfPresent([PlexHistoryEntry].self, forKey: .Metadata)) ?? nil
        }
    }
}

package struct PlexHistoryEntry: Decodable, Sendable {
    package let ratingKey: String?
    package let type: String?
    package let title: String?
    package let grandparentTitle: String?
    package let grandparentRatingKey: String?
    package let grandparentThumb: String?
    package let thumb: String?
    package let parentIndex: Int?
    package let index: Int?
    package let viewedAt: Int?
    package let librarySectionID: Int?
    package let librarySectionTitle: String?
    package let accountID: Int?
    package let deviceID: Int?

    enum CodingKeys: String, CodingKey {
        case ratingKey, type, title, grandparentTitle, grandparentRatingKey, grandparentThumb, thumb
        case parentIndex, index, viewedAt, librarySectionID, librarySectionTitle, accountID, deviceID
    }

    package init(from decoder: Decoder) throws {
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

package struct PlexMediaContainer: Decodable, Sendable {
    package let size: Int?
    package let totalSize: Int?
    package let offset: Int?
    package let title1: String?
    package let title2: String?
    let viewGroup: String?
    package let librarySectionID: Int?
    package let librarySectionTitle: String?
    package let Metadata: [PlexMetadata]?
    package let Hub: [PlexHub]?
    package let Directory: [PlexDirectory]?

    enum CodingKeys: String, CodingKey {
        case size, totalSize, offset, title1, title2, viewGroup
        case librarySectionID, librarySectionTitle
        case Metadata, Hub, Directory
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        totalSize = try container.decodeIfPresent(Int.self, forKey: .totalSize)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset)
        title1 = try container.decodeIfPresent(String.self, forKey: .title1)
        title2 = try container.decodeIfPresent(String.self, forKey: .title2)
        viewGroup = try container.decodeIfPresent(String.self, forKey: .viewGroup)
        librarySectionID = PlexNumber.decode(container, .librarySectionID, Int.self)
        librarySectionTitle = try container.decodeIfPresent(String.self, forKey: .librarySectionTitle)
        Metadata = try container.decodeIfPresent([PlexMetadata].self, forKey: .Metadata)
        Hub = try container.decodeIfPresent([PlexHub].self, forKey: .Hub)
        Directory = try container.decodeIfPresent([PlexDirectory].self, forKey: .Directory)
    }
}

package struct PlexMetadata: Decodable, Sendable {
    package let ratingKey: String?
    package let key: String?
    package let type: String?
    package let title: String
    package let grandparentTitle: String?
    package let grandparentRatingKey: String?
    package let grandparentThumb: String?
    package let grandparentArt: String?
    package let parentTitle: String?
    package let parentRatingKey: String?
    package let parentThumb: String?
    package let parentIndex: Int?
    package let index: Int?
    package let year: Int?
    package let summary: String?
    package let tagline: String?
    package let contentRating: String?
    package let studio: String?
    package let rating: Double?
    package let audienceRating: Double?
    package let duration: Int?
    package let viewOffset: Int?
    package let viewCount: Int?
    package let lastViewedAt: Int?
    package let viewedAt: Int?
    package let accountID: Int?
    package let deviceID: Int?
    package let addedAt: Int?
    package let originallyAvailableAt: String?
    package let thumb: String?
    package let art: String?
    package let leafCount: Int?
    package let viewedLeafCount: Int?
    package let childCount: Int?
    package let librarySectionID: Int?
    package let librarySectionTitle: String?
    package let Genre: [PlexTag]?
    package let Role: [PlexRole]?
    package let Director: [PlexTag]?
    package let Writer: [PlexTag]?
    package let Media: [PlexMedia]?
    package let Marker: [PlexMarker]?
    package let Related: PlexRelatedHubs?

    package init(
        ratingKey: String?,
        key: String?,
        type: String?,
        title: String,
        grandparentTitle: String?,
        grandparentRatingKey: String?,
        grandparentThumb: String?,
        grandparentArt: String?,
        parentTitle: String?,
        parentRatingKey: String?,
        parentThumb: String?,
        parentIndex: Int?,
        index: Int?,
        year: Int?,
        summary: String?,
        tagline: String?,
        contentRating: String?,
        studio: String?,
        rating: Double?,
        audienceRating: Double?,
        duration: Int?,
        viewOffset: Int?,
        viewCount: Int?,
        lastViewedAt: Int?,
        viewedAt: Int?,
        accountID: Int?,
        deviceID: Int?,
        addedAt: Int?,
        originallyAvailableAt: String?,
        thumb: String?,
        art: String?,
        leafCount: Int?,
        viewedLeafCount: Int?,
        childCount: Int?,
        librarySectionID: Int?,
        librarySectionTitle: String?,
        Genre: [PlexTag]?,
        Role: [PlexRole]?,
        Director: [PlexTag]?,
        Writer: [PlexTag]?,
        Media: [PlexMedia]?,
        Marker: [PlexMarker]?,
        Related: PlexRelatedHubs?
    ) {
        self.ratingKey = ratingKey
        self.key = key
        self.type = type
        self.title = title
        self.grandparentTitle = grandparentTitle
        self.grandparentRatingKey = grandparentRatingKey
        self.grandparentThumb = grandparentThumb
        self.grandparentArt = grandparentArt
        self.parentTitle = parentTitle
        self.parentRatingKey = parentRatingKey
        self.parentThumb = parentThumb
        self.parentIndex = parentIndex
        self.index = index
        self.year = year
        self.summary = summary
        self.tagline = tagline
        self.contentRating = contentRating
        self.studio = studio
        self.rating = rating
        self.audienceRating = audienceRating
        self.duration = duration
        self.viewOffset = viewOffset
        self.viewCount = viewCount
        self.lastViewedAt = lastViewedAt
        self.viewedAt = viewedAt
        self.accountID = accountID
        self.deviceID = deviceID
        self.addedAt = addedAt
        self.originallyAvailableAt = originallyAvailableAt
        self.thumb = thumb
        self.art = art
        self.leafCount = leafCount
        self.viewedLeafCount = viewedLeafCount
        self.childCount = childCount
        self.librarySectionID = librarySectionID
        self.librarySectionTitle = librarySectionTitle
        self.Genre = Genre
        self.Role = Role
        self.Director = Director
        self.Writer = Writer
        self.Media = Media
        self.Marker = Marker
        self.Related = Related
    }

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

    /// The server spells ids and counts as numbers on a library listing and as strings on a history row, and one field it
    /// wrote differently used to cost the whole screen, so every scalar decodes leniently here.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? {
            (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil
        }
        func number<T: Decodable & LosslessStringConvertible>(_ key: CodingKeys, _ type: T.Type) -> T? {
            PlexNumber.decode(container, key, type)
        }
        func list<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? container.decodeIfPresent(type, forKey: key)) ?? nil
        }
        self.init(
            ratingKey: string(.ratingKey),
            key: string(.key),
            type: string(.type),
            title: string(.title) ?? "",
            grandparentTitle: string(.grandparentTitle),
            grandparentRatingKey: string(.grandparentRatingKey),
            grandparentThumb: string(.grandparentThumb),
            grandparentArt: string(.grandparentArt),
            parentTitle: string(.parentTitle),
            parentRatingKey: string(.parentRatingKey),
            parentThumb: string(.parentThumb),
            parentIndex: number(.parentIndex, Int.self),
            index: number(.index, Int.self),
            year: number(.year, Int.self),
            summary: string(.summary),
            tagline: string(.tagline),
            contentRating: string(.contentRating),
            studio: string(.studio),
            rating: number(.rating, Double.self),
            audienceRating: number(.audienceRating, Double.self),
            duration: number(.duration, Int.self),
            viewOffset: number(.viewOffset, Int.self),
            viewCount: number(.viewCount, Int.self),
            lastViewedAt: number(.lastViewedAt, Int.self),
            viewedAt: number(.viewedAt, Int.self),
            accountID: number(.accountID, Int.self),
            deviceID: number(.deviceID, Int.self),
            addedAt: number(.addedAt, Int.self),
            originallyAvailableAt: string(.originallyAvailableAt),
            thumb: string(.thumb),
            art: string(.art),
            leafCount: number(.leafCount, Int.self),
            viewedLeafCount: number(.viewedLeafCount, Int.self),
            childCount: number(.childCount, Int.self),
            librarySectionID: number(.librarySectionID, Int.self),
            librarySectionTitle: string(.librarySectionTitle),
            Genre: list([PlexTag].self, .Genre),
            Role: list([PlexRole].self, .Role),
            Director: list([PlexTag].self, .Director),
            Writer: list([PlexTag].self, .Writer),
            Media: list([PlexMedia].self, .Media),
            Marker: list([PlexMarker].self, .Marker),
            Related: list(PlexRelatedHubs.self, .Related)
        )
    }
}

/// Reads a value the server may send either as a JSON number or as a string holding one.
package enum PlexNumber {
    package static func decode<Key: CodingKey, T: Decodable & LosslessStringConvertible>(
        _ container: KeyedDecodingContainer<Key>,
        _ key: Key,
        _ type: T.Type
    ) -> T? {
        if let value = try? container.decodeIfPresent(T.self, forKey: key) { return value }
        guard let text = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return T(text)
    }
}

extension PlexMetadata {
    package init(homeCard card: HomeCardSnapshot) {
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
            librarySectionID: card.librarySectionID,
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

    /// Lifts a `/status/sessions/history/all` row into the metadata shape the poster cells consume.
    /// History rows carry no runtime or rating data, and a row only exists once the server recorded
    /// a view, so `viewCount` is seeded to 1.
    package init(historyEntry entry: PlexHistoryEntry) {
        self.init(
            ratingKey: entry.ratingKey,
            key: nil,
            type: entry.type,
            title: entry.title ?? "",
            grandparentTitle: entry.grandparentTitle,
            grandparentRatingKey: entry.grandparentRatingKey,
            grandparentThumb: entry.grandparentThumb,
            grandparentArt: nil,
            parentTitle: nil,
            parentRatingKey: nil,
            parentThumb: nil,
            parentIndex: entry.parentIndex,
            index: entry.index,
            year: nil,
            summary: nil,
            tagline: nil,
            contentRating: nil,
            studio: nil,
            rating: nil,
            audienceRating: nil,
            duration: nil,
            viewOffset: nil,
            viewCount: 1,
            lastViewedAt: entry.viewedAt,
            viewedAt: entry.viewedAt,
            accountID: entry.accountID,
            deviceID: entry.deviceID,
            addedAt: nil,
            originallyAvailableAt: nil,
            thumb: entry.thumb,
            art: nil,
            leafCount: nil,
            viewedLeafCount: nil,
            childCount: nil,
            librarySectionID: entry.librarySectionID,
            librarySectionTitle: entry.librarySectionTitle,
            Genre: nil,
            Role: nil,
            Director: nil,
            Writer: nil,
            Media: nil,
            Marker: nil,
            Related: nil
        )
    }

    package func homeCard(bucket: String) -> HomeCardSnapshot {
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
            bucket: bucket,
            librarySectionID: librarySectionID
        )
    }
}

package struct PlexMarker: Decodable, Sendable {
    package let type: String?
    package let startTimeOffset: Int?
    package let endTimeOffset: Int?
    package let final: Bool?

    package init(type: String?, startTimeOffset: Int?, endTimeOffset: Int?, final: Bool?) {
        self.type = type
        self.startTimeOffset = startTimeOffset
        self.endTimeOffset = endTimeOffset
        self.final = final
    }

    var isIntro: Bool { type == "intro" }
    package var isCredits: Bool { type == "credits" }
    package var startSecs: Double { Double(startTimeOffset ?? 0) / 1000.0 }
    package var endSecs: Double { Double(endTimeOffset ?? 0) / 1000.0 }
}

package struct PlexRole: Decodable, Sendable, Hashable {
    package let id: Int?
    package let tag: String?
    package let role: String?
    package let thumb: String?

    package init(id: Int?, tag: String?, role: String?, thumb: String?) {
        self.id = id
        self.tag = tag
        self.role = role
        self.thumb = thumb
    }
}

package struct PlexRelatedHubs: Decodable, Sendable {
    package let Hub: [PlexHub]?
}

extension PlexMetadata: Hashable {
    package static func == (lhs: PlexMetadata, rhs: PlexMetadata) -> Bool {
        lhs.hashId == rhs.hashId
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(hashId)
    }

    private var hashId: String {
        ratingKey ?? key ?? title
    }
}

extension PlexMetadata {
    package var durationSecs: Double {
        Double(duration ?? 0) / 1000.0
    }

    package var positionSecs: Double {
        Double(viewOffset ?? 0) / 1000.0
    }

    package var isWatched: Bool {
        (viewCount ?? 0) > 0
    }

    package var progressPercent: Double {
        guard let offset = viewOffset, let dur = duration, dur > 0 else { return 0 }
        return Double(offset) / Double(dur)
    }

    /// Where playback resumes: zero for an item already watched, whose offset is where the last watching
    /// stopped rather than a place to continue from.
    package var resumeSecs: Double { isWatched ? 0 : positionSecs }

    /// How much of the item is left to watch, for a progress bar: nothing for one already watched.
    package var progressFraction: Double { isWatched ? 0 : progressPercent }

    /// Whether the server holds a place worth returning to: a started item that is not yet watched and has
    /// not reached the watched threshold.
    package var isResumable: Bool {
        guard resumeSecs > 0 else { return false }
        guard durationSecs > 0 else { return true }
        return positionSecs / durationSecs < WatchedRule.threshold
    }

    /// Where a Continue Watching card resumes; a title at the end starts over.
    package var continueSecs: Double { isResumable ? positionSecs : 0 }

    package var id: String { ratingKey ?? key ?? "" }
    package var mediaType: String { type ?? "unknown" }

    package var posterPath: String? { thumb }
    var backdropPath: String? { art }
    package var showName: String? { grandparentTitle }
    package var showRatingKey: String? { grandparentRatingKey }
    package var seasonNumber: Int? { parentIndex }
    package var episodeNumber: Int? { index }

    package var videoWidth: Int? { Media?.first?.width }
    package var videoHeight: Int? { Media?.first?.height }
    package var videoCodec: String? { Media?.first?.videoCodec }
    var audioCodec: String? { Media?.first?.audioCodec }
    var audioChannels: Int? { Media?.first?.audioChannels }
    var videoResolution: String? { Media?.first?.videoResolution }
    package var fileSize: Int64? { Media?.first?.Part?.first?.size }

    package var subtitleStreams: [PlexStream] {
        Media?.first?.Part?.first?.Stream?.filter { $0.streamType == 3 } ?? []
    }

    package var audioStreams: [PlexStream] {
        Media?.first?.Part?.first?.Stream?.filter { $0.streamType == 2 } ?? []
    }

    var directPlayPath: String? {
        Media?.first?.Part?.first?.key
    }

    package var mediaContainer: String? {
        if let container = Media?.first?.container, !container.isEmpty {
            return container.lowercased()
        }
        if let file = Media?.first?.Part?.first?.file,
           let ext = file.split(separator: ".").last {
            return String(ext).lowercased()
        }
        return nil
    }

    package var genres: [String] {
        Genre?.map(\.tag) ?? []
    }

    package var cast: [PlexRole] { Role ?? [] }
    package var directors: [String] { Director?.map(\.tag) ?? [] }
    package var writers: [String] { Writer?.map(\.tag) ?? [] }
    package var relatedHubs: [PlexHub] { (Related?.Hub ?? []).filter { !($0.Metadata?.isEmpty ?? true) } }
    var introMarker: PlexMarker? { Marker?.first { $0.isIntro } }
    var firstCreditsMarker: PlexMarker? { Marker?.first { $0.isCredits } }
}

package struct PlexMedia: Decodable, Sendable {
    package let id: Int?
    package let videoCodec: String?
    let audioCodec: String?
    let videoResolution: String?
    package let width: Int?
    package let height: Int?
    let audioChannels: Int?
    package let bitrate: Int?
    package let videoProfile: String?
    package let container: String?
    package let Part: [PlexPart]?

    enum CodingKeys: String, CodingKey {
        case id, videoCodec, audioCodec, videoResolution
        case width, height, audioChannels, bitrate, videoProfile, container
        case Part
    }
}

package struct PlexPart: Decodable, Sendable {
    package let id: Int
    package let key: String
    package let file: String?
    package let size: Int64?
    package let duration: Int?
    package let Stream: [PlexStream]?

    enum CodingKeys: String, CodingKey {
        case id, key, file, size, duration
        case Stream
    }
}

package struct PlexStream: Decodable, Sendable, Identifiable {
    package let id: Int?
    package let streamType: Int
    package let codec: String?
    package let language: String?
    let languageCode: String?
    let languageTag: String?
    package let channels: Int?
    package let bitrate: Int?
    package let title: String?
    package let selected: Bool?
    package let isDefault: Bool?
    package let forced: Bool?
    package let format: String?
    package let key: String?
    package let displayTitle: String?

    enum CodingKeys: String, CodingKey {
        case id, streamType, codec, language, languageCode, languageTag
        case channels, bitrate, title, selected
        case isDefault = "default"
        case forced, format, key, displayTitle
    }

    package var isBitmap: Bool {
        guard let codec else { return false }
        let bitmapCodecs = ["dvd_subtitle", "hdmv_pgs_subtitle", "pgssub", "vobsub", "dvb_subtitle"]
        return bitmapCodecs.contains(codec)
    }

    var channelDescription: String {
        Formatters.channelDescription(channels)
    }
}

extension PlexStream: Hashable {
    package static func == (lhs: PlexStream, rhs: PlexStream) -> Bool {
        lhs.id == rhs.id
            && lhs.streamType == rhs.streamType
            && lhs.codec == rhs.codec
            && lhs.language == rhs.language
            && lhs.displayTitle == rhs.displayTitle
            && lhs.channels == rhs.channels
            && lhs.bitrate == rhs.bitrate
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(streamType)
        hasher.combine(codec)
        hasher.combine(language)
        hasher.combine(displayTitle)
    }
}

package struct PlexTag: Decodable, Sendable {
    package let tag: String
}

package struct PlexHub: Decodable, Sendable {
    package let type: String?
    package let hubIdentifier: String?
    package let title: String?
    package let size: Int?
    let promoted: Bool?
    package let Metadata: [PlexMetadata]?

    enum CodingKeys: String, CodingKey {
        case type, hubIdentifier, title, size, promoted
        case Metadata
    }
}

package struct PlexDirectory: Decodable, Sendable {
    package let key: String?
    package let type: String?
    package let title: String?
    package let hidden: Int?

    /// Plex marks a library 1 to leave it off Home and 2 to leave it off Home and global search.
    var isHiddenFromHome: Bool { (hidden ?? 0) > 0 }
}

package struct PlexResource: Decodable, Sendable {
    package let name: String
    package let provides: String
    package let clientIdentifier: String
    package let owned: Bool?
    let presence: Bool?
    let lastSeenAt: String?
    package let connections: [PlexResourceConnection]
}

package struct PlexResourceConnection: Decodable, Sendable {
    package let uri: String
    package let address: String?
    package let port: Int?
    let `protocol`: String?
    package let local: Bool?
    package let relay: Bool?
}

package struct PlexPin: Decodable, Sendable {
    package let id: Int
    package let code: String
    package let authToken: String?
    package let expiresIn: Int?
}

package struct PlexIdentity: Decodable, Sendable {
    package let MediaContainer: PlexIdentityContainer

    package struct PlexIdentityContainer: Decodable, Sendable {
        package let machineIdentifier: String?
        package let version: String?
    }
}
