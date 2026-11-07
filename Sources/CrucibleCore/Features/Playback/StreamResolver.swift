import Foundation
import os

package struct ResolvedStream: Sendable {
    package let url: URL
    package let isDirectPlay: Bool
    package let sessionId: String
    package let subtitles: [PlexStream]
    package let audioTracks: [PlexStream]
    package let markers: [PlexMarker]
    /// Every skippable stretch: Plex's markers, then what the file's chapter names mark.
    package let segments: [SkipMarker]
    /// The file being played, for Stream Info.
    package let media: PlexMedia?
    /// What the server decided about a converted stream, when it said.
    package let decision: PlaybackDecision?
    /// The title's chapters in order, when the file has more than one.
    package let chapters: [PlexChapter]
    /// The subtitle and audio stream this stream was resolved with, including ones picked from remembered languages.
    package let chosenSubtitleId: Int?
    package let chosenAudioStreamId: Int?

    package init(
        url: URL,
        isDirectPlay: Bool,
        sessionId: String,
        subtitles: [PlexStream],
        audioTracks: [PlexStream],
        markers: [PlexMarker],
        media: PlexMedia? = nil,
        decision: PlaybackDecision? = nil,
        chapters: [PlexChapter] = [],
        chosenSubtitleId: Int? = nil,
        chosenAudioStreamId: Int? = nil,
        segments: [SkipMarker]? = nil
    ) {
        self.segments = segments ?? markers.compactMap(SkipMarker.init)
        self.chosenSubtitleId = chosenSubtitleId
        self.chosenAudioStreamId = chosenAudioStreamId
        self.url = url
        self.isDirectPlay = isDirectPlay
        self.sessionId = sessionId
        self.subtitles = subtitles
        self.audioTracks = audioTracks
        self.markers = markers
        self.media = media
        self.decision = decision
        self.chapters = chapters
    }

    /// The same stream restarted under another server session.
    package func restarted(url: URL, sessionId: String) -> ResolvedStream {
        ResolvedStream(
            url: url, isDirectPlay: isDirectPlay, sessionId: sessionId, subtitles: subtitles, audioTracks: audioTracks, markers: markers,
            media: media, decision: decision, chapters: chapters, chosenSubtitleId: chosenSubtitleId, chosenAudioStreamId: chosenAudioStreamId,
            segments: segments
        )
    }
}

package enum StreamResolverError: Error, LocalizedError {
    case noMediaFound
    case noConnectionURL
    /// The server's decision refused the stream; the message says why.
    case refused(String)

    package var errorDescription: String? {
        switch self {
        case .noMediaFound: return String(localized: "No playable media found")
        case .noConnectionURL: return String(localized: "Could not build stream URL")
        case .refused(let message): return message
        }
    }
}

package enum StreamResolver {
    private static let log = Logger(subsystem: "com.guitaripod.crucible", category: "playback")
    private static let directPlayContainers: Set<String> = ["mp4", "mov", "m4v"]
    private static let directPlayVideoCodecs: Set<String> = ["h264", "hevc"]
    private static let directPlayAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac", "flac"]

    /// Resolves how to play `ratingKey`. Streams chosen by id win; with none chosen, `languages` picks this file's streams in
    /// the languages the viewer had before.
    package static func resolve(
        api: APIClient,
        ratingKey: String,
        startSecs: Double?,
        selectedSubtitleId: Int?,
        selectedAudioStreamId: Int?,
        languages: TrackLanguages? = nil,
        forceTranscode: Bool = false
    ) async throws -> ResolvedStream {
        let container = try await api.requestContainer(.metadata(ratingKey: ratingKey))
        guard let metadata = container.Metadata?.first,
              let media = metadata.Media?.first,
              let part = media.Part?.first else {
            throw StreamResolverError.noMediaFound
        }

        let sessionId = UUID().uuidString
        let baseURL = await api.baseURL
        let token = api.token

        let subtitles = part.Stream?.filter { $0.streamType == 3 } ?? []
        let audioTracks = part.Stream?.filter { $0.streamType == 2 } ?? []
        let markers = metadata.Marker ?? []
        let chapters = ChapterList.playable(metadata.Chapter ?? [])
        let segments = SkipSegments.make(markers: markers, chapters: metadata.Chapter ?? [], durationSecs: Double(part.duration ?? metadata.duration ?? 0) / 1000)

        var selectedSubtitleId = selectedSubtitleId
        var selectedAudioStreamId = selectedAudioStreamId
        if selectedSubtitleId == nil, selectedAudioStreamId == nil, let languages {
            (selectedSubtitleId, selectedAudioStreamId) = languages.streamIds(subtitles: subtitles, audioTracks: audioTracks)
        }
        let defaultAudioId = audioTracks.first(where: { $0.isDefault == true })?.id ?? audioTracks.first?.id
        let wantsBurnedSubtitle = selectedSubtitleId != nil
        let wantsNonDefaultAudio = selectedAudioStreamId != nil && selectedAudioStreamId != defaultAudioId

        if !forceTranscode,
           QualityPolicy.current(for: baseURL) == .original,
           !wantsBurnedSubtitle,
           !wantsNonDefaultAudio,
           isDirectPlayable(container: metadata.mediaContainer, videoCodec: media.videoCodec, audioCodec: media.audioCodec),
           let directURL = directPlayURL(baseURL: baseURL, partKey: part.key, token: token) {
            return ResolvedStream(
                url: directURL,
                isDirectPlay: true,
                sessionId: sessionId,
                subtitles: subtitles,
                audioTracks: audioTracks,
                markers: markers,
                media: media,
                chapters: chapters,
                chosenSubtitleId: selectedSubtitleId,
                chosenAudioStreamId: selectedAudioStreamId,
                segments: segments
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

        let decision = await fetchDecision(startURL: url, token: token)
        if let decision, decision.isRefusal {
            log.error("Server refused the stream code=\(decision.generalCode ?? 0) text=\(decision.generalText ?? "", privacy: .public)")
            throw StreamResolverError.refused(PlaybackDecisionCopy.refusalMessage(decision))
        }

        return ResolvedStream(
            url: url,
            isDirectPlay: false,
            sessionId: sessionId,
            subtitles: subtitles,
            audioTracks: audioTracks,
            markers: markers,
            media: media,
            decision: decision,
            chapters: chapters,
            chosenSubtitleId: selectedSubtitleId,
            chosenAudioStreamId: selectedAudioStreamId,
            segments: segments
        )
    }

    /// Asks the server what it would do with the stream about to start, with the very query the stream uses. A server that
    /// does not answer is not a refusal: the stream starts as it always did.
    private static func fetchDecision(startURL: URL, token: String) async -> PlaybackDecision? {
        guard let url = decisionURL(for: startURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        for (key, value) in PlexHeaders.allHeaders(token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return PlaybackDecision.parse(data)
    }

    static func decisionURL(for startURL: URL) -> URL? {
        guard var components = URLComponents(url: startURL, resolvingAgainstBaseURL: false),
              components.path.hasSuffix("/start.m3u8") else { return nil }
        components.path = components.path.replacingOccurrences(of: "/start.m3u8", with: "/decision")
        return components.url
    }

    /// Rebuilds the universal-transcoder URL at a new absolute offset, reusing the session (the server re-keys the encode).
    package static func transcodeRestartURL(
        api: APIClient,
        ratingKey: String,
        offsetSecs: Double,
        sessionId: String,
        burnSubtitle: Bool
    ) async -> URL? {
        transcodeURL(
            baseURL: await api.baseURL,
            token: api.token,
            ratingKey: ratingKey,
            session: sessionId,
            startSecs: offsetSecs,
            subtitlesMode: burnSubtitle ? "burn" : "auto"
        )
    }

    static func isDirectPlayable(container: String?, videoCodec: String?, audioCodec: String?) -> Bool {
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

    static func transcodeURL(
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
            + "&subtitleSize=\(Preferences.subtitleSize.rawValue)&audioBoost=100&subtitles=\(subtitlesMode)"
            + "&location=lan&autoAdjustQuality=0"
            + "&X-Plex-Token=\(token)"
            + "&X-Plex-Client-Identifier=\(PlexHeaders.clientIdentifier)"
            + "&X-Plex-Platform=\(AppPlatform.plexName)"
            + "&X-Plex-Product=Crucible"
        if let secs = startSecs {
            query += "&offset=\(Int(StreamPosition.transcodeStart(secs)))"
        }
        let quality = QualityPolicy.current(for: baseURL)
        if quality != .original {
            query += "&maxVideoBitrate=\(quality.rawValue)&videoQuality=100"
        }
        return plexURL(base: baseURL, path: "/video/:/transcode/universal/start.m3u8", query: query)
    }

    private static func plexURL(base: URL, path: String, query: String) -> URL? {
        let urlString = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path + "?" + query
        return URL(string: urlString)
    }
}
