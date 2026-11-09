import Foundation

/// Copy and fact formatting for the detail screens, matching the board's "2 h 14 m", "42 min" and
/// uppercase badge vocabulary.
package enum DetailFormat {
    package static func runtime(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let totalMinutes = max(1, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return String(localized: "\(minutes) min") }
        if minutes == 0 { return String(localized: "\(hours) h") }
        return String(localized: "\(hours) h \(minutes) m")
    }

    package static func remaining(position: Double, duration: Double) -> String? {
        guard duration > 0, position > 0, position < duration else { return nil }
        return runtime(duration - position).map { String(localized: "\($0) left") }
    }

    package static func spokenDuration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: max(60, seconds))
    }

    package static func episodeCode(season: Int?, episode: Int?) -> String? {
        switch (season, episode) {
        case let (s?, e?): return "S\(s) · E\(e)"
        case let (nil, e?): return "E\(e)"
        default: return nil
        }
    }

    /// The most scores a meta line carries, so it stays one compact line beside the year and the runtime.
    package static let ratingLimit = 4

    /// The scores for a detail page's meta line: Plex's own ratings first, under their sources' marks when the server names
    /// them, then what Trakt adds from sources Plex did not show, Trakt's own score leading. A source shows once.
    package static func ratings(
        audience: Double?,
        audienceImage: String?,
        critic: Double?,
        criticImage: String?,
        trakt: [TraktScore] = []
    ) -> [DetailRating] {
        var ratings: [DetailRating] = []
        if let audience, audience > 0 {
            ratings.append(plexRating(audience, image: audienceImage, isCritic: false, alone: true))
        }
        if let critic, critic > 0 {
            ratings.append(plexRating(critic, image: criticImage, isCritic: true, alone: ratings.isEmpty))
        }
        var shown = Set(ratings.compactMap(\.scoreSource))
        for score in trakt.sorted(by: { traktOrder($0.source) < traktOrder($1.source) }) where ratings.count < ratingLimit {
            guard !shown.contains(score.source) else { continue }
            shown.insert(score.source)
            ratings.append(DetailRating(score: score))
        }
        return ratings
    }

    /// A rating Plex holds, `value` out of 10, under the mark of the source its image names. Rotten Tomatoes' audience
    /// score has no mark Crucible draws, so it keeps the star; an unnamed critics' score beside another rating says "critics".
    private static func plexRating(_ value: Double, image: String?, isCritic: Bool, alone: Bool) -> DetailRating {
        let percent = Int((value * 10).rounded())
        switch RatingSource(plexImage: image) {
        case .imdb:
            return DetailRating(score: TraktScore(source: .imdb, value: value, votes: nil, link: nil))
        case .tmdb:
            return DetailRating(score: TraktScore(source: .tmdb, value: value, votes: nil, link: nil))
        case .rottenTomatoesCritics:
            return DetailRating(score: TraktScore(source: .rottenTomatoes, value: value * 10, votes: nil, link: nil))
        case .rottenTomatoesAudience:
            return DetailRating(mark: .star, text: "\(percent)%", spoken: String(localized: "Audience score \(percent)%", comment: "Spoken Rotten Tomatoes audience score on a detail page"))
        case nil:
            if isCritic, !alone {
                return DetailRating(mark: .none, text: String(localized: "\(percent)% critics"), spoken: String(localized: "\(percent)% critics"))
            }
            let text = Formatters.rating(value) ?? String(format: "%.1f", value)
            return DetailRating(mark: .star, text: text, spoken: String(localized: "rated \(text) out of 10"))
        }
    }

    private static func traktOrder(_ source: TraktScore.Source) -> Int {
        [.trakt, .imdb, .rottenTomatoes, .metascore, .letterboxd, .myAnimeList, .tmdb].firstIndex(of: source) ?? 99
    }

    package static func primaryAudioStream(_ item: PlexMetadata, selectedId: Int? = nil) -> PlexStream? {
        let streams = item.audioStreams
        if let selectedId, let match = streams.first(where: { $0.id == selectedId }) { return match }
        return streams.first(where: { $0.selected == true }) ?? streams.first(where: { $0.isDefault == true }) ?? streams.first
    }

    package static func isAtmos(_ stream: PlexStream) -> Bool {
        let haystack = [stream.displayTitle, stream.title].compactMap { $0 }.joined(separator: " ").lowercased()
        return haystack.contains("atmos")
    }

    static func audioCodecLabel(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "truehd": return "TrueHD"
        case "eac3": return "DD+"
        case "ac3": return "Dolby Digital"
        case "dca", "dts", "dca-ma", "dts-hd": return "DTS"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "mp3": return "MP3"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "pcm": return "PCM"
        default: return codec.uppercased()
        }
    }

    static func videoCodecLabel(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "h264": return "H.264"
        case "hevc", "h265": return "HEVC"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "mpeg2video": return "MPEG-2"
        default: return codec.uppercased()
        }
    }

    static func channelLabel(_ channels: Int?) -> String? {
        guard let channels else { return nil }
        switch channels {
        case 8: return "7.1"
        case 6: return "5.1"
        case 2: return String(localized: "Stereo", comment: "Audio channel layout: two channels")
        case 1: return String(localized: "Mono", comment: "Audio channel layout: one channel")
        default: return String(localized: "\(channels)ch")
        }
    }

    package static func languageName(_ stream: PlexStream) -> String {
        stream.language ?? stream.displayTitle ?? stream.title ?? stream.id.map { String(localized: "Track \($0)") } ?? String(localized: "Unknown", comment: "Track language is not known")
    }

    /// Short "English · Atmos" summary for the Audio menu button.
    package static func audioValue(_ stream: PlexStream) -> String {
        let qualifier = isAtmos(stream) ? "Atmos" : (channelLabel(stream.channels) ?? audioCodecLabel(stream.codec))
        return [languageName(stream), qualifier].compactMap { $0 }.joined(separator: " · ")
    }

    package static func audioDetail(_ stream: PlexStream) -> String {
        var parts: [String] = []
        if isAtmos(stream) { parts.append("Atmos") } else if let codec = audioCodecLabel(stream.codec) { parts.append(codec) }
        if let channels = channelLabel(stream.channels) { parts.append(channels) }
        if let bitrate = stream.bitrate { parts.append(String(localized: "\(bitrate) kbps")) }
        return parts.joined(separator: " · ")
    }

    package static func subtitleValue(_ stream: PlexStream) -> String {
        var parts = [languageName(stream)]
        if stream.forced == true { parts.append(String(localized: "Forced", comment: "Subtitle track flagged as forced")) }
        return parts.joined(separator: " · ")
    }

    package static func subtitleDetail(_ stream: PlexStream) -> String {
        if stream.isBitmap { return String(localized: "Image-based") }
        var parts: [String] = []
        if let codec = stream.codec { parts.append(codec.uppercased()) }
        if stream.forced == true { parts.append(String(localized: "Forced", comment: "Subtitle track flagged as forced")) }
        if stream.isDefault == true { parts.append(String(localized: "Default", comment: "Audio or subtitle track that is selected by default")) }
        return parts.joined(separator: " · ")
    }

    /// Technical badges for the hero: resolution, dynamic range, audio format, channels, rating.
    package static func technicalBadges(for item: PlexMetadata?, contentRating: String?, audio: PlexStream?) -> [String] {
        var badges: [String] = []
        if let item {
            if let resolution = Formatters.resolution(item.videoWidth, item.videoHeight) {
                badges.append(resolution)
            }
            if let range = dynamicRange(item) { badges.append(range) }
            if let audio {
                if isAtmos(audio) {
                    badges.append("DOLBY ATMOS")
                } else if let codec = audioCodecLabel(audio.codec) {
                    badges.append(codec.uppercased())
                }
                if let channels = audio.channels, channels >= 6, let label = channelLabel(channels) {
                    badges.append(label)
                }
            }
        }
        if let contentRating, !contentRating.isEmpty { badges.append(contentRating) }
        return badges
    }

    package static let dolbyVisionBadge = "DOLBY VISION"

    /// "DOLBY VISION", "HDR10+", "HDR10" or "HDR" from the video stream's label, nil for SDR.
    package static func dynamicRange(_ item: PlexMetadata) -> String? {
        let video = item.Media?.first?.Part?.first?.Stream?.first { $0.streamType == 1 }
        let title = [video?.displayTitle, video?.title].compactMap { $0 }.joined(separator: " ").lowercased()
        if title.contains("dovi") || title.contains("dolby vision") { return dolbyVisionBadge }
        if title.contains("hdr10+") { return "HDR10+" }
        if title.contains("hdr10") { return "HDR10" }
        if title.contains("hdr") || title.contains("hlg") { return "HDR" }
        if video?.displayTitle == nil, let profile = item.Media?.first?.videoProfile, profile.lowercased().contains("10") {
            return "HDR"
        }
        return nil
    }

    package static func fileFact(_ item: PlexMetadata) -> String? {
        let parts = [videoCodecLabel(item.videoCodec), item.mediaContainer?.uppercased(), item.fileSize.map(Formatters.fileSize)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    package static func audioFact(_ stream: PlexStream?) -> String? {
        guard let stream else { return nil }
        let format = [isAtmos(stream) ? "Atmos" : audioCodecLabel(stream.codec), channelLabel(stream.channels)]
            .compactMap { $0 }
            .joined(separator: " ")
        return [format.isEmpty ? nil : format, stream.language].compactMap { $0 }.joined(separator: " · ")
    }

    package static func addedDate(_ timestamp: Int?) -> String? {
        guard let timestamp, timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }

    package static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).filter { !$0.isEmpty }
        guard let first = words.first?.first else { return "" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return "\(first)\(last)".uppercased()
    }
}
