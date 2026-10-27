import Foundation

/// Platform-neutral display data for the Home hero.
package struct HomeHeroModel: Hashable, Sendable {
    package let id: String
    package let backdropPath: String?
    package let eyebrow: String
    package let title: String
    package let subtitle: String?
    package let metaParts: [String]
    package let actionTitle: String
    package let trailingText: String?
    package let progress: Double?
    package let spokenLabel: String
    package let accessibilityText: String

    package init(item: PlexMetadata, eyebrow: String, cachedArt: [String: String] = [:]) {
        let resuming = HomeMediaRules.isResuming(item)
        id = item.id
        backdropPath = Self.backdropPath(for: item, cachedArt: cachedArt)
        self.eyebrow = eyebrow
        title = HomeFormat.title(for: item)
        subtitle = HomeFormat.heroSubtitle(for: item)
        metaParts = Self.metaParts(for: item)
        actionTitle = HomeMediaRules.playTitle(for: item)
        trailingText = HomeFormat.remaining(item) ?? HomeFormat.runtime(item.durationSecs)
        progress = resuming ? item.progressFraction : nil
        let episode = item.mediaType == "episode" ? HomeFormat.spokenEpisode(season: item.parentIndex, episode: item.index) : nil
        let timePhrase = Self.timePhrase(for: item)
        spokenLabel = [
            "\(actionTitle) \(title)",
            episode,
            timePhrase,
        ].compactMap { $0 }.joined(separator: ", ")
        accessibilityText = [eyebrow, title, episode, timePhrase, item.summary]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }

    /// Show backdrop for episodes, the item's own backdrop otherwise; the cached snapshot's art
    /// stands in on a cold launch, and the thumb is the last resort.
    package static func backdropPath(for item: PlexMetadata, cachedArt: [String: String]) -> String? {
        if item.mediaType == "episode" {
            return item.grandparentArt ?? item.art ?? cachedArt[item.id] ?? item.thumb
        }
        return item.art ?? cachedArt[item.id] ?? item.thumb ?? item.grandparentThumb
    }

    /// The facts line of a hero as separate parts, the time left or runtime last: "S2 · E4", the
    /// episode title and "17 min left" for an episode; the year and runtime for a movie.
    private static func metaParts(for item: PlexMetadata) -> [String] {
        let year = item.year.map(String.init)
        let time = HomeFormat.remaining(item) ?? HomeFormat.runtime(item.durationSecs)
        let parts: [String?]
        switch item.mediaType {
        case "episode":
            parts = [HomeFormat.episodeLine(season: item.parentIndex, episode: item.index, tail: nil), item.title, time]
        case "season":
            parts = [item.title, year]
        case "show":
            parts = [year]
        default:
            parts = [year, time]
        }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }
    }

    private static func timePhrase(for item: PlexMetadata) -> String? {
        if let left = HomeFormat.remainingSeconds(item) { return "\(HomeFormat.spoken(left)) left" }
        return item.durationSecs > 0 ? HomeFormat.spoken(item.durationSecs) : nil
    }
}
