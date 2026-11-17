import Foundation

/// A video on the web as yt-dlp describes it (`yt-dlp -J`): what it is, who published it, and every way to play it.
package struct WebVideo: Sendable, Decodable {
    package let id: String
    package let title: String
    package let summary: String?
    /// The page the video lives on, which opens it again later.
    package let pageURL: String
    /// The site, as yt-dlp names its extractor ("Youtube", "Vimeo", "Twitch").
    package let site: String
    package let channel: String?
    package let channelID: String?
    package let channelURL: String?
    /// The channel's short name on its site ("@kurzgesagt").
    package let channelHandle: String?
    package let channelFollowers: Int?
    package let isChannelVerified: Bool
    package let duration: Double?
    package let viewCount: Int?
    package let likeCount: Int?
    package let commentCount: Int?
    package let published: Date?
    package let thumbnail: String?
    package let liveStatus: WebLiveStatus
    package let ageLimit: Int
    /// The language the video is spoken in, when the site says.
    package let language: String?
    package let chapters: [WebChapter]
    /// Every picture and sound stream that can play (storyboards and protected streams left out).
    package let formats: [WebFormat]
    package let subtitles: [WebSubtitle]
    /// How much each stretch of the video is replayed, from 0 to 1, when the site publishes it.
    package let heatmap: [WebHeat]
    /// Sheets of small stills along the video, coarsest first.
    package let storyboards: [WebStoryboard]
    package let comments: [WebComment]

    enum CodingKeys: String, CodingKey {
        case id, title, description, channel, uploader, duration, timestamp, thumbnail, language, chapters, formats, subtitles, heatmap, comments, url
        case pageURL = "webpage_url"
        case originalURL = "original_url"
        case site = "extractor_key"
        case channelID = "channel_id"
        case channelURL = "channel_url"
        case uploaderURL = "uploader_url"
        case uploaderID = "uploader_id"
        case channelFollowers = "channel_follower_count"
        case isChannelVerified = "channel_is_verified"
        case viewCount = "view_count"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case releaseTimestamp = "release_timestamp"
        case uploadDate = "upload_date"
        case liveStatus = "live_status"
        case isLive = "is_live"
        case ageLimit = "age_limit"
        case automaticCaptions = "automatic_captions"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = container.text(.title) ?? id
        summary = container.text(.description)
        let original = container.text(.originalURL)
        pageURL = container.text(.pageURL) ?? original ?? id
        site = container.text(.site) ?? "Generic"
        channel = container.text(.channel) ?? container.text(.uploader)
        channelID = container.text(.channelID)
        channelURL = container.text(.channelURL) ?? container.text(.uploaderURL)
        channelHandle = container.text(.uploaderID)
        channelFollowers = container.number(.channelFollowers).map { Int($0) }
        isChannelVerified = (try? container.decodeIfPresent(Bool.self, forKey: .isChannelVerified)) ?? false
        duration = container.number(.duration)
        viewCount = container.number(.viewCount).map { Int($0) }
        likeCount = container.number(.likeCount).map { Int($0) }
        commentCount = container.number(.commentCount).map { Int($0) }
        published = WebDates.published(timestamp: container.number(.timestamp) ?? container.number(.releaseTimestamp),
                                       uploadDate: container.text(.uploadDate))
        thumbnail = container.text(.thumbnail)
        let live = (try? container.decodeIfPresent(Bool.self, forKey: .isLive)) ?? false
        liveStatus = WebLiveStatus(container.text(.liveStatus), isLive: live)
        ageLimit = container.number(.ageLimit).map { Int($0) } ?? 0
        language = container.text(.language)
        chapters = ((try? container.decodeIfPresent([WebChapter].self, forKey: .chapters)) ?? nil) ?? []
        let every = ((try? container.decodeIfPresent([Lossy<WebFormat>].self, forKey: .formats)) ?? nil)?.compactMap(\.value) ?? []
        var playable = every.filter { !$0.isStoryboard && !$0.isProtected && $0.url != nil }
        if playable.isEmpty, let direct = container.text(.url) { playable = [WebFormat(direct: direct)] }
        formats = playable
        storyboards = every.compactMap(WebStoryboard.init).sorted { $0.width < $1.width }
        let manual = ((try? container.decodeIfPresent([String: [WebSubtitle.Source]].self, forKey: .subtitles)) ?? nil) ?? [:]
        let automatic = ((try? container.decodeIfPresent([String: [WebSubtitle.Source]].self, forKey: .automaticCaptions)) ?? nil) ?? [:]
        subtitles = WebSubtitle.list(manual: manual, automatic: automatic, spoken: language)
        heatmap = ((try? container.decodeIfPresent([WebHeat].self, forKey: .heatmap)) ?? nil) ?? []
        comments = ((try? container.decodeIfPresent([Lossy<WebComment>].self, forKey: .comments)) ?? nil)?.compactMap(\.value) ?? []
    }

    /// Whether the video is being broadcast now, so it has no end and no stills.
    package var isLive: Bool { liveStatus == .live }
}

package enum WebLiveStatus: String, Sendable {
    case notLive, live, upcoming, wasLive, postLive

    init(_ text: String?, isLive: Bool) {
        switch text {
        case "is_live": self = .live
        case "is_upcoming": self = .upcoming
        case "was_live": self = .wasLive
        case "post_live": self = .postLive
        default: self = isLive ? .live : .notLive
        }
    }
}

package struct WebChapter: Sendable, Decodable, Equatable {
    package let title: String
    package let start: Double
    package let end: Double

    enum CodingKeys: String, CodingKey {
        case title
        case start = "start_time"
        case end = "end_time"
    }

    package init(title: String, start: Double, end: Double) {
        self.title = title
        self.start = start
        self.end = end
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.text(.title) ?? ""
        start = container.number(.start) ?? 0
        end = container.number(.end) ?? start
    }
}

package struct WebHeat: Sendable, Decodable, Equatable {
    package let start: Double
    package let end: Double
    package let value: Double

    enum CodingKeys: String, CodingKey {
        case value
        case start = "start_time"
        case end = "end_time"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = container.number(.start) ?? 0
        end = container.number(.end) ?? start
        value = container.number(.value) ?? 0
    }
}

package struct WebComment: Sendable, Decodable, Equatable, Identifiable {
    package let id: String
    /// The comment this one answers, or nil for one on the video itself.
    package let parentID: String?
    package let author: String
    package let authorThumbnail: String?
    package let text: String
    package let likeCount: Int?
    package let published: Date?
    package let isPinned: Bool
    package let isByUploader: Bool
    package let isFavorited: Bool

    enum CodingKeys: String, CodingKey {
        case id, parent, author, text, timestamp
        case authorThumbnail = "author_thumbnail"
        case likeCount = "like_count"
        case isPinned = "is_pinned"
        case isByUploader = "author_is_uploader"
        case isFavorited = "is_favorited"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let parent = container.text(.parent)
        parentID = parent == "root" ? nil : parent
        author = container.text(.author) ?? ""
        authorThumbnail = container.text(.authorThumbnail)
        text = container.text(.text) ?? ""
        likeCount = container.number(.likeCount).map { Int($0) }
        published = container.number(.timestamp).map { Date(timeIntervalSince1970: $0) }
        isPinned = (try? container.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
        isByUploader = (try? container.decodeIfPresent(Bool.self, forKey: .isByUploader)) ?? false
        isFavorited = (try? container.decodeIfPresent(Bool.self, forKey: .isFavorited)) ?? false
    }
}

/// An element that decodes to nil instead of failing the list it is in.
struct Lossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

enum WebDates {
    /// When a video was published: its Unix time, else the day yt-dlp gives as "20190901".
    static func published(timestamp: Double?, uploadDate: String?) -> Date? {
        if let timestamp, timestamp > 0 { return Date(timeIntervalSince1970: timestamp) }
        guard let uploadDate, uploadDate.count == 8, let year = Int(uploadDate.prefix(4)), let month = Int(uploadDate.dropFirst(4).prefix(2)),
              let day = Int(uploadDate.suffix(2)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }
}

extension KeyedDecodingContainer {
    /// A number yt-dlp wrote as an integer, a float or text; nil when absent, null or anything else.
    func number(_ key: Key) -> Double? {
        if let value = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return value.isFinite ? value : nil }
        if let text = (try? decodeIfPresent(String.self, forKey: key)) ?? nil { return Double(text) }
        return nil
    }

    /// Text that is there and not empty.
    func text(_ key: Key) -> String? {
        guard let value = (try? decodeIfPresent(String.self, forKey: key)) ?? nil, !value.isEmpty else { return nil }
        return value
    }
}
