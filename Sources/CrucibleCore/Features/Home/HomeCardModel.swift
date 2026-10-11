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
    package let unwatchedCount: Int?
    package let isWatched: Bool
    package let isPlayable: Bool
    package let showsPlayChip: Bool
    package let usesSeriesPlaceholder: Bool

    package init(item: PlexMetadata, bucket: HomeBucket, layout: Layout) {
        id = item.id
        title = HomeFormat.title(for: item)
        isWatched = HomeMediaRules.isWatched(item)
        isPlayable = HomeMediaRules.isPlayable(item)
        unwatchedCount = HomeMediaRules.unwatchedCount(item)
        progress = item.positionSecs > 0 && item.duration != nil ? item.progressPercent : nil
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
            trailingText = HomeFormat.remaining(item) ?? HomeFormat.runtime(item.durationSecs)
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

    private static func posterSubtitle(for item: PlexMetadata, bucket: HomeBucket) -> String? {
        switch bucket {
        case .upNext, .hero, .continueWatching: return HomeFormat.upNextSubtitle(for: item)
        case .recentlyAdded: return HomeFormat.recentSubtitle(for: item)
        }
    }

    private static func landscapeSubtitle(for item: PlexMetadata, bucket: HomeBucket) -> String? {
        switch bucket {
        case .upNext: return HomeFormat.upNextSubtitle(for: item)
        case .recentlyAdded: return HomeFormat.recentSubtitle(for: item)
        case .hero, .continueWatching: return HomeFormat.continueSubtitle(for: item)
        }
    }
}
