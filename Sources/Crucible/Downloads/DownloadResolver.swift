import Foundation
import os

enum DownloadResolverError: Error, LocalizedError {
    case noMediaFound
    case noURL

    var errorDescription: String? {
        switch self {
        case .noMediaFound: return "No downloadable media found"
        case .noURL: return "Could not build download URL"
        }
    }
}

/// Plans an offline download. Plex's universal transcoder only produces HLS (single-file `.mp4`
/// transcode returns HTTP 400), so every download is an HLS stream fetched with `AVAssetDownloadTask`
/// into a local `.movpkg`. Quality is controlled by `maxVideoBitrate`; Original keeps source codecs
/// via direct-stream remuxing.
enum DownloadResolver {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "downloads")

    struct Plan: Sendable {
        let url: URL
        let estimatedBytes: Int64
        let durationMs: Int
        let markers: [StoredMarker]
        let initialViewOffsetMs: Int

        let title: String
        let mediaType: String
        let showTitle: String?
        let grandparentRatingKey: String?
        let parentRatingKey: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let year: Int?
        let summary: String?
        let posterPath: String?
    }

    static func plan(api: APIClient, ratingKey: String, quality: DownloadQuality) async throws -> Plan {
        let container = try await api.requestContainer(.metadata(ratingKey: ratingKey))
        guard let metadata = container.Metadata?.first,
              let media = metadata.Media?.first,
              let part = media.Part?.first else {
            throw DownloadResolverError.noMediaFound
        }

        let baseURL = api.baseURL
        let token = api.token
        let durationMs = part.duration ?? metadata.duration ?? 0

        let markers: [StoredMarker] = (metadata.Marker ?? []).compactMap { marker in
            guard let type = marker.type,
                  let start = marker.startTimeOffset,
                  let end = marker.endTimeOffset else { return nil }
            return StoredMarker(type: type, startMs: start, endMs: end)
        }

        let mediaType = metadata.mediaType
        let posterPath: String? = mediaType == "episode"
            ? (metadata.grandparentThumb ?? metadata.thumb)
            : metadata.thumb

        let bitrate = quality.maxVideoBitrate
        let estimatedBytes: Int64
        if let bitrate {
            estimatedBytes = estimateBytes(kbps: bitrate, durationMs: durationMs)
        } else {
            estimatedBytes = part.size ?? estimateBytes(kbps: 12000, durationMs: durationMs)
        }

        guard let url = hlsURL(baseURL: baseURL, ratingKey: ratingKey, token: token, maxVideoBitrate: bitrate) else {
            throw DownloadResolverError.noURL
        }

        log.notice("Planned HLS download \(ratingKey, privacy: .public) quality=\(quality.shortLabel, privacy: .public) bitrate=\(bitrate ?? 0)")

        return Plan(
            url: url,
            estimatedBytes: estimatedBytes,
            durationMs: durationMs,
            markers: markers,
            initialViewOffsetMs: metadata.viewOffset ?? 0,
            title: metadata.title,
            mediaType: mediaType,
            showTitle: metadata.grandparentTitle,
            grandparentRatingKey: metadata.grandparentRatingKey,
            parentRatingKey: metadata.parentRatingKey,
            seasonNumber: metadata.parentIndex,
            episodeNumber: metadata.index,
            year: metadata.year,
            summary: metadata.summary,
            posterPath: posterPath
        )
    }

    static func posterURL(baseURL: URL, token: String, path: String, width: Int, height: Int) -> URL? {
        let baseString = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: baseString + "/photo/:/transcode") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "url", value: path),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]
        return components.url
    }

    private static func estimateBytes(kbps: Int, durationMs: Int) -> Int64 {
        let seconds = Double(durationMs) / 1000.0
        let videoBytes = Double(kbps) * 1000.0 / 8.0 * seconds
        let audioBytes = 192_000.0 / 8.0 * seconds
        return Int64(videoBytes + audioBytes)
    }

    /// Builds the universal-transcoder HLS master-playlist URL. Mirrors the proven streaming format,
    /// minus the playback offset. `maxVideoBitrate == nil` (Original) direct-streams at source quality.
    private static func hlsURL(baseURL: URL, ratingKey: String, token: String, maxVideoBitrate: Int?) -> URL? {
        let session = UUID().uuidString
        var query = "path=/library/metadata/\(ratingKey)"
            + "&mediaIndex=0&partIndex=0&protocol=hls"
            + "&fastSeek=1&directPlay=0&directStream=1&directStreamAudio=1"
            + "&session=\(session)"
            + "&subtitleSize=100&audioBoost=100&subtitles=none"
            + "&location=lan&autoAdjustQuality=0"
            + "&X-Plex-Token=\(token)"
            + "&X-Plex-Client-Identifier=\(PlexHeaders.clientIdentifier)"
            + "&X-Plex-Platform=iOS"
            + "&X-Plex-Product=Crucible"
        if let maxVideoBitrate {
            query += "&maxVideoBitrate=\(maxVideoBitrate)&videoQuality=100"
        }
        let urlString = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/video/:/transcode/universal/start.m3u8?" + query
        return URL(string: urlString)
    }
}
