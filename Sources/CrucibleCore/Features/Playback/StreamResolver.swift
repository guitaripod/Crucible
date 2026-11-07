import Foundation
import os

/// How the stream carries the subtitle it was resolved with.
package enum SubtitleDelivery: String, Sendable {
    /// No subtitle travels with the stream.
    case none
    /// A text track the player shows and hides itself: a WebVTT rendition of the transcode, or a track of the file that
    /// plays directly.
    case track
    /// Drawn into the picture by the transcoder; only image-based subtitles come this way.
    case burned

    /// The transcoder's `subtitles` parameter for this delivery.
    var transcodeParameter: String {
        switch self {
        case .none: "none"
        case .track: "auto"
        case .burned: "burn"
        }
    }
}

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
    /// How the chosen subtitle reaches the screen.
    package let subtitleDelivery: SubtitleDelivery

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
        segments: [SkipMarker]? = nil,
        subtitleDelivery: SubtitleDelivery = .none
    ) {
        self.segments = segments ?? markers.compactMap(SkipMarker.init)
        self.subtitleDelivery = subtitleDelivery
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
            segments: segments,
            subtitleDelivery: subtitleDelivery
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

    /// Asks the transcoder for a text subtitle as a WebVTT rendition of the HLS stream instead of burning it into the picture, so
    /// the player shows it as a real subtitle track: the system controls, Siri and the viewer's caption style all reach it.
    static let webVTTSubtitleProfile = "add-transcode-target(type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt)"

    /// Subtitle codecs a file carries that the player shows from the file itself when it plays directly.
    private static let fileTrackSubtitleCodecs: Set<String> = ["mov_text", "tx3g"]

    /// Resolves how to play `ratingKey`. Streams chosen by id win; with none chosen, `languages` picks this file's streams in
    /// the languages the viewer had before, and with neither, `honorsServerSelection` takes the subtitle the server selected for
    /// the viewer (their Plex account's subtitle preferences), else one in `captionLanguage`, the language of the device's
    /// always-on captions. The server is told the choice, so a converted stream carries exactly that subtitle, or none. A text
    /// subtitle travels as a WebVTT track; an image subtitle, or a text one on a server that answers it will burn it in, is burned.
    package static func resolve(
        api: APIClient,
        ratingKey: String,
        startSecs: Double?,
        selectedSubtitleId: Int?,
        selectedAudioStreamId: Int?,
        languages: TrackLanguages? = nil,
        honorsServerSelection: Bool = false,
        captionLanguage: String? = nil,
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
        if selectedSubtitleId == nil, selectedAudioStreamId == nil {
            if let languages {
                (selectedSubtitleId, selectedAudioStreamId) = languages.streamIds(subtitles: subtitles, audioTracks: audioTracks)
            } else if honorsServerSelection {
                selectedSubtitleId = subtitles.first { $0.selected == true }?.id
                    ?? captionLanguage.flatMap { captionSubtitle(in: $0, among: subtitles)?.id }
            }
        }
        let subtitle = subtitles.first { $0.id != nil && $0.id == selectedSubtitleId }
        selectedSubtitleId = subtitle?.id
        let defaultAudioId = audioTracks.first(where: { $0.isDefault == true })?.id ?? audioTracks.first?.id
        let wantsNonDefaultAudio = selectedAudioStreamId != nil && selectedAudioStreamId != defaultAudioId
        let subtitleIsInFile = subtitle.map(isFileTrack) ?? true

        await applyStreamSelection(
            api: api,
            ratingKey: ratingKey,
            partId: part.id,
            audioStreamId: selectedAudioStreamId ?? defaultAudioId,
            subtitleStreamId: selectedSubtitleId
        )

        if !forceTranscode,
           QualityPolicy.current(for: baseURL) == .original,
           subtitleIsInFile,
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
                segments: segments,
                subtitleDelivery: subtitle == nil ? .none : .track
            )
        }

        var delivery: SubtitleDelivery = subtitle.map { $0.isBitmap ? .burned : .track } ?? .none
        guard let url = transcodeURL(
            baseURL: baseURL,
            token: token,
            ratingKey: ratingKey,
            session: sessionId,
            startSecs: startSecs,
            subtitlesMode: delivery.transcodeParameter
        ) else {
            throw StreamResolverError.noConnectionURL
        }

        let decision = await fetchDecision(startURL: url, token: token)
        if let decision, decision.isRefusal {
            log.error("Server refused the stream code=\(decision.generalCode ?? 0) text=\(decision.generalText ?? "", privacy: .public)")
            throw StreamResolverError.refused(PlaybackDecisionCopy.refusalMessage(decision))
        }
        if delivery == .track, decision?.subtitleDecision == "burn" {
            delivery = .burned
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
            segments: segments,
            subtitleDelivery: delivery
        )
    }

    /// The full (not forced) text subtitle in `language`, a BCP 47 tag such as "en-US", for a viewer who keeps captions on.
    static func captionSubtitle(in language: String, among subtitles: [PlexStream]) -> PlexStream? {
        let wanted = alpha3(language)
        return subtitles.first { stream in
            guard !stream.isBitmap, stream.forced != true, let tag = stream.bcp47Language else { return false }
            return alpha3(tag) == wanted
        }
    }

    /// The ISO 639 alpha-3 code of a language however it is written ("en", "en-US", "eng").
    package static func alpha3(_ language: String) -> String {
        let code = Locale.Language(identifier: language).languageCode
        return code?.identifier(.alpha3) ?? code?.identifier ?? language.lowercased()
    }

    /// Whether `subtitle` is a track of the file the player can show when the file plays directly; any other subtitle needs the
    /// transcoder, which hands it over as a WebVTT rendition.
    package static func isFileTrack(_ subtitle: PlexStream) -> Bool {
        subtitle.key == nil && fileTrackSubtitleCodecs.contains(subtitle.codec?.lowercased() ?? "")
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
        subtitleDelivery: SubtitleDelivery
    ) async -> URL? {
        transcodeURL(
            baseURL: await api.baseURL,
            token: api.token,
            ratingKey: ratingKey,
            session: sessionId,
            startSecs: offsetSecs,
            subtitlesMode: subtitleDelivery.transcodeParameter
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

    /// Tells the server which audio and subtitle stream of the part to play. The transcoder only ever takes them from the part,
    /// and keeps a subtitle selected there until it is told otherwise, so no subtitle is sent as stream 0. The metadata cached for
    /// the item is dropped afterwards, so the next read shows the server's new selection. A refused or failed update is logged;
    /// the stream still starts.
    package static func applyStreamSelection(
        api: APIClient,
        ratingKey: String,
        partId: Int,
        audioStreamId: Int?,
        subtitleStreamId: Int?
    ) async {
        var params = ["allParts=1", "subtitleStreamID=\(subtitleStreamId ?? 0)"]
        if let audioStreamId { params.append("audioStreamID=\(audioStreamId)") }
        guard let url = plexURL(base: await api.baseURL, path: "/library/parts/\(partId)", query: params.joined(separator: "&")) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 10
        for (key, value) in PlexHeaders.allHeaders(token: api.token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                log.error("Stream selection for part \(partId) answered \(status)")
            }
        } catch {
            log.error("Stream selection PUT failed for part \(partId): \(error.localizedDescription, privacy: .public)")
        }
        await api.invalidate(ratingKey: ratingKey)
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
            + "&X-Plex-Client-Profile-Extra=\(profileExtra)"
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

    private static var profileExtra: String {
        webVTTSubtitleProfile.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    private static func plexURL(base: URL, path: String, query: String) -> URL? {
        let urlString = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path + "?" + query
        return URL(string: urlString)
    }
}
