import CrucibleCore
import UIKit

enum TVHomeSection: Hashable {
    case hero
    case continueWatching
    case upNext
    case week
    case recentlyAdded
    case rateWatched

    var bucket: HomeBucket? {
        switch self {
        case .continueWatching: .continueWatching
        case .upNext: .upNext
        case .recentlyAdded: .recentlyAdded
        case .hero, .week, .rateWatched: nil
        }
    }
}

enum TVHomeItem: Hashable {
    case hero
    case card(String, HomeBucket)
    case rate(String)
    case week
    case surprise
}

/// Numbers only Home uses.
enum TVHomeMetrics {
    static let backdropDimmingDistance: CGFloat = 520
    static let weekTileSize = CGSize(width: 960, height: 260)
}

/// Maps the shared Home models onto the tvOS design-system data.
@MainActor
enum TVHomeContent {
    static func card(for media: PlexMetadata, bucket: HomeBucket) -> TVCardItem {
        let layout: HomeCardModel.Layout = bucket == .recentlyAdded ? .poster : .landscape
        let model = HomeCardModel(item: media, bucket: bucket, layout: layout)
        return TVCardItem(
            id: model.id,
            artworkPath: model.imagePath,
            title: model.title,
            subtitle: model.subtitle,
            detail: model.trailingText,
            eyebrow: model.news?.eyebrow,
            progress: model.progress,
            isUnwatched: model.isUnwatched,
            badgeText: model.news?.badge.localizedUppercase,
            placeholderSymbol: model.usesSeriesPlaceholder ? "tv" : "film"
        )
    }

    static func card(for ask: RatingAsk, now: Date = Date()) -> TVCardItem {
        TVCardItem(
            id: ask.id,
            artworkPath: ask.posterPath,
            title: ask.title,
            subtitle: ask.caption(now: now),
            placeholderSymbol: ask.isShow ? "tv" : "film",
            accessibilityHint: UserRatingCopy.rate
        )
    }

    static func heroInfo(for media: PlexMetadata, model: HomeHeroModel) -> TVHeroInfo {
        TVHeroInfo(
            eyebrow: model.eyebrow,
            title: model.title,
            metaParts: model.metaParts,
            badges: model.badges,
            synopsis: media.summary,
            progress: model.progress,
            accessibilityText: model.accessibilityText
        )
    }
}
