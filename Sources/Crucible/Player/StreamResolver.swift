import Foundation
import os

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
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "playback")
    private static let directPlayContainers: Set<String> = ["mp4", "mov", "m4v"]
    private static let directPlayVideoCodecs: Set<String> = ["h264", "hevc"]
    private static let directPlayAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]

    static func resolve(
        api: APIClient,
        ratingKey: String,
        startSecs: Double?,
        selectedSubtitleId: Int?,
        selectedAudioStreamId: Int?
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

        let defaultAudioId = audioTracks.first(where: { $0.isDefault == true })?.id ?? audioTracks.first?.id
        let wantsBurnedSubtitle = selectedSubtitleId != nil
        let wantsNonDefaultAudio = selectedAudioStreamId != nil && selectedAudioStreamId != defaultAudioId

        if Preferences.streamingQuality == .original,
           !wantsBurnedSubtitle,
           !wantsNonDefaultAudio,
           isDirectPlayable(container: metadata.mediaContainer, videoCodec: media.videoCodec, audioCodec: media.audioCodec),
           let directURL = directPlayURL(baseURL: baseURL, partKey: part.key, token: token) {
            return ResolvedStream(
                url: directURL,
                isDirectPlay: true,
                sessionId: sessionId,
                subtitles: subtitles,
                audioTracks: audioTracks
            )
        }

        if wantsBurnedSubtitle || wantsNonDefaultAudio {
            await applyStreamSelection(
                baseURL: baseURL,
                token: token,
                partId: part.id,
                audioStreamId: wantsNonDefaultAudio ? selectedAudioStreamId : nil,
                subtitleStreamId: wantsBurnedSubtitle ? selectedSubtitleId : nil
            )
        }

        let subtitlesMode = wantsBurnedSubtitle ? "burn" : "auto"

        guard let url = transcodeURL(
            baseURL: baseURL,
            token: token,
            ratingKey: ratingKey,
            session: sessionId,
            startSecs: startSecs,
            subtitlesMode: subtitlesMode
        ) else {
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

    /// Rebuilds the universal-transcoder URL at a new absolute offset, reusing the session (the server re-keys the encode).
    static func transcodeRestartURL(
        api: APIClient,
        ratingKey: String,
        offsetSecs: Double,
        sessionId: String,
        burnSubtitle: Bool
    ) -> URL? {
        transcodeURL(
            baseURL: api.baseURL,
            token: api.token,
            ratingKey: ratingKey,
            session: sessionId,
            startSecs: offsetSecs,
            subtitlesMode: burnSubtitle ? "burn" : "auto"
        )
    }

    private static func isDirectPlayable(container: String?, videoCodec: String?, audioCodec: String?) -> Bool {
        guard let container, directPlayContainers.contains(container) else { return false }
        guard let videoCodec = videoCodec?.lowercased(), directPlayVideoCodecs.contains(videoCodec) else { return false }
        guard let audioCodec = audioCodec?.lowercased(), directPlayAudioCodecs.contains(audioCodec) else { return false }
        return true
    }

    private static func directPlayURL(baseURL: URL, partKey: String, token: String) -> URL? {
        let query = "X-Plex-Token=\(token)&X-Plex-Client-Identifier=\(PlexHeaders.clientIdentifier)"
        return plexURL(base: baseURL, path: partKey, query: query)
    }

    /// Selects audio/subtitle streams server-side before transcoding; only the streams the user actually changed are sent.
    private static func applyStreamSelection(
        baseURL: URL,
        token: String,
        partId: Int,
        audioStreamId: Int?,
        subtitleStreamId: Int?
    ) async {
        var params = ["allParts=1"]
        if let audioStreamId { params.append("audioStreamID=\(audioStreamId)") }
        if let subtitleStreamId { params.append("subtitleStreamID=\(subtitleStreamId)") }
        guard params.count > 1 else { return }
        guard let url = plexURL(base: baseURL, path: "/library/parts/\(partId)", query: params.joined(separator: "&")) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 10
        for (key, value) in PlexHeaders.allHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            log.error("Stream selection PUT failed for part \(partId): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func transcodeURL(
        baseURL: URL,
        token: String,
        ratingKey: String,
        session: String,
        startSecs: Double?,
        subtitlesMode: String
    ) -> URL? {
        var query = "path=/library/metadata/\(ratingKey)"
            + "&mediaIndex=0&partIndex=0&protocol=hls"
            + "&fastSeek=1&directPlay=0&directStream=1&directStreamAudio=1"
            + "&session=\(session)"
            + "&subtitleSize=100&audioBoost=100&subtitles=\(subtitlesMode)"
            + "&location=lan&autoAdjustQuality=0"
            + "&X-Plex-Token=\(token)"
            + "&X-Plex-Client-Identifier=\(PlexHeaders.clientIdentifier)"
            + "&X-Plex-Platform=iOS"
            + "&X-Plex-Product=Crucible"
        if let secs = startSecs {
            query += "&offset=\(Int(secs))"
        }
        if Preferences.streamingQuality != .original {
            query += "&maxVideoBitrate=\(Preferences.streamingQuality.rawValue)&videoQuality=100"
        }
        return plexURL(base: baseURL, path: "/video/:/transcode/universal/start.m3u8", query: query)
    }

    private static func plexURL(base: URL, path: String, query: String) -> URL? {
        let urlString = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path + "?" + query
        return URL(string: urlString)
    }
}
