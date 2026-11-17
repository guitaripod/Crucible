import Foundation

/// A picture quality a viewer picks between: "2160p60 HDR", "1080p".
package struct WebQuality: Hashable, Sendable, Comparable {
    package let height: Int
    /// Frames a second, rounded; every rate up to 30 counts as 30, so a video's 15, 24, 25 and 30 frame streams of one
    /// height are one quality.
    package let frameRate: Int
    package let isHDR: Bool

    package init(height: Int, frameRate: Int, isHDR: Bool) {
        self.height = height
        self.frameRate = frameRate
        self.isHDR = isHDR
    }

    init?(_ format: WebFormat) {
        guard format.hasVideo, let height = format.height, height > 0 else { return nil }
        let rate = Int((format.frameRate ?? 0).rounded())
        self.init(height: height, frameRate: rate > 30 ? rate : 30, isHDR: format.isHDR)
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
    /// Streams that failed to play in this sitting, which are not picked again.
    package var excluded: Set<String>
    /// Whether only the sound is wanted (a talk or music listened to while doing something else), with no picture fetched.
    package var soundOnly: Bool

    package init(maximumHeight: Int? = nil, codec: Codec = .automatic, allowsHDR: Bool = true, prefersSurround: Bool = false, audioLanguage: String? = nil,
                 excluded: Set<String> = [], soundOnly: Bool = false) {
        self.soundOnly = soundOnly
        self.maximumHeight = maximumHeight
        self.codec = codec
        self.allowsHDR = allowsHDR
        self.prefersSurround = prefersSurround
        self.audioLanguage = audioLanguage
        self.excluded = excluded
    }
}

/// The streams chosen to play together: a picture and a sound, or one stream carrying both.
package struct WebSelection: Sendable, Equatable {
    package let video: WebFormat?
    /// The sound beside the picture; nil when `video` carries its own.
    package let audio: WebFormat?

    package var quality: WebQuality? { video.flatMap(WebQuality.init) }

    /// When the site serves every chosen stream; nil when it does already.
    package var readyAt: Date? {
        [video?.availableAt, audio?.availableAt].compactMap { $0 }.max()
    }

    /// The streams' names, for leaving them out after they failed.
    package var formats: Set<String> {
        Set([video?.id, audio?.id].compactMap { $0 })
    }
}

/// A language a video can be heard in.
package struct WebAudioLanguage: Sendable, Equatable, Identifiable {
    package let code: String
    /// The language the video was made in.
    package let isOriginal: Bool

    package var id: String { code }
}

/// Chooses which of a video's streams play, as a web player's automatic quality does but for a home screen: the tallest
/// picture within the viewer's limit, the highest frame rate, HDR when the screen has it, and the original language's
/// best sound. Among streams of that quality, one the site serves at once comes before one it holds back for a few
/// seconds, a single file (which seeks by byte) before a playlist of segments, and a leaner codec before a heavier one.
package enum WebFormatPicker {
    /// Every quality the video has, best first.
    package static func qualities(of video: WebVideo) -> [WebQuality] {
        Set(video.formats.filter(\.hasVideo).compactMap(WebQuality.init)).sorted(by: >)
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

    /// The streams to play at `now`: `quality` when the viewer chose one, else the best within the preferences.
    package static func pick(from video: WebVideo, preferences: WebPlaybackPreferences, quality: WebQuality? = nil, now: Date = Date()) -> WebSelection? {
        if preferences.soundOnly, let sound = sound(of: video, preferences: preferences, now: now) { return WebSelection(video: nil, audio: sound) }
        let pictures = video.formats.filter { $0.hasVideo && !preferences.excluded.contains($0.id) }
        let chosen = quality.flatMap { wanted in best(among: pictures.filter { WebQuality($0) == wanted }, preferences: preferences, now: now) }
            ?? automatic(among: pictures, preferences: preferences, now: now)
        guard let picture = chosen else {
            guard let sound = sound(of: video, preferences: preferences, now: now) ?? video.formats.first(where: { $0.hasAudio && !preferences.excluded.contains($0.id) })
            else { return nil }
            return WebSelection(video: nil, audio: sound)
        }
        if picture.hasAudio { return WebSelection(video: picture, audio: nil) }
        return WebSelection(video: picture, audio: sound(of: video, preferences: preferences, now: now))
    }

    private static func automatic(among pictures: [WebFormat], preferences: WebPlaybackPreferences, now: Date) -> WebFormat? {
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
        guard let top = candidates.compactMap(WebQuality.init).max() else { return best(among: candidates, preferences: preferences, now: now) }
        return best(among: candidates.filter { WebQuality($0) == top }, preferences: preferences, now: now)
    }

    /// Among streams of one quality: one served at once, then a picture with its sound beside it (the site's joined
    /// files carry its poorest sound), then a single file, then the viewer's codec or AV1, VP9, HEVC, H.264 in that order
    /// (each needs fewer bits than the next for the same picture), then the higher bitrate.
    private static func best(among formats: [WebFormat], preferences: WebPlaybackPreferences, now: Date) -> WebFormat? {
        func codec(_ format: WebFormat) -> Int {
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
        func order(_ format: WebFormat) -> (Int, Int, Int, Int, Double) {
            (format.isReady(at: now) ? 1 : 0, format.hasAudio ? 0 : 1, format.isProgressive ? 1 : 0, codec(format), format.bitrate ?? 0)
        }
        return formats.max { order($0) < order($1) }
    }

    /// The sound to go with a picture: the chosen language (else the original), in surround only when asked for, never the
    /// compressed mix when there is another, then one served at once, the site's own rank, the better codec and bitrate.
    private static func sound(of video: WebVideo, preferences: WebPlaybackPreferences, now: Date) -> WebFormat? {
        var sounds = video.formats.filter { $0.hasAudio && !$0.hasVideo && !preferences.excluded.contains($0.id) }
        guard !sounds.isEmpty else { return nil }
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
        func codec(_ format: WebFormat) -> Int {
            switch format.audioFamily {
            case .eac3: return preferences.prefersSurround ? 4 : 1
            case .ac3: return preferences.prefersSurround ? 3 : 0
            case .opus: return 3
            case .aac: return 2
            default: return 0
            }
        }
        func order(_ format: WebFormat) -> (Int, Double, Int, Double) {
            (format.isReady(at: now) ? 1 : 0, format.rank ?? -1, codec(format), format.audioBitrate ?? format.bitrate ?? 0)
        }
        return sounds.max { order($0) < order($1) }
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
