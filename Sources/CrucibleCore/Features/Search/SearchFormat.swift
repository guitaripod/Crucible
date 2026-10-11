package enum SearchFormat {
    package static func episodeCode(_ item: PlexMetadata) -> String? {
        guard let season = item.parentIndex, let episode = item.index else { return nil }
        return "S\(season) E\(episode)"
    }

    /// The "S# E# · Title" line shown under an episode's show name.
    package static func episodeSubtitle(_ item: PlexMetadata) -> String {
        [episodeCode(item), item.title].compactMap { $0 }.joined(separator: " · ")
    }

    package static func typeLine(for item: PlexMetadata) -> String {
        var parts = [String]()
        switch item.mediaType {
        case "show":
            parts.append("Show")
            if let year = item.year { parts.append("\(year)") }
            if let seasons = item.childCount, seasons > 0 {
                parts.append(seasons == 1 ? "1 season" : "\(seasons) seasons")
            }
        case "episode":
            parts.append("Episode")
            if let code = episodeCode(item) { parts.append(code) }
            if let show = item.grandparentTitle { parts.append(show) }
        default:
            parts.append("Movie")
            if let year = item.year { parts.append("\(year)") }
            let duration = Formatters.duration(item.durationSecs)
            if !duration.isEmpty { parts.append(duration) }
        }
        return parts.joined(separator: " · ")
    }
}
