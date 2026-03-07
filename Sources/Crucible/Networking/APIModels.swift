import Foundation

struct MediaSummary: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let mediaType: String
    let year: Int?
    let posterPath: String?
    let posterBlurhash: String?
    let rating: Double?
    let durationSecs: Double?
    let videoWidth: Int?
    let videoHeight: Int?
    let hdrFormat: String?
    let showName: String?
    let showId: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeTitle: String?
}

struct MediaItem: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let mediaType: String
    let year: Int?
    let fileSize: Int64
    let durationSecs: Double?
    let videoCodec: String?
    let videoWidth: Int?
    let videoHeight: Int?
    let hdrFormat: String?
    let audioCodec: String?
    let audioChannels: Int?
    let showName: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeTitle: String?
    let tmdbId: Int64?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let posterBlurhash: String?
    let genres: [String]?
    let rating: Double?
    let releaseDate: String?
    let addedAt: String
    let updatedAt: String
}

struct TvShowSummary: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let posterPath: String?
    let posterBlurhash: String?
    let rating: Double?
    let firstAirDate: String?
    let seasonCount: Int
    let episodeCount: Int
    let watchedCount: Int
}

struct TvShow: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let tmdbId: Int64?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let posterBlurhash: String?
    let genres: [String]?
    let rating: Double?
    let firstAirDate: String?
    let addedAt: String
}

struct EpisodeSummary: Codable, Hashable, Sendable {
    let id: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeTitle: String?
    let durationSecs: Double?
    let isWatched: Bool
    let positionSecs: Double
}

struct SeasonSummary: Codable, Hashable, Sendable {
    let seasonNumber: Int
    let episodeCount: Int
    let watchedCount: Int
}

struct PlaybackState: Codable, Hashable, Sendable {
    let mediaId: String
    let positionSecs: Double
    let isWatched: Bool
    let lastPlayedAt: String?
}

struct Subtitle: Codable, Hashable, Sendable {
    let id: String
    let mediaId: String
    let streamIndex: Int?
    let language: String?
    let codec: String?
    let isForced: Bool
    let isDefault: Bool
    let isExternal: Bool

    var isBitmap: Bool {
        guard let codec else { return false }
        let bitmapCodecs = ["dvd_subtitle", "hdmv_pgs_subtitle", "pgssub", "vobsub", "dvb_subtitle"]
        return bitmapCodecs.contains(codec)
    }
}

struct AudioTrack: Codable, Hashable, Sendable {
    let id: String
    let mediaId: String
    let streamIndex: Int
    let codec: String
    let language: String?
    let channels: Int?
    let bitrate: Int64?
    let isDefault: Bool
    let title: String?

    var channelDescription: String {
        Formatters.channelDescription(channels)
    }
}

struct StreamInfo: Codable, Sendable {
    let id: String
    let videoCodec: String?
    let audioCodec: String?
    let videoWidth: Int?
    let videoHeight: Int?
    let hdrFormat: String?
    let durationSecs: Double?
    let fileSize: Int64
    let needsTranscode: Bool
    let canDirectPlay: Bool
    let subtitles: [Subtitle]
    let audioTracks: [AudioTrack]
    let spritesVtt: String
}

struct MediaDetailResponse: Codable, Sendable {
    let item: MediaItem
    let subtitles: [Subtitle]
    let playback: PlaybackState?
    let audioTracks: [AudioTrack]
}

struct ShowDetailResponse: Codable, Sendable {
    let show: TvShow
    let seasons: [SeasonSummary]
}

struct ContinueWatchingItem: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let mediaType: String
    let posterPath: String?
    let posterBlurhash: String?
    let durationSecs: Double?
    let positionSecs: Double
    let progressPercent: Double?
    let lastPlayedAt: String
    let showName: String?
    let showId: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeTitle: String?
}

struct ContinueWatchingResponse: Codable, Sendable {
    let items: [ContinueWatchingItem]
    let total: Int64
}

struct OnDeckItem: Codable, Hashable, Sendable {
    let showId: String
    let showName: String
    let posterPath: String?
    let posterBlurhash: String?
    let episodeId: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeTitle: String?
    let durationSecs: Double?
    let positionSecs: Double
}

struct PaginatedResponse<T: Codable & Hashable & Sendable>: Codable, Sendable {
    let items: [T]
    let total: Int64
    let page: Int
    let perPage: Int
    let totalPages: Int
}

struct SearchResult: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let mediaType: String
    let year: Int?
    let posterPath: String?
    let posterBlurhash: String?
    let rating: Double?
    let durationSecs: Double?
    let videoWidth: Int?
    let videoHeight: Int?
    let hdrFormat: String?
    let showName: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeTitle: String?
}

struct HlsStatusResponse: Codable, Sendable {
    let status: String
    let progress: Float?
    let error: String?
}

struct StatsResponse: Codable, Sendable {
    let movies: Int64
    let episodes: Int64
    let shows: Int64
    let totalSizeBytes: Int64
    let totalDurationSecs: Double
}

struct HealthResponse: Codable, Sendable {
    let status: String
    let version: String
}

struct ScanStatusResponse: Codable, Sendable {
    let status: String
    let isRunning: Bool
    let startedAt: String?
    let itemsFound: Int?
    let lastCompletedAt: String?
    let lastError: String?
}

struct SystemConfigResponse: Codable, Sendable {
    let server: ServerConfig
    let library: LibraryConfig
    let transcoding: TranscodingConfig
    let tmdb: TmdbConfig

    struct ServerConfig: Codable, Sendable {
        let host: String
        let port: Int
    }

    struct LibraryConfig: Codable, Sendable {
        let mediaDirs: [String]
        let scanIntervalSecs: Int
    }

    struct TranscodingConfig: Codable, Sendable {
        let hlsSegmentDuration: Int
        let maxConcurrentTranscodes: Int
        let cacheDir: String
    }

    struct TmdbConfig: Codable, Sendable {
        let hasApiKey: Bool
        let language: String
    }
}

struct HistoryEntry: Codable, Hashable, Sendable {
    let id: Int64
    let mediaId: String
    let eventType: String
    let positionSecs: Double
    let createdAt: String
    let title: String?
    let mediaType: String?
}

struct HistoryResponse: Codable, Sendable {
    let entries: [HistoryEntry]
    let total: Int64
    let limit: Int
    let offset: Int
}

struct UpdatePlaybackRequest: Codable, Sendable {
    let positionSecs: Double
    let event: String?
}

struct HlsPrepareRequest: Codable, Sendable {
    let audioTrackId: String?
    let startSecs: Double?
}

struct BatchUpdateResponse: Codable, Sendable {
    let updated: Int
}
