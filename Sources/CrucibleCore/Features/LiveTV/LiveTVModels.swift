import Foundation

/// Where a channel comes from: Plex's own free channels, a tuner the viewer's Plex server records with, or a playlist the
/// viewer added.
package enum LiveSourceKind: String, Codable, Sendable, CaseIterable {
    case plexFree
    case plexDVR
    case playlist
}

/// One source of channels, named by its kind and a key unique within it: `plex` for the free channels, the server's
/// machine identifier and DVR key for a tuner, a playlist's id.
package struct LiveSourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    package let kind: LiveSourceKind
    package let key: String

    package init(kind: LiveSourceKind, key: String) {
        self.kind = kind
        self.key = key
    }

    package static let plexFree = LiveSourceID(kind: .plexFree, key: "plex")

    package var description: String { "\(kind.rawValue):\(key)" }
}

/// How a channel's picture is reached.
package enum LiveStream: Hashable, Codable, Sendable {
    /// An address from a playlist, which may be HLS or a bare MPEG transport stream, with the user agent and referrer the
    /// playlist asks for.
    case address(URL, userAgent: String?, referrer: String?)
    /// A free Plex channel: the part's path on Plex's live TV service, an HLS playlist.
    case plexFree(partKey: String)
    /// A channel of a tuner on the viewer's Plex server, which the server tunes when asked.
    case plexDVR(dvrKey: String, channel: String)
}

/// A channel in the guide.
package struct LiveChannel: Hashable, Codable, Sendable, Identifiable {
    package let id: String
    package let source: LiveSourceID
    /// The number shown beside the name (a virtual channel number, `tvg-chno`), when the source has one.
    package let number: String?
    package let title: String
    package let logo: URL?
    /// The groups or genres the source files the channel under.
    package let groups: [String]
    package let isHD: Bool
    /// The key the guide data knows the channel by (a Plex grid key, an XMLTV channel id).
    package let guideKey: String?
    package let stream: LiveStream
    package let summary: String?

    package init(id: String, source: LiveSourceID, number: String? = nil, title: String, logo: URL? = nil, groups: [String] = [],
                 isHD: Bool = false, guideKey: String? = nil, stream: LiveStream, summary: String? = nil) {
        self.id = id
        self.source = source
        self.number = number
        self.title = title
        self.logo = logo
        self.groups = groups
        self.isHD = isHD
        self.guideKey = guideKey
        self.stream = stream
        self.summary = summary
    }

    /// The name with its number in front, the way a channel banner reads.
    package var numberedTitle: String {
        guard let number, !number.isEmpty else { return title }
        return "\(number)  \(title)"
    }
}

/// What a recording would be made from: the airing's guid, which the server's subscription template takes.
package struct LiveRecordHint: Hashable, Codable, Sendable {
    package let guid: String
    package let isEpisode: Bool

    package init(guid: String, isEpisode: Bool) {
        self.guid = guid
        self.isEpisode = isEpisode
    }
}

/// One airing in the guide.
package struct LiveProgram: Hashable, Codable, Sendable, Identifiable {
    package let id: String
    package let channelID: String
    /// The show or film.
    package let title: String
    /// The episode's own name, when it has one worth showing.
    package let episodeTitle: String?
    package let summary: String?
    package let start: Date
    package let end: Date
    package let image: URL?
    package let season: Int?
    package let episode: Int?
    package let genres: [String]
    package let contentRating: String?
    package let isNew: Bool
    package let isLive: Bool
    package let isPremiere: Bool
    package let record: LiveRecordHint?

    package init(id: String, channelID: String, title: String, episodeTitle: String? = nil, summary: String? = nil, start: Date, end: Date,
                 image: URL? = nil, season: Int? = nil, episode: Int? = nil, genres: [String] = [], contentRating: String? = nil,
                 isNew: Bool = false, isLive: Bool = false, isPremiere: Bool = false, record: LiveRecordHint? = nil) {
        self.id = id
        self.channelID = channelID
        self.title = title
        self.episodeTitle = episodeTitle
        self.summary = summary
        self.start = start
        self.end = end
        self.image = image
        self.season = season
        self.episode = episode
        self.genres = genres
        self.contentRating = contentRating
        self.isNew = isNew
        self.isLive = isLive
        self.isPremiere = isPremiere
        self.record = record
    }

    package var duration: TimeInterval { end.timeIntervalSince(start) }

    package func isOn(at date: Date) -> Bool { start <= date && date < end }

    /// How far through the airing `date` is, from 0 to 1.
    package func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }

    /// "S2 E5", when the airing is a numbered episode.
    package var episodeCode: String? {
        switch (season, episode) {
        case let (season?, episode?): return String(localized: "S\(season) E\(episode)", comment: "Season and episode numbers of an airing in the TV guide, e.g. S2 E5")
        case let (nil, episode?): return String(localized: "E\(episode)", comment: "Episode number of an airing in the TV guide with no season, e.g. E5")
        default: return nil
        }
    }
}

/// What a source has to say about itself in the guide's source list.
package struct LiveSourceSummary: Hashable, Sendable, Identifiable {
    package let id: LiveSourceID
    package let title: String
    package let channelCount: Int
    /// Whether recordings can be scheduled from this source.
    package let records: Bool

    package init(id: LiveSourceID, title: String, channelCount: Int, records: Bool) {
        self.id = id
        self.title = title
        self.channelCount = channelCount
        self.records = records
    }
}

/// A source of channels and their guide.
package protocol LiveChannelSource: Sendable {
    var id: LiveSourceID { get }
    var title: String { get }
    /// Whether recordings can be scheduled from this source.
    var records: Bool { get }
    func channels() async throws -> [LiveChannel]
    /// The airings on `channels` that overlap `window`, by channel id. A channel the source has no guide for is left out.
    func programs(for channels: [LiveChannel], in window: DateInterval) async throws -> [String: [LiveProgram]]
}
