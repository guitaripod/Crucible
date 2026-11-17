import CrucibleCore
import CrucibleWeb
import Foundation

/// How web video's facts read on a card and in the player.
enum WebFormatting {
    /// A site's name as people write it; yt-dlp names its YouTube extractor "Youtube".
    static func siteName(_ site: String) -> String {
        switch site {
        case "Youtube", "YoutubeTab", "YoutubeSearch": "YouTube"
        case "Generic": String(localized: "the web", comment: "Where a web video comes from when yt-dlp names no site")
        default: site
        }
    }

    /// "1.2M views", in the app's language.
    static func views(_ count: Int) -> String {
        String(localized: "\(Formatters.compactCount(count)) views", comment: "How often a web video was watched, as in \"1.2M views\"")
    }

    /// "1.2M views · 3 days ago", with whichever of the two the entry has.
    static func facts(_ entry: WebEntry) -> String? {
        var parts: [String] = []
        if entry.isLive {
            parts.append(String(localized: "Live now", comment: "A web video that is being broadcast now"))
        } else if entry.isUpcoming {
            parts.append(String(localized: "Upcoming", comment: "A web video scheduled to premiere or go live later"))
        }
        if let count = entry.viewCount, count > 0 { parts.append(views(count)) }
        if let published = entry.published, let age = Formatters.unixRelativeDate(Int(published.timeIntervalSince1970)) { parts.append(age) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The channel and the facts on one line, for a card's second line.
    static func byline(_ entry: WebEntry) -> String? {
        let parts = [entry.channel, facts(entry)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
