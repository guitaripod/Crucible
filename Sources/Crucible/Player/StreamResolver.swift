import Foundation

struct ResolvedStream: Sendable {
    let url: URL
    let isDirectPlay: Bool
    let sessionId: String
    let subtitles: [PlexStream]
    let audioTracks: [PlexStream]
}

enum StreamResolverError: Error, LocalizedError {
    case noMediaFound
    case noConnectionURL

    var errorDescription: String? {
        switch self {
        case .noMediaFound: return "No playable media found"
        case .noConnectionURL: return "Could not build stream URL"
        }
    }
}

enum StreamResolver {
    static func resolve(
        api: APIClient,
        ratingKey: String,
        startSecs: Double?
    ) async throws -> ResolvedStream {
        let container = try await api.requestContainer(.metadata(ratingKey: ratingKey))
        guard let metadata = container.Metadata?.first,
              let media = metadata.Media?.first,
              let part = media.Part?.first else {
            throw StreamResolverError.noMediaFound
        }

        let sessionId = UUID().uuidString
        let baseURL = api.baseURL
        let token = api.token

        let subtitles = part.Stream?.filter { $0.streamType == 3 } ?? []
        let audioTracks = part.Stream?.filter { $0.streamType == 2 } ?? []

        guard let url = transcodeURL(baseURL: baseURL, token: token, ratingKey: ratingKey, session: sessionId, startSecs: startSecs) else {
            throw StreamResolverError.noConnectionURL
        }

        return ResolvedStream(
            url: url,
            isDirectPlay: false,
            sessionId: sessionId,
            subtitles: subtitles,
            audioTracks: audioTracks
        )
    }

    private static func transcodeURL(baseURL: URL, token: String, ratingKey: String, session: String, startSecs: Double?) -> URL? {
        var query = "path=/library/metadata/\(ratingKey)"
            + "&mediaIndex=0&partIndex=0&protocol=hls"
            + "&fastSeek=1&directPlay=0&directStream=1"
            + "&session=\(session)"
            + "&subtitleSize=100&audioBoost=100"
            + "&location=lan&autoAdjustQuality=0"
            + "&X-Plex-Token=\(token)"
            + "&X-Plex-Client-Identifier=\(PlexHeaders.clientIdentifier)"
            + "&X-Plex-Platform=iOS"
            + "&X-Plex-Product=Crucible"
        if let secs = startSecs {
            query += "&offset=\(Int(secs))"
        }
        return plexURL(base: baseURL, path: "/video/:/transcode/universal/start.m3u8", query: query)
    }

    private static func plexURL(base: URL, path: String, query: String) -> URL? {
        let urlString = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path + "?" + query
        return URL(string: urlString)
    }
}
