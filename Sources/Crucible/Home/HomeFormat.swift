import Foundation

/// Copy and number formatting shared by the Home, section grid and offline Home screens.
enum HomeFormat {
    /// "2 h 05 m" for an hour or more, "44 min" below that.
    static func runtime(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = max(60, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours) h " + String(format: "%02d", minutes) + " m"
        }
        return "\(minutes) min"
    }

    /// "31 min left" / "1 h 12 m left" for a partially watched item, nil when nothing remains.
    static func remaining(_ item: PlexMetadata) -> String? {
        guard let seconds = remainingSeconds(item) else { return nil }
        return runtime(seconds).map { "\($0) left" }
    }

    static func remainingSeconds(_ item: PlexMetadata) -> Double? {
        let duration = item.durationSecs
        let position = item.positionSecs
        guard duration > 0, position > 0, position < duration else { return nil }
        return max(60, duration - position)
    }

    /// Week total in the "7 h 20 m" style of the This Week card.
    static func weekTotal(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        let hours = minutes / 60
        if hours > 0 {
            return "\(hours) h \(minutes % 60) m"
        }
        return "\(minutes) min"
    }

    /// Spelled-out duration for VoiceOver, e.g. "1 hour, 12 minutes".
    static func spoken(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "less than a minute" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds) ?? ""
    }

    /// "S2 · E4" followed by an optional tail ("Low Tide", "44 min").
    static func episodeLine(season: Int?, episode: Int?, tail: String?) -> String {
        var parts = [String]()
        if let season { parts.append("S\(season)") }
        if let episode { parts.append("E\(episode)") }
        if let tail, !tail.isEmpty { parts.append(tail) }
        return parts.joined(separator: " · ")
    }

    /// Display title: the show for an episode, the show for a season, the item otherwise.
    static func title(for item: PlexMetadata) -> String {
        switch item.mediaType {
        case "episode": return item.grandparentTitle ?? item.title
        case "season": return item.parentTitle ?? item.title
        default: return item.title
        }
    }

    /// Hero subtitle: "S2 · E4 · Low Tide" for an episode, "2021 · 2 h 05 m" otherwise.
    static func heroSubtitle(for item: PlexMetadata) -> String? {
        if item.mediaType == "episode" {
            return episodeLine(season: item.parentIndex, episode: item.index, tail: item.title)
        }
        return joined([item.year.map(String.init), runtime(item.durationSecs)])
    }

    /// Continue Watching card subtitle: "S1 · E3 · Salt and Rope" or "Movie · 2 h 05 m".
    static func continueSubtitle(for item: PlexMetadata) -> String? {
        if item.mediaType == "episode" {
            return episodeLine(season: item.parentIndex, episode: item.index, tail: item.title)
        }
        return joined(["Movie", runtime(item.durationSecs)])
    }

    /// Up Next poster subtitle: "S2 · E5 · 44 min".
    static func upNextSubtitle(for item: PlexMetadata) -> String? {
        if item.mediaType == "episode" {
            return episodeLine(season: item.parentIndex, episode: item.index, tail: runtime(item.durationSecs))
        }
        return joined([item.year.map(String.init), runtime(item.durationSecs)])
    }

    /// Recently Added poster subtitle: the year, "Series", the season name, or the episode code.
    static func recentSubtitle(for item: PlexMetadata) -> String? {
        switch item.mediaType {
        case "show": return item.year.map(String.init) ?? "Series"
        case "season": return item.title
        case "episode": return episodeLine(season: item.parentIndex, episode: item.index, tail: item.title)
        default: return item.year.map(String.init)
        }
    }

    /// VoiceOver phrase for the season/episode position, e.g. "season 2 episode 4".
    static func spokenEpisode(season: Int?, episode: Int?) -> String? {
        var parts = [String]()
        if let season { parts.append("season \(season)") }
        if let episode { parts.append("episode \(episode)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func joined(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }
}
