@preconcurrency import UIKit

/// Compositional sections shared by the movie/episode and show detail screens.
@MainActor
enum DetailLayout {
    static func fullWidth(top: CGFloat, bottom: CGFloat = 0) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(52))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0)
        return section
    }

    static func castRail() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .absolute(78), heightDimension: .estimated(118))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = 14
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.m, bottom: 0, trailing: Theme.Space.m)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    static func factsGrid() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.5), heightDimension: .estimated(52))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(52))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: 2)
        group.interItemSpacing = .fixed(Theme.Space.m)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 14
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.m, bottom: 0, trailing: Theme.Space.m)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    static func posterRail(bottom: CGFloat = Theme.Space.xl) -> NSCollectionLayoutSection {
        let width = Theme.Size.posterRailWidth
        let size = NSCollectionLayoutSize(
            widthDimension: .absolute(width),
            heightDimension: .estimated(width * Theme.Size.posterAspect + Theme.Size.captionBlockHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = Theme.Space.s
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.m, bottom: bottom, trailing: Theme.Space.m)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    static func header() -> NSCollectionLayoutBoundarySupplementaryItem {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(52))
        return NSCollectionLayoutBoundarySupplementaryItem(layoutSize: size, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    static func posterConfiguration(for item: PlexMetadata) -> PosterContentConfiguration {
        let subtitle: String?
        if item.mediaType == "show", let count = item.childCount, count > 0 {
            subtitle = count == 1 ? "1 season" : "\(count) seasons"
        } else {
            subtitle = item.year.map(String.init)
        }
        return PosterContentConfiguration(
            posterPath: item.posterPath ?? item.grandparentThumb,
            title: item.title,
            subtitle: subtitle,
            progress: item.progressPercent > 0 ? item.progressPercent : nil,
            placeholderIcon: item.mediaType == "show" ? "tv" : "film",
            isUnwatched: item.mediaType != "show" && !item.isWatched && item.positionSecs == 0,
            isDownloaded: DownloadManager.shared.isDownloaded(item.id)
        )
    }
}
