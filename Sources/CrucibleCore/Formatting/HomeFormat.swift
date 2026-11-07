import Foundation

/// Copy and number formatting shared by the Home, section grid and offline Home screens.
package enum HomeFormat {
    /// "2 h 05 m" for an hour or more, "44 min" below that.
    package static func runtime(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = max(60, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            let paddedMinutes = String(format: "%02d", minutes)
            return String(localized: "\(hours) h \(paddedMinutes) m")
        }
        return String(localized: "\(minutes) min")
    }

    /// "31 min left" / "1 h 12 m left" for a partially watched item, nil when nothing remains. Pass
    /// the position a Continue Watching card carries when it differs from the plain stored offset.
    package static func remaining(_ item: PlexMetadata, position: Double? = nil) -> String? {
        guard let seconds = remainingSeconds(item, position: position) else { return nil }
        return runtime(seconds).map { String(localized: "\($0) left") }
    }

    package static func remainingSeconds(_ item: PlexMetadata, position: Double? = nil) -> Double? {
        let duration = item.durationSecs
        let position = position ?? item.resumeSecs
        guard duration > 0, position > 0, position < duration else { return nil }
        return max(60, duration - position)
    }

    /// "12 min in" for a partly watched title whose runtime the server did not send.
    package static func elapsed(_ item: PlexMetadata, position: Double? = nil) -> String? {
        let position = position ?? item.positionSecs
        guard position > 0 else { return nil }
        return runtime(position).map { String(localized: "\($0) in") }
    }

    /// Week total in the "7 h 20 m" style of the This Week card.
    package static func weekTotal(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        let hours = minutes / 60
        if hours > 0 {
            return String(localized: "\(hours) h \(minutes % 60) m")
        }
        return String(localized: "\(minutes) min")
    }

    /// Spelled-out duration for VoiceOver, e.g. "1 hour, 12 minutes".
    package static func spoken(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return String(localized: "less than a minute") }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds) ?? ""
    }

    /// "S2 · E4" followed by an optional tail ("Low Tide", "44 min").
    package static func episodeLine(season: Int?, episode: Int?, tail: String?) -> String {
        var parts = [String]()
        if let season { parts.append(String(localized: "S\(season)")) }
        if let episode { parts.append(String(localized: "E\(episode)")) }
        if let tail, !tail.isEmpty { parts.append(tail) }
        return parts.joined(separator: " · ")
    }

    /// Display title: the show for an episode, the show for a season, the item otherwise.
    package static func title(for item: PlexMetadata) -> String {
        switch item.mediaType {
        case "episode": return item.grandparentTitle ?? item.title
        case "season": return item.parentTitle ?? item.title
        default: return item.title
        }
    }

    /// Hero subtitle: "S2 · E4 · Low Tide" for an episode, "2021 · 2 h 05 m" otherwise.
    package static func heroSubtitle(for item: PlexMetadata) -> String? {
        if item.mediaType == "episode" {
            return episodeLine(season: item.parentIndex, episode: item.index, tail: item.title)
        }
        return joined([item.year.map(String.init), runtime(item.durationSecs)])
    }

    /// Continue Watching card subtitle: "S1 · E3 · Salt and Rope" or "Movie · 2 h 05 m".
    package static func continueSubtitle(for item: PlexMetadata) -> String? {
        if item.mediaType == "episode" {
            return episodeLine(season: item.parentIndex, episode: item.index, tail: item.title)
        }
        return joined([String(localized: "Movie"), runtime(item.durationSecs)])
    }

    /// Up Next poster subtitle: "S2 · E5 · 44 min".
    package static func upNextSubtitle(for item: PlexMetadata) -> String? {
        if item.mediaType == "episode" {
            return episodeLine(season: item.parentIndex, episode: item.index, tail: runtime(item.durationSecs))
        }
        return joined([item.year.map(String.init), runtime(item.durationSecs)])
    }

    /// Recently Added poster subtitle: the year, "Series", the season name, or the episode code.
    package static func recentSubtitle(for item: PlexMetadata) -> String? {
        switch item.mediaType {
        case "show": return item.year.map(String.init) ?? String(localized: "Series")
        case "season": return item.title
        case "episode": return episodeLine(season: item.parentIndex, episode: item.index, tail: item.title)
        default: return item.year.map(String.init)
        }
    }

    /// "Ends at 9:41 PM": when the item would finish if it played from `position` (its saved place, or the start) now.
    /// Nil for a saved place at or past the end, which has nothing left to finish.
    package static func endsAt(_ item: PlexMetadata, position: Double? = nil, now: Date = Date()) -> String? {
        guard ["movie", "episode"].contains(item.mediaType) else { return nil }
        let start = position ?? item.resumeSecs
        let left = start > 0 ? remainingSeconds(item, position: start) : (item.durationSecs > 0 ? item.durationSecs : nil)
        guard let left else { return nil }
        let time = now.addingTimeInterval(left).formatted(date: .omitted, time: .shortened)
        return String(localized: "Ends at \(time)", comment: "When an item that starts playing now would finish, e.g. Ends at 9:41 PM")
    }

    /// Why an episode nobody has started yet deserves a word on Home and the Top Shelf, or nil when it is just the next one.
    package static func episodeNews(_ item: PlexMetadata, now: Date = Date()) -> EpisodeNews? {
        guard item.mediaType == "episode", !item.isWatched, item.resumeSecs == 0 else { return nil }
        let opensSeason = item.index == 1 && (item.parentIndex ?? 0) > 1
        let fresh = isFresh(item, now: now)
        if opensSeason { return fresh ? .newSeason : .seasonPremiere }
        return fresh ? .newEpisode : nil
    }

    /// Arrived on the server in the last week and, when the server knows its air date, aired in the last month: a back
    /// catalogue added today is not news.
    private static func isFresh(_ item: PlexMetadata, now: Date) -> Bool {
        guard let addedAt = item.addedAt, now.timeIntervalSince1970 - Double(addedAt) < 7 * 86_400 else { return false }
        guard let aired = item.originallyAvailableAt.flatMap(airDate) else { return true }
        let age = now.timeIntervalSince(aired)
        return age > -86_400 && age < 30 * 86_400
    }

    private static func airDate(_ text: String) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .gmt, year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// VoiceOver phrase for the season/episode position, e.g. "season 2 episode 4".
    package static func spokenEpisode(season: Int?, episode: Int?) -> String? {
        var parts = [String]()
        if let season { parts.append(String(localized: "season \(season)")) }
        if let episode { parts.append(String(localized: "episode \(episode)")) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    package static func joined(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }
}

/// What sets an unstarted episode apart from simply being the next one.
package enum EpisodeNews: Hashable, Sendable {
    /// Arrived in the last week, aired in the last month.
    case newEpisode
    /// The first episode of a season after the first, which has been on the server a while.
    case seasonPremiere
    /// The first episode of a season after the first, just arrived.
    case newSeason

    /// The short word on the card's artwork.
    package var badge: String {
        switch self {
        case .newEpisode: String(localized: "New", comment: "Badge on an episode that arrived on the server in the last few days")
        case .seasonPremiere: String(localized: "Premiere", comment: "Badge on the first episode of a new season")
        case .newSeason: String(localized: "New Season", comment: "Badge on, and label above, the first episode of a season that just arrived")
        }
    }

    /// The longer label above a title, in place of the row's name.
    package var eyebrow: String {
        switch self {
        case .newEpisode: String(localized: "New Episode", comment: "Label above an episode that arrived on the server in the last few days")
        case .seasonPremiere: String(localized: "Season Premiere", comment: "Label above the first episode of a new season")
        case .newSeason: String(localized: "New Season", comment: "Badge on, and label above, the first episode of a season that just arrived")
        }
    }
}
