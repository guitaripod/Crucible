import Foundation

/// What Plex's live TV answers, from its free channel service and from a server's DVR alike. Plex sends many numbers and
/// flags as strings in one place and as numbers in another, so everything is read leniently.
struct PlexLiveContainer<Body: Decodable & Sendable>: Decodable, Sendable {
    let MediaContainer: Body
}

struct PlexLiveProviderBody: Decodable, Sendable {
    struct Provider: Decodable, Sendable {
        struct FeatureEntry: Decodable, Sendable {
            struct FilterEntry: Decodable, Sendable {
                let identifier: String?
                let title: String?
                let genreRatingKey: String?
            }

            let type: String?
            let GridChannelFilter: [FilterEntry]?
        }

        let title: String?
        let Feature: [FeatureEntry]?
    }

    let MediaProvider: Provider?
}

/// The provider's root answers `{"MediaProvider": …}` with no container around it.
struct PlexLiveProviderRoot: Decodable, Sendable {
    let MediaProvider: PlexLiveProviderBody.Provider?
}

struct PlexLiveChannelsBody: Decodable, Sendable {
    let Channel: [PlexLiveChannel]?
}

struct PlexLiveChannel: Decodable, Sendable {
    struct MediaEntry: Decodable, Sendable {
        struct PartEntry: Decodable, Sendable {
            let key: String?
        }

        let `protocol`: String?
        let drm: Bool?
        let Part: [PartEntry]?
    }

    let id: String?
    let gridKey: String?
    let title: String?
    let callSign: String?
    let vcn: String?
    let thumb: String?
    let summary: String?
    let isHd: Bool
    let hidden: Bool
    let genreRatingKeys: [String]?
    let Media: [MediaEntry]?

    enum CodingKeys: String, CodingKey {
        case id, gridKey, title, callSign, vcn, thumb, summary, isHd, hidden, genreRatingKeys, Media
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = PlexLiveLenient.string(container, .id)
        gridKey = PlexLiveLenient.string(container, .gridKey)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        callSign = try container.decodeIfPresent(String.self, forKey: .callSign)
        vcn = PlexLiveLenient.string(container, .vcn)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        isHd = PlexLiveLenient.bool(container, .isHd)
        hidden = PlexLiveLenient.bool(container, .hidden)
        genreRatingKeys = try? container.decodeIfPresent([String].self, forKey: .genreRatingKeys)
        Media = try? container.decodeIfPresent([MediaEntry].self, forKey: .Media)
    }
}

struct PlexLiveGridBody: Decodable, Sendable {
    let Metadata: [PlexLiveAiring]?
}

struct PlexLiveAiring: Decodable, Sendable {
    struct MediaEntry: Decodable, Sendable {
        let beginsAt: Int?
        let endsAt: Int?
        let onAir: Bool
        let premiere: Bool
        let channelIdentifier: String?
        let channelTitle: String?
        let channelVcn: String?
        let channelThumb: String?

        enum CodingKeys: String, CodingKey {
            case beginsAt, endsAt, onAir, premiere, channelIdentifier, channelTitle, channelVcn, channelThumb
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            beginsAt = PlexNumber.decode(container, .beginsAt, Int.self)
            endsAt = PlexNumber.decode(container, .endsAt, Int.self)
            onAir = PlexLiveLenient.bool(container, .onAir)
            premiere = PlexLiveLenient.bool(container, .premiere)
            channelIdentifier = PlexLiveLenient.string(container, .channelIdentifier)
            channelTitle = try container.decodeIfPresent(String.self, forKey: .channelTitle)
            channelVcn = PlexLiveLenient.string(container, .channelVcn)
            channelThumb = try container.decodeIfPresent(String.self, forKey: .channelThumb)
        }
    }

    struct TagEntry: Decodable, Sendable {
        let tag: String?
    }

    struct ImageEntry: Decodable, Sendable {
        let type: String?
        let url: String?
    }

    let guid: String?
    let ratingKey: String?
    let key: String?
    let type: String?
    let title: String?
    let grandparentTitle: String?
    let parentIndex: Int?
    let index: Int?
    let summary: String?
    let contentRating: String?
    let thumb: String?
    let art: String?
    let grandparentThumb: String?
    let grandparentArt: String?
    let hasGenericTitle: Bool
    let Genre: [TagEntry]?
    let Image: [ImageEntry]?
    let Media: [MediaEntry]?

    enum CodingKeys: String, CodingKey {
        case guid, ratingKey, key, type, title, grandparentTitle, parentIndex, index, summary, contentRating, thumb, art, grandparentThumb, grandparentArt,
             hasGenericTitle, Genre, Image, Media
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guid = try container.decodeIfPresent(String.self, forKey: .guid)
        ratingKey = PlexLiveLenient.string(container, .ratingKey)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        grandparentTitle = try container.decodeIfPresent(String.self, forKey: .grandparentTitle)
        parentIndex = PlexNumber.decode(container, .parentIndex, Int.self)
        index = PlexNumber.decode(container, .index, Int.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        contentRating = try container.decodeIfPresent(String.self, forKey: .contentRating)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        art = try container.decodeIfPresent(String.self, forKey: .art)
        grandparentThumb = try container.decodeIfPresent(String.self, forKey: .grandparentThumb)
        grandparentArt = try container.decodeIfPresent(String.self, forKey: .grandparentArt)
        hasGenericTitle = PlexLiveLenient.bool(container, .hasGenericTitle)
        Genre = try? container.decodeIfPresent([TagEntry].self, forKey: .Genre)
        Image = try? container.decodeIfPresent([ImageEntry].self, forKey: .Image)
        Media = try? container.decodeIfPresent([MediaEntry].self, forKey: .Media)
    }

    /// The airings of this title as the guide shows them on `channelID`, one per `Media` entry (a film shown twice in a day
    /// is one title with two): the show's name as the title and the episode's own name beside it unless Plex marks it
    /// generic ("Episode 1"). `imageBase` makes relative artwork paths absolute.
    func programs(channelID: String, imageBase: URL?) -> [LiveProgram] {
        let isEpisode = type == "episode"
        guard let showTitle = isEpisode ? (grandparentTitle ?? title) : title, !showTitle.isEmpty else { return [] }
        let episodeTitle = isEpisode && !hasGenericTitle && title != showTitle ? title : nil
        let picture = Image?.first { $0.type == "snapshot" || $0.type == "coverArt" }?.url ?? art ?? thumb ?? grandparentArt ?? grandparentThumb
        let image = picture.flatMap { PlexLiveLenient.url($0, base: imageBase) }
        return (Media ?? []).compactMap { media in
            guard let begins = media.beginsAt, let ends = media.endsAt, ends > begins else { return nil }
            return LiveProgram(id: "\(channelID)@\(begins)", channelID: channelID, title: showTitle, episodeTitle: episodeTitle, summary: summary,
                               start: Date(timeIntervalSince1970: TimeInterval(begins)), end: Date(timeIntervalSince1970: TimeInterval(ends)),
                               image: image, season: isEpisode && (parentIndex ?? 0) > 0 && !hasGenericTitle ? parentIndex : nil,
                               episode: isEpisode && !hasGenericTitle ? index : nil,
                               genres: Genre?.compactMap(\.tag) ?? [], contentRating: contentRating,
                               isNew: false, isLive: media.onAir, isPremiere: media.premiere,
                               record: guid.map { LiveRecordHint(guid: $0, isEpisode: isEpisode) })
        }
    }

    /// The first airing, for a recording's details.
    func program(channelID: String, imageBase: URL?) -> LiveProgram? {
        programs(channelID: channelID, imageBase: imageBase).first
    }
}

enum PlexLiveLenient {
    static func string<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> String? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? container.decodeIfPresent(Int.self, forKey: key) { return String(number) }
        if let number = try? container.decodeIfPresent(Double.self, forKey: key) { return String(number) }
        return nil
    }

    static func bool<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> Bool {
        if let flag = try? container.decodeIfPresent(Bool.self, forKey: key) { return flag }
        if let number = try? container.decodeIfPresent(Int.self, forKey: key) { return number != 0 }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text == "1" || text.lowercased() == "true" }
        return false
    }

    /// An absolute URL as is, a path against `base`.
    static func url(_ text: String, base: URL?) -> URL? {
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return URL(string: text) }
        guard let base else { return nil }
        return URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (text.hasPrefix("/") ? text : "/" + text))
    }

    /// Dates as Plex's grid takes them: `YYYY-MM-DD` in UTC.
    static func gridDates(covering window: DateInterval) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var dates: [String] = []
        var day = calendar.startOfDay(for: window.start)
        while day < window.end {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            dates.append(String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return dates
    }
}
