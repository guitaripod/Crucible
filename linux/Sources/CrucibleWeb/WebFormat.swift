import Foundation

/// One stream of a video: a picture, a sound, or both in one file, at one size, codec and bitrate.
package struct WebFormat: Sendable, Decodable, Equatable {
    package let id: String
    package let url: String?
    package let container: String?
    /// The picture's codec as the site names it ("av01.0.13M.08"), nil without a picture.
    package let videoCodec: String?
    package let audioCodec: String?
    package let width: Int?
    package let height: Int?
    package let frameRate: Double?
    /// Total, picture and sound bitrates in kilobits a second.
    package let bitrate: Double?
    package let videoBitrate: Double?
    package let audioBitrate: Double?
    /// "SDR", "HDR10", "HLG" and the like.
    package let dynamicRange: String?
    package let audioChannels: Int?
    package let sampleRate: Int?
    package let language: String?
    /// How much the site prefers this sound's language: its original at the top, a described one at the bottom.
    package let languagePreference: Int
    package let note: String?
    package let transport: String?
    package let headers: [String: String]
    package let fileSize: Int?
    let isProtected: Bool
    let fragments: [Fragment]
    let rows: Int?
    let columns: Int?

    struct Fragment: Sendable, Decodable, Equatable {
        let url: String?
        let duration: Double?
    }

    enum CodingKeys: String, CodingKey {
        case url, ext, vcodec, acodec, width, height, fps, tbr, vbr, abr, asr, language, fragments, rows, columns, filesize
        case id = "format_id"
        case dynamicRange = "dynamic_range"
        case audioChannels = "audio_channels"
        case languagePreference = "language_preference"
        case note = "format_note"
        case transport = "protocol"
        case headers = "http_headers"
        case approximateSize = "filesize_approx"
        case isProtected = "has_drm"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = container.text(.url)
        self.container = container.text(.ext)
        let video = container.text(.vcodec)
        let audio = container.text(.acodec)
        videoCodec = video == "none" ? nil : video
        audioCodec = audio == "none" ? nil : audio
        width = container.number(.width).map { Int($0) }
        height = container.number(.height).map { Int($0) }
        frameRate = container.number(.fps)
        bitrate = container.number(.tbr)
        videoBitrate = container.number(.vbr).flatMap { $0 > 0 ? $0 : nil }
        audioBitrate = container.number(.abr).flatMap { $0 > 0 ? $0 : nil }
        dynamicRange = container.text(.dynamicRange)
        audioChannels = container.number(.audioChannels).map { Int($0) }
        sampleRate = container.number(.asr).map { Int($0) }
        language = container.text(.language)
        languagePreference = container.number(.languagePreference).map { Int($0) } ?? -1
        note = container.text(.note)
        transport = container.text(.transport)
        headers = ((try? container.decodeIfPresent([String: String].self, forKey: .headers)) ?? nil) ?? [:]
        fileSize = (container.number(.filesize) ?? container.number(.approximateSize)).map { Int($0) }
        isProtected = (try? container.decodeIfPresent(Bool.self, forKey: .isProtected)) ?? false
        fragments = ((try? container.decodeIfPresent([Fragment].self, forKey: .fragments)) ?? nil) ?? []
        rows = container.number(.rows).map { Int($0) }
        columns = container.number(.columns).map { Int($0) }
    }

    /// A lone address a site gave in place of a list of formats; what it carries is only known once it plays.
    init(direct url: String) {
        id = "direct"
        self.url = url
        container = nil
        videoCodec = nil
        audioCodec = nil
        width = nil
        height = nil
        frameRate = nil
        bitrate = nil
        videoBitrate = nil
        audioBitrate = nil
        dynamicRange = nil
        audioChannels = nil
        sampleRate = nil
        language = nil
        languagePreference = -1
        note = nil
        transport = nil
        headers = [:]
        fileSize = nil
        isProtected = false
        fragments = []
        rows = nil
        columns = nil
    }

    var isStoryboard: Bool { note == "storyboard" || container == "mhtml" }

    package var hasVideo: Bool { videoCodec != nil || (audioCodec == nil && id == "direct") }
    package var hasAudio: Bool { audioCodec != nil || id == "direct" }

    /// Whether the address is one file that seeks by byte range, not a playlist of segments.
    package var isProgressive: Bool { transport == "https" || transport == "http" || transport == nil }

    package var isHDR: Bool {
        guard let dynamicRange else { return false }
        return dynamicRange != "SDR"
    }

    /// Sound mixed for small speakers, with the loud and the quiet pressed together ("DRC").
    package var isCompressedDynamics: Bool { id.hasSuffix("-drc") || (note?.contains("DRC") ?? false) }

    package var videoFamily: WebCodec? { videoCodec.map(WebCodec.init(video:)) }
    package var audioFamily: WebCodec? { audioCodec.map(WebCodec.init(audio:)) }
}

/// The codec families a choice is made between.
package enum WebCodec: String, Sendable, CaseIterable {
    case av1, vp9, h264, hevc, opus, aac, eac3, ac3, other

    init(video name: String) {
        let name = name.lowercased()
        if name.hasPrefix("av01") || name == "av1" {
            self = .av1
        } else if name.hasPrefix("vp09") || name.hasPrefix("vp9") {
            self = .vp9
        } else if name.hasPrefix("avc") || name.hasPrefix("h264") {
            self = .h264
        } else if name.hasPrefix("hev") || name.hasPrefix("hvc") || name.hasPrefix("h265") {
            self = .hevc
        } else {
            self = .other
        }
    }

    init(audio name: String) {
        let name = name.lowercased()
        if name.hasPrefix("opus") {
            self = .opus
        } else if name.hasPrefix("mp4a") || name.hasPrefix("aac") {
            self = .aac
        } else if name.hasPrefix("ec-3") || name.hasPrefix("eac3") {
            self = .eac3
        } else if name.hasPrefix("ac-3") || name.hasPrefix("ac3") {
            self = .ac3
        } else {
            self = .other
        }
    }

    /// The name people know the codec by.
    package var displayName: String {
        switch self {
        case .av1: "AV1"
        case .vp9: "VP9"
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .opus: "Opus"
        case .aac: "AAC"
        case .eac3: "Dolby Digital Plus"
        case .ac3: "Dolby Digital"
        case .other: ""
        }
    }
}

/// A subtitle track of a video: written by its publisher, or made by the site from the speech.
package struct WebSubtitle: Sendable, Equatable, Identifiable {
    package let language: String
    package let name: String?
    package let url: String
    /// "vtt", "srt" and the like.
    package let format: String
    package let isAutomatic: Bool
    /// An automatic track in the language the video is spoken in, not a machine translation of it.
    package let isOriginal: Bool

    package var id: String { (isAutomatic ? "auto:" : "sub:") + language }

    struct Source: Sendable, Decodable {
        let ext: String?
        let url: String?
        let name: String?
        let transport: String?

        enum CodingKeys: String, CodingKey {
            case ext, url, name
            case transport = "protocol"
        }
    }

    /// The formats mpv reads, best first.
    private static let readable = ["vtt", "srt", "ass", "ttml"]

    /// One track per language from yt-dlp's lists: the publisher's own first, then the automatic ones, each in the first
    /// format mpv reads; a publisher's track hides the automatic one of the same language.
    static func list(manual: [String: [Source]], automatic: [String: [Source]], spoken: String?) -> [WebSubtitle] {
        func track(_ language: String, _ sources: [Source], automatic: Bool) -> WebSubtitle? {
            let whole = sources.filter { $0.url != nil && $0.transport?.hasPrefix("m3u8") != true }
            for format in readable {
                guard let source = whole.first(where: { $0.ext == format }), let url = source.url else { continue }
                let original = automatic && (language.hasSuffix("-orig") || language == spoken)
                return WebSubtitle(language: language.replacingOccurrences(of: "-orig", with: ""), name: source.name, url: url, format: format,
                                   isAutomatic: automatic, isOriginal: original)
            }
            return nil
        }
        let written = manual.keys.sorted().filter { $0 != "live_chat" }.compactMap { track($0, manual[$0] ?? [], automatic: false) }
        let taken = Set(written.map(\.language))
        var made: [String: WebSubtitle] = [:]
        for key in automatic.keys.sorted() {
            guard let found = track(key, automatic[key] ?? [], automatic: true), !taken.contains(found.language) else { continue }
            if let kept = made[found.language], kept.isOriginal || !found.isOriginal { continue }
            made[found.language] = found
        }
        return written + made.values.sorted { $0.language < $1.language }
    }
}

/// Sheets of small stills along a video, a grid of them per sheet, for the preview above the scrubber.
package struct WebStoryboard: Sendable, Equatable {
    package struct Sheet: Sendable, Equatable {
        package let url: String
        /// Where on the video's timeline the sheet's first still sits, and how long the sheet covers.
        package let start: Double
        package let duration: Double
    }

    /// One still's size in pixels.
    package let width: Int
    package let height: Int
    package let rows: Int
    package let columns: Int
    package let sheets: [Sheet]
    package let headers: [String: String]

    init?(_ format: WebFormat) {
        guard format.isStoryboard, let width = format.width, let height = format.height, let rows = format.rows, let columns = format.columns,
              rows > 0, columns > 0, width > 0, height > 0 else { return nil }
        var start = 0.0
        var sheets: [Sheet] = []
        for fragment in format.fragments {
            guard let url = fragment.url, let duration = fragment.duration, duration > 0 else { continue }
            sheets.append(Sheet(url: url, start: start, duration: duration))
            start += duration
        }
        guard !sheets.isEmpty else { return nil }
        self.width = width
        self.height = height
        self.rows = rows
        self.columns = columns
        self.sheets = sheets
        headers = format.headers
    }

    package struct Still: Sendable, Equatable {
        package let sheet: Int
        /// The still's place in its sheet, in pixels.
        package let x: Int
        package let y: Int
        package let width: Int
        package let height: Int
    }

    /// The still nearest `time`. A video's last sheet is rarely full, so its stills are spread over the time it covers at
    /// the pace of the sheets before it.
    package func still(at time: Double) -> Still? {
        guard let index = sheets.lastIndex(where: { $0.start <= max(time, 0) }) else { return nil }
        let sheet = sheets[index]
        let capacity = rows * columns
        let pace = sheets.count > 1 ? sheets[0].duration / Double(capacity) : sheet.duration / Double(capacity)
        guard pace > 0 else { return nil }
        let filled = min(capacity, max(1, Int((sheet.duration / pace).rounded(.up))))
        let cell = min(filled - 1, max(0, Int((time - sheet.start) / pace)))
        return Still(sheet: index, x: (cell % columns) * width, y: (cell / columns) * height, width: width, height: height)
    }
}
