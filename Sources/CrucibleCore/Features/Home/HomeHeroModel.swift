import Foundation

/// Platform-neutral display data for the Home hero.
package struct HomeHeroModel: Hashable, Sendable {
    package let id: String
    package let backdropPath: String?
    package let eyebrow: String
    package let title: String
    package let subtitle: String?
    package let actionTitle: String
    package let trailingText: String?
    package let progress: Double?
    package let spokenLabel: String

    package init(item: PlexMetadata, eyebrow: String, cachedArt: [String: String] = [:]) {
        let resuming = HomeMediaRules.isResuming(item)
        id = item.id
        backdropPath = Self.backdropPath(for: item, cachedArt: cachedArt)
        self.eyebrow = eyebrow
        title = HomeFormat.title(for: item)
        subtitle = HomeFormat.heroSubtitle(for: item)
        actionTitle = HomeMediaRules.playTitle(for: item)
        trailingText = HomeFormat.remaining(item) ?? HomeFormat.runtime(item.durationSecs)
        progress = resuming ? item.progressPercent : nil
        let episode = item.mediaType == "episode" ? HomeFormat.spokenEpisode(season: item.parentIndex, episode: item.index) : nil
        spokenLabel = [
            "\(actionTitle) \(title)",
            episode,
            Self.timePhrase(for: item),
        ].compactMap { $0 }.joined(separator: ", ")
    }

    /// Show backdrop for episodes, the item's own backdrop otherwise; the cached snapshot's art
    /// stands in on a cold launch, and the thumb is the last resort.
    package static func backdropPath(for item: PlexMetadata, cachedArt: [String: String]) -> String? {
        if item.mediaType == "episode" {
            return item.grandparentArt ?? item.art ?? cachedArt[item.id] ?? item.thumb
        }
        return item.art ?? cachedArt[item.id] ?? item.thumb ?? item.grandparentThumb
    }

    private static func timePhrase(for item: PlexMetadata) -> String? {
        if let left = HomeFormat.remainingSeconds(item) { return "\(HomeFormat.spoken(left)) left" }
        return item.durationSecs > 0 ? HomeFormat.spoken(item.durationSecs) : nil
    }
}
