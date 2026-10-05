import UIKit

extension Theme.Font {
    static var detailTitle: UIFont { scaled(.largeTitle, 34, .heavy) }
    static var eyebrow: UIFont { scaled(.caption2, 11, .bold, maximum: 18) }
    static var episodeTitle: UIFont { scaled(.callout, 16, .semibold) }
    static var chip: UIFont { scaled(.subheadline, 14, .semibold, maximum: 22) }
}

/// Copy and fact formatting for the detail screens, matching the board's "2 h 14 m", "42 min" and
/// uppercase badge vocabulary.
@MainActor
enum DetailFormat {
    static func runtime(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let totalMinutes = max(1, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes) min" }
        if minutes == 0 { return "\(hours) h" }
        return "\(hours) h \(minutes) m"
    }

    static func remaining(position: Double, duration: Double) -> String? {
        guard duration > 0, position > 0, position < duration else { return nil }
        return runtime(duration - position).map { "\($0) left" }
    }

    static func spokenDuration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: max(60, seconds))
    }

    static func eyebrow(_ text: String, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: Theme.Font.eyebrow,
            .foregroundColor: color,
            .kern: 1.0,
        ])
    }

    static func episodeCode(season: Int?, episode: Int?) -> String? {
        switch (season, episode) {
        case let (s?, e?): return "S\(s) · E\(e)"
        case let (nil, e?): return "E\(e)"
        default: return nil
        }
    }

    /// "2021 · 2 h 14 m · ★ 8.1 · 92% critics" with the star drawn as an ember SF Symbol.
    static func metaLine(leading: [String], star: String?, trailing: [String]) -> NSAttributedString {
        let font = Theme.Font.subheadline
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.Color.labelSecondary]
        var segments: [NSAttributedString] = leading.map { NSAttributedString(string: $0, attributes: attributes) }
        if let star {
            let segment = NSMutableAttributedString()
            let symbol = UIImage(systemName: "star.fill", withConfiguration: UIImage.SymbolConfiguration(font: font, scale: .small))?
                .withTintColor(Theme.Color.accent, renderingMode: .alwaysOriginal)
            if let symbol {
                let attachment = NSTextAttachment(image: symbol)
                segment.append(NSAttributedString(attachment: attachment))
                segment.append(NSAttributedString(string: "\u{2009}", attributes: attributes))
            }
            segment.append(NSAttributedString(string: star, attributes: attributes))
            segments.append(segment)
        }
        segments.append(contentsOf: trailing.map { NSAttributedString(string: $0, attributes: attributes) })
        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: " · ", attributes: attributes)) }
            result.append(segment)
        }
        return result
    }

    static func ratingParts(audience: Double?, critic: Double?) -> (star: String?, trailing: [String]) {
        if let audience, audience > 0 {
            var trailing: [String] = []
            if let critic, critic > 0 { trailing.append("\(Int((critic * 10).rounded()))% critics") }
            return (Formatters.rating(audience), trailing)
        }
        if let critic, critic > 0 { return (Formatters.rating(critic), []) }
        return (nil, [])
    }

    static func spokenRating(audience: Double?, critic: Double?) -> String? {
        let value = (audience ?? 0) > 0 ? audience : critic
        guard let value, value > 0, let text = Formatters.rating(value) else { return nil }
        return "rated \(text) out of 10"
    }

    static func primaryAudioStream(_ item: PlexMetadata, selectedId: Int? = nil) -> PlexStream? {
        let streams = item.audioStreams
        if let selectedId, let match = streams.first(where: { $0.id == selectedId }) { return match }
        return streams.first(where: { $0.selected == true }) ?? streams.first(where: { $0.isDefault == true }) ?? streams.first
    }

    static func isAtmos(_ stream: PlexStream) -> Bool {
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
        case 2: return "Stereo"
        case 1: return "Mono"
        default: return "\(channels)ch"
        }
    }

    static func languageName(_ stream: PlexStream) -> String {
        stream.language ?? stream.displayTitle ?? stream.title ?? stream.id.map { "Track \($0)" } ?? "Unknown"
    }

    /// Short "English · Atmos" summary for the Audio menu button.
    static func audioValue(_ stream: PlexStream) -> String {
        let qualifier = isAtmos(stream) ? "Atmos" : (channelLabel(stream.channels) ?? audioCodecLabel(stream.codec))
        return [languageName(stream), qualifier].compactMap { $0 }.joined(separator: " · ")
    }

    static func audioDetail(_ stream: PlexStream) -> String {
        var parts: [String] = []
        if isAtmos(stream) { parts.append("Atmos") } else if let codec = audioCodecLabel(stream.codec) { parts.append(codec) }
        if let channels = channelLabel(stream.channels) { parts.append(channels) }
        if let bitrate = stream.bitrate { parts.append("\(bitrate) kbps") }
        return parts.joined(separator: " · ")
    }

    static func subtitleValue(_ stream: PlexStream) -> String {
        var parts = [languageName(stream)]
        if stream.forced == true { parts.append("Forced") }
        return parts.joined(separator: " · ")
    }

    static func subtitleDetail(_ stream: PlexStream) -> String {
        if stream.isBitmap { return "Image-based" }
        var parts: [String] = []
        if let codec = stream.codec { parts.append(codec.uppercased()) }
        if stream.forced == true { parts.append("Forced") }
        if stream.isDefault == true { parts.append("Default") }
        return parts.joined(separator: " · ")
    }

    /// Technical badges for the hero: resolution, dynamic range, audio format, channels, rating.
    static func technicalBadges(for item: PlexMetadata?, contentRating: String?, audio: PlexStream?) -> [String] {
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

    private static func dynamicRange(_ item: PlexMetadata) -> String? {
        let video = item.Media?.first?.Part?.first?.Stream?.first { $0.streamType == 1 }
        let title = [video?.displayTitle, video?.title].compactMap { $0 }.joined(separator: " ").lowercased()
        if title.contains("dovi") || title.contains("dolby vision") { return "DOLBY VISION" }
        if title.contains("hdr10+") { return "HDR10+" }
        if title.contains("hdr10") { return "HDR10" }
        if title.contains("hdr") || title.contains("hlg") { return "HDR" }
        if video?.displayTitle == nil, let profile = item.Media?.first?.videoProfile, profile.lowercased().contains("10") {
            return "HDR"
        }
        return nil
    }

    static func fileFact(_ item: PlexMetadata) -> String? {
        let parts = [videoCodecLabel(item.videoCodec), item.mediaContainer?.uppercased(), item.fileSize.map(Formatters.fileSize)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func audioFact(_ stream: PlexStream?) -> String? {
        guard let stream else { return nil }
        let format = [isAtmos(stream) ? "Atmos" : audioCodecLabel(stream.codec), channelLabel(stream.channels)]
            .compactMap { $0 }
            .joined(separator: " ")
        return [format.isEmpty ? nil : format, stream.language].compactMap { $0 }.joined(separator: " · ")
    }

    static func addedDate(_ timestamp: Int?) -> String? {
        guard let timestamp, timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).filter { !$0.isEmpty }
        guard let first = words.first?.first else { return "" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return "\(first)\(last)".uppercased()
    }
}
