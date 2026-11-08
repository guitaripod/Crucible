import Foundation

/// Platform-neutral display data for one Home card; each platform maps it onto its own cell.
package struct HomeCardModel: Hashable, Sendable {
    package enum Layout: Sendable {
        case poster
        case landscape
    }

    package let id: String
    package let title: String
    package let subtitle: String?
    package let imagePath: String?
    package let progress: Double?
    package let trailingText: String?
    package let isUnwatched: Bool
    /// What sets an Up Next episode apart from just being the next one; its `badge` goes on the artwork.
    package let news: EpisodeNews?
    package let unwatchedCount: Int?
    package let isWatched: Bool
    package let isPlayable: Bool
    package let showsPlayChip: Bool
    package let usesSeriesPlaceholder: Bool

    package init(item: PlexMetadata, bucket: HomeBucket, layout: Layout, now: Date = Date()) {
        id = item.id
        title = HomeFormat.title(for: item)
        isWatched = HomeMediaRules.isWatched(item)
        isPlayable = HomeMediaRules.isPlayable(item)
        unwatchedCount = HomeMediaRules.unwatchedCount(item)
        let continuing = bucket == .continueWatching
        let position = continuing ? item.continueSecs : item.resumeSecs
        let fraction = continuing
            ? (item.durationSecs > 0 ? item.continueSecs / item.durationSecs : 0)
            : item.progressFraction
        progress = position > 0 && item.duration != nil ? fraction : nil
        news = bucket == .upNext ? HomeFormat.episodeNews(item, now: now) : nil
        switch layout {
        case .poster:
            subtitle = Self.posterSubtitle(for: item, bucket: bucket)
            imagePath = Self.posterPath(for: item)
            trailingText = nil
            isUnwatched = bucket == .recentlyAdded && HomeMediaRules.isUnwatched(item)
            showsPlayChip = false
            usesSeriesPlaceholder = ["episode", "season", "show"].contains(item.mediaType)
        case .landscape:
            subtitle = Self.landscapeSubtitle(for: item, bucket: bucket)
            imagePath = Self.landscapePath(for: item)
            trailingText = HomeFormat.remaining(item, position: position)
                ?? HomeFormat.elapsed(item, position: position)
                ?? HomeFormat.runtime(item.durationSecs)
            isUnwatched = false
            showsPlayChip = item.mediaType != "show"
            usesSeriesPlaceholder = item.mediaType == "episode"
        }
    }

    private static func posterPath(for item: PlexMetadata) -> String? {
        switch item.mediaType {
        case "episode": return item.grandparentThumb ?? item.thumb
        case "season", "show": return item.thumb ?? item.parentThumb ?? item.grandparentThumb
        default: return item.thumb ?? item.grandparentThumb
        }
    }

    private static func landscapePath(for item: PlexMetadata) -> String? {
        item.mediaType == "episode"
            ? (item.thumb ?? item.grandparentArt ?? item.art)
            : (item.art ?? item.thumb)
    }

    /// An episode names itself (S2 · E5 · Gulls) wherever it is the thing to watch next, as Apple TV's cards do; a movie
    /// gives its year and runtime.
    private static func posterSubtitle(for item: PlexMetadata, bucket: HomeBucket) -> String? {
        switch bucket {
        case .upNext, .hero, .continueWatching:
            return item.mediaType == "episode" ? HomeFormat.continueSubtitle(for: item) : HomeFormat.upNextSubtitle(for: item)
        case .recentlyAdded: return HomeFormat.recentSubtitle(for: item)
        }
    }

    private static func landscapeSubtitle(for item: PlexMetadata, bucket: HomeBucket) -> String? {
        switch bucket {
        case .upNext where item.mediaType == "episode": return HomeFormat.continueSubtitle(for: item)
        case .upNext: return HomeFormat.upNextSubtitle(for: item)
        case .recentlyAdded: return HomeFormat.recentSubtitle(for: item)
        case .hero, .continueWatching: return HomeFormat.continueSubtitle(for: item)
        }
    }
}
