import Foundation

package enum LibraryFormat {
    package static func timeLeft(_ item: PlexMetadata) -> String? {
        let remaining = item.durationSecs - item.resumeSecs
        guard item.durationSecs > 0, remaining.isFinite, remaining > 0 else { return nil }
        let minutes = Int((remaining / 60).rounded())
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest > 0 ? "\(hours) h \(rest) m left" : "\(hours) h left"
        }
        return minutes > 0 ? "\(minutes) min left" : "Less than a minute left"
    }

    package static func continueTitle(_ item: PlexMetadata) -> String {
        if item.mediaType == "episode", let show = item.grandparentTitle {
            return show
        }
        return item.title
    }

    package static func continueDetail(_ item: PlexMetadata) -> String {
        var parts = [continueTitle(item)]
        if item.mediaType == "episode", let code = Formatters.episodeCode(item.parentIndex, item.index) {
            parts.append(code)
        }
        if let left = timeLeft(item) { parts.append(left) }
        return parts.joined(separator: " · ")
    }

    /// The caption under a folder-browser poster: a film's year, or an episode's code and show.
    package static func folderMediaSubtitle(_ item: PlexMetadata) -> String? {
        if let year = item.year { return "\(year)" }
        guard let show = item.grandparentTitle else { return nil }
        var parts = [String]()
        if let code = Formatters.episodeCode(item.parentIndex, item.index) { parts.append(code) }
        parts.append(show)
        return parts.joined(separator: " · ")
    }
}
