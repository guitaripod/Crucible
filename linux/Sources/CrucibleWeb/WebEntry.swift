import Foundation

/// A video as a list shows it: enough for a card, and the address that opens it.
package struct WebEntry: Sendable, Codable, Hashable, Identifiable {
    package enum Kind: String, Sendable, Codable {
        case video, playlist, channel
    }

    package let id: String
    /// The page of the video, playlist or channel.
    package let url: String
    package var kind: Kind
    package var title: String
    package var channel: String?
    package var channelID: String?
    package var channelURL: String?
    package var duration: Double?
    package var viewCount: Int?
    package var published: Date?
    package var thumbnail: String?
    package var isLive: Bool
    package var isUpcoming: Bool
    /// A vertical clip of a minute or so, which the site keeps on a shelf of its own.
    package var isShort: Bool

    package init(id: String, url: String, kind: Kind = .video, title: String, channel: String? = nil, channelID: String? = nil, channelURL: String? = nil,
                 duration: Double? = nil, viewCount: Int? = nil, published: Date? = nil, thumbnail: String? = nil, isLive: Bool = false,
                 isUpcoming: Bool = false, isShort: Bool = false) {
        self.id = id
        self.url = url
        self.kind = kind
        self.title = title
        self.channel = channel
        self.channelID = channelID
        self.channelURL = channelURL
        self.duration = duration
        self.viewCount = viewCount
        self.published = published
        self.thumbnail = thumbnail
        self.isLive = isLive
        self.isUpcoming = isUpcoming
        self.isShort = isShort
    }

    /// The card of a video that was opened in full.
    package init(_ video: WebVideo) {
        self.init(id: video.id, url: video.pageURL, title: video.title, channel: video.channel, channelID: video.channelID, channelURL: video.channelURL,
                  duration: video.duration, viewCount: video.viewCount, published: video.published, thumbnail: video.thumbnail,
                  isLive: video.liveStatus == .live, isUpcoming: video.liveStatus == .upcoming, isShort: video.pageURL.contains("/shorts/"))
    }

    /// The thumbnail addresses to try, sharpest first. YouTube keeps a 1280 pixel picture for most videos and a 320 pixel
    /// one for every video, both sixteen by nine; what a list or a feed names comes between them.
    package var thumbnailCandidates: [String] {
        var candidates: [String] = []
        if let video = WebLink.youTubeVideoID(in: url) ?? (kind == .video && id.count == 11 && url.contains("youtu") ? id : nil) {
            candidates.append("https://i.ytimg.com/vi/\(video)/hq720.jpg")
            if let thumbnail, !thumbnail.contains("/hqdefault") { candidates.append(thumbnail) }
            candidates.append("https://i.ytimg.com/vi/\(video)/mqdefault.jpg")
        } else if let thumbnail {
            candidates.append(thumbnail)
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }
}

/// An entry of a yt-dlp list (`--flat-playlist`), in yt-dlp's own words.
struct ListedEntry: Sendable, Decodable {
    let id: String
    let url: String?
    let title: String?
    let extractor: String?
    let channel: String?
    let channelID: String?
    let channelURL: String?
    let duration: Double?
    let viewCount: Int?
    let timestamp: Double?
    let liveStatus: String?
    let thumbnails: [WebThumbnail]

    enum CodingKeys: String, CodingKey {
        case id, url, title, channel, uploader, duration, timestamp, thumbnails
        case extractor = "ie_key"
        case channelID = "channel_id"
        case channelURL = "channel_url"
        case viewCount = "view_count"
        case releaseTimestamp = "release_timestamp"
        case liveStatus = "live_status"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = container.text(.url)
        title = container.text(.title)
        extractor = container.text(.extractor)
        channel = container.text(.channel) ?? container.text(.uploader)
        channelID = container.text(.channelID)
        channelURL = container.text(.channelURL)
        duration = container.number(.duration)
        viewCount = container.number(.viewCount).map { Int($0) }
        timestamp = container.number(.timestamp) ?? container.number(.releaseTimestamp)
        liveStatus = container.text(.liveStatus)
        thumbnails = ((try? container.decodeIfPresent([WebThumbnail].self, forKey: .thumbnails)) ?? nil) ?? []
    }

    /// The card for this entry, with the list's own channel where the entry names none (a channel's tab). Entries
    /// without a title or an address (removed and private videos) give nil.
    func entry(channel listChannel: String?, channelID listChannelID: String?, channelURL listChannelURL: String?) -> WebEntry? {
        guard let url, let title, title != "[Private video]", title != "[Deleted video]" else { return nil }
        let kind: WebEntry.Kind
        switch WebLink(url) {
        case .playlist: kind = .playlist
        case .channel: kind = .channel
        default: kind = .video
        }
        return WebEntry(id: id, url: url, kind: kind, title: title, channel: channel ?? listChannel, channelID: channelID ?? listChannelID,
                        channelURL: channelURL ?? listChannelURL, duration: duration, viewCount: viewCount,
                        published: timestamp.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                        thumbnail: thumbnails.max { ($0.width ?? 0) < ($1.width ?? 0) }?.url ?? thumbnails.last?.url,
                        isLive: liveStatus == "is_live", isUpcoming: liveStatus == "is_upcoming", isShort: url.contains("/shorts/"))
    }
}
