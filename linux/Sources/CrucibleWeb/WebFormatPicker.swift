import Foundation

/// A picture quality a viewer picks between: "2160p60 HDR", "1080p".
package struct WebQuality: Hashable, Sendable, Comparable {
    package let height: Int
    /// Frames a second, rounded; rates up to 30 count as the ordinary one.
    package let frameRate: Int
    package let isHDR: Bool

    package init(height: Int, frameRate: Int, isHDR: Bool) {
        self.height = height
        self.frameRate = frameRate
        self.isHDR = isHDR
    }

    init?(_ format: WebFormat) {
        guard format.hasVideo, let height = format.height, height > 0 else { return nil }
        self.init(height: height, frameRate: Int((format.frameRate ?? 0).rounded()), isHDR: format.isHDR)
    }

    package var isHighFrameRate: Bool { frameRate > 30 }

    /// "1080p", "2160p60", "2160p60 HDR".
    package var label: String {
        "\(height)p" + (isHighFrameRate ? "\(frameRate)" : "") + (isHDR ? " HDR" : "")
    }

    package static func < (lhs: WebQuality, rhs: WebQuality) -> Bool {
        (lhs.height, lhs.isHDR ? 1 : 0, lhs.frameRate) < (rhs.height, rhs.isHDR ? 1 : 0, rhs.frameRate)
    }
}

/// What a viewer wants of a web video's streams.
package struct WebPlaybackPreferences: Sendable, Equatable {
    package enum Codec: String, Sendable, CaseIterable {
        case automatic, av1, vp9, h264
    }

    /// The tallest picture to pick on its own, or nil for the tallest there is.
    package var maximumHeight: Int?
    package var codec: Codec
    /// Whether an HDR picture is picked when the video has one.
    package var allowsHDR: Bool
    /// Whether sound in more than two channels is picked when the video has it.
    package var prefersSurround: Bool
    /// The language to hear, or nil for the one the video was made in.
    package var audioLanguage: String?

    package init(maximumHeight: Int? = nil, codec: Codec = .automatic, allowsHDR: Bool = true, prefersSurround: Bool = false, audioLanguage: String? = nil) {
        self.maximumHeight = maximumHeight
        self.codec = codec
        self.allowsHDR = allowsHDR
        self.prefersSurround = prefersSurround
        self.audioLanguage = audioLanguage
    }
}

/// The streams chosen to play together: a picture and a sound, or one stream carrying both.
package struct WebSelection: Sendable, Equatable {
    package let video: WebFormat?
    /// The sound beside the picture; nil when `video` carries its own.
    package let audio: WebFormat?

    package var quality: WebQuality? { video.flatMap(WebQuality.init) }
}

/// A language a video can be heard in.
package struct WebAudioLanguage: Sendable, Equatable, Identifiable {
    package let code: String
    /// The language the video was made in.
    package let isOriginal: Bool

    package var id: String { code }
}

/// Chooses which of a video's streams play, as a web player's automatic quality does but for a home screen: the tallest
/// picture the screen shows, the highest frame rate, HDR when the screen has it, the most efficient codec, and the
/// original language's best sound.
package enum WebFormatPicker {
    /// Every quality the video has, best first.
    package static func qualities(of video: WebVideo) -> [WebQuality] {
        Set(pictures(of: video).compactMap(WebQuality.init)).sorted(by: >)
    }

    /// The languages the video's sound comes in, the original first; empty when there is only one.
    package static func audioLanguages(of video: WebVideo) -> [WebAudioLanguage] {
        let sounds = video.formats.filter { $0.hasAudio && !$0.hasVideo && $0.language != nil }
        let top = sounds.map(\.languagePreference).max() ?? -1
        var seen: Set<String> = []
        var languages: [WebAudioLanguage] = []
        for sound in sounds.sorted(by: { ($0.languagePreference, $1.language ?? "") > ($1.languagePreference, $0.language ?? "") }) {
            guard let code = sound.language, seen.insert(code).inserted else { continue }
            languages.append(WebAudioLanguage(code: code, isOriginal: sound.languagePreference == top && top > -1))
        }
        return languages.count > 1 ? languages : []
    }

    /// The streams to play: `quality` when the viewer chose one, else the best within the preferences.
    package static func pick(from video: WebVideo, preferences: WebPlaybackPreferences, quality: WebQuality? = nil) -> WebSelection? {
        let pictures = pictures(of: video)
        let picture = quality.flatMap { wanted in best(among: pictures.filter { WebQuality($0) == wanted }, preferences: preferences) }
            ?? automatic(among: pictures, preferences: preferences)
        guard let picture else {
            guard let sound = sound(of: video, preferences: preferences) ?? video.formats.first(where: \.hasAudio) else { return nil }
            return WebSelection(video: nil, audio: sound)
        }
        if picture.hasAudio { return WebSelection(video: picture, audio: nil) }
        return WebSelection(video: picture, audio: sound(of: video, preferences: preferences))
    }

    /// The picture streams worth choosing between: one file each where the site has those, since they seek at once, else
    /// whatever it has.
    private static func pictures(of video: WebVideo) -> [WebFormat] {
        let all = video.formats.filter(\.hasVideo)
        let separate = all.filter { !$0.hasAudio && $0.isProgressive }
        if !separate.isEmpty { return separate }
        let progressive = all.filter(\.isProgressive)
        return video.isLive || progressive.isEmpty ? all : progressive
    }

    private static func automatic(among pictures: [WebFormat], preferences: WebPlaybackPreferences) -> WebFormat? {
        var candidates = pictures
        if !preferences.allowsHDR {
            let standard = candidates.filter { !$0.isHDR }
            if !standard.isEmpty { candidates = standard }
        }
        if let limit = preferences.maximumHeight {
            let within = candidates.filter { ($0.height ?? 0) <= limit }
            if within.isEmpty {
                let lowest = candidates.compactMap(\.height).min()
                candidates = candidates.filter { $0.height == lowest }
            } else {
                candidates = within
            }
        }
        guard let top = candidates.compactMap(WebQuality.init).max() else { return best(among: candidates, preferences: preferences) }
        return best(among: candidates.filter { WebQuality($0) == top }, preferences: preferences)
    }

    /// Among streams of one quality: the viewer's codec, else AV1, VP9, H.264 in that order (each needs fewer bits than
    /// the next for the same picture), then the higher bitrate.
    private static func best(among formats: [WebFormat], preferences: WebPlaybackPreferences) -> WebFormat? {
        func rank(_ format: WebFormat) -> Int {
            let family = format.videoFamily
            if preferences.codec != .automatic, family?.rawValue == preferences.codec.rawValue { return 10 }
            switch family {
            case .av1: return 4
            case .vp9: return 3
            case .hevc: return 2
            case .h264: return 1
            default: return 0
            }
        }
        return formats.max { (rank($0), $0.bitrate ?? 0) < (rank($1), $1.bitrate ?? 0) }
    }

    /// The sound to go with a picture: the chosen language (else the original), in surround only when asked for, never the
    /// compressed mix when there is another, then the better codec and bitrate.
    private static func sound(of video: WebVideo, preferences: WebPlaybackPreferences) -> WebFormat? {
        var sounds = video.formats.filter { $0.hasAudio && !$0.hasVideo }
        guard !sounds.isEmpty else { return nil }
        let progressive = sounds.filter(\.isProgressive)
        if !progressive.isEmpty { sounds = progressive }
        if let wanted = preferences.audioLanguage, sounds.contains(where: { $0.language == wanted }) {
            sounds = sounds.filter { $0.language == wanted }
        } else {
            let top = sounds.map(\.languagePreference).max() ?? -1
            sounds = sounds.filter { $0.languagePreference == top }
        }
        let plain = sounds.filter { !$0.isCompressedDynamics }
        if !plain.isEmpty { sounds = plain }
        let surround = sounds.filter { ($0.audioChannels ?? 2) > 2 }
        let stereo = sounds.filter { ($0.audioChannels ?? 2) <= 2 }
        if preferences.prefersSurround, !surround.isEmpty {
            sounds = surround
        } else if !stereo.isEmpty {
            sounds = stereo
        }
        func rank(_ format: WebFormat) -> Int {
            switch format.audioFamily {
            case .eac3: return preferences.prefersSurround ? 4 : 1
            case .ac3: return preferences.prefersSurround ? 3 : 0
            case .opus: return 3
            case .aac: return 2
            default: return 0
            }
        }
        let richest = sounds.map { $0.audioBitrate ?? $0.bitrate ?? 0 }.max() ?? 0
        let full = sounds.filter { ($0.audioBitrate ?? $0.bitrate ?? 0) >= richest * 0.7 }
        return full.max { (rank($0), $0.audioBitrate ?? $0.bitrate ?? 0) < (rank($1), $1.audioBitrate ?? $1.bitrate ?? 0) }
    }
}

/// What mpv is handed to play a selection.
package struct WebPlaybackPlan: Sendable, Equatable {
    /// The address mpv opens: the stream's own, or an `edl://` joining a picture and a sound into one title.
    package let location: String
    package let userAgent: String?
    /// The request headers the site expects, the user agent left out.
    package let headers: [String: String]
    package let selection: WebSelection

    package init?(_ selection: WebSelection) {
        guard let first = selection.video ?? selection.audio, let address = first.url else { return nil }
        self.selection = selection
        var headers = first.headers
        userAgent = headers.removeValue(forKey: "User-Agent")
        self.headers = headers
        if selection.video != nil, let sound = selection.audio?.url {
            location = "edl://" + [address, sound].map { "!new_stream;!no_clip;!no_chapters;" + Self.escaped($0) }.joined(separator: ";")
        } else {
            location = address
        }
    }

    /// An address as an EDL entry: its length in bytes between percent signs, then the address untouched.
    static func escaped(_ address: String) -> String {
        "%\(address.utf8.count)%\(address)"
    }
}
