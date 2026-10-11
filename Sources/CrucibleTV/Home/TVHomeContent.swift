import CrucibleCore
import UIKit

enum TVHomeSection: Hashable {
    case hero
    case continueWatching
    case upNext
    case week
    case recentlyAdded

    var bucket: HomeBucket? {
        switch self {
        case .continueWatching: .continueWatching
        case .upNext: .upNext
        case .recentlyAdded: .recentlyAdded
        case .hero, .week: nil
        }
    }
}

enum TVHomeItem: Hashable {
    case hero
    case card(String, HomeBucket)
    case week
    case surprise
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
            progress: model.progress,
            isUnwatched: model.isUnwatched,
            placeholderSymbol: model.usesSeriesPlaceholder ? "tv" : "film"
        )
    }

    static func heroInfo(for media: PlexMetadata, model: HomeHeroModel) -> TVHeroInfo {
        TVHeroInfo(
            eyebrow: model.eyebrow,
            title: model.title,
            metaParts: metaParts(for: media, model: model),
            badges: [media.contentRating].compactMap { $0 },
            synopsis: media.summary,
            progress: model.progress
        )
    }

    private static func metaParts(for media: PlexMetadata, model: HomeHeroModel) -> [String] {
        let year = media.year.map(String.init)
        let parts: [String?]
        switch media.mediaType {
        case "episode":
            parts = [HomeFormat.episodeLine(season: media.parentIndex, episode: media.index, tail: nil), media.title, model.trailingText]
        case "season":
            parts = [media.title, year]
        case "show":
            parts = [year]
        default:
            parts = [year, model.trailingText]
        }
        return parts.compactMap { $0 }.filter { !$0.isEmpty }
    }
}
