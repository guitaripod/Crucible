import CrucibleCore
import CrucibleDesign
import UIKit

extension Theme {
    enum Size {
        static let posterRailWidth: CGFloat = 120
        static let landscapeCardWidth: CGFloat = 232
        static let landscapeCardHeight: CGFloat = 130
        static let episodeThumbWidth: CGFloat = 132
        static let castAvatar: CGFloat = 72
        static let primaryButtonHeight: CGFloat = 52
        static let iconButton: CGFloat = 44
        static let minTarget: CGFloat = 44
        static let heroCardHeight: CGFloat = 288
        static let posterAspect: CGFloat = 1.5
        static let captionBlockHeight: CGFloat = 50
    }

    static let cornerRadius: CGFloat = Radius.s
    static let cornerRadiusSmall: CGFloat = Radius.xs
    static let cornerRadiusLarge: CGFloat = Radius.m

    static let padding: CGFloat = Space.m
    static let spacingSmall: CGFloat = Space.xs
    static let spacingMedium: CGFloat = Space.s
    static let spacing: CGFloat = 10
    static let buttonHeight: CGFloat = Size.iconButton

    @MainActor static func quickPlay(api: APIClient, item: PlexMetadata, from vc: UIViewController) -> PlayerCoordinator {
        AppLogger.notice("Quick play tapped ratingKey=\(item.id) type=\(item.mediaType)", .playback)
        let meta = PlayerCoordinator.Metadata(
            title: item.title,
            showName: item.grandparentTitle,
            seasonNumber: item.parentIndex,
            episodeNumber: item.index,
            posterPath: item.thumb ?? item.grandparentThumb,
            duration: item.durationSecs
        )
        let offlineAsset = DownloadManager.shared.offlineAsset(for: item.id)
        let resumePosition = offlineAsset != nil
            ? (DownloadManager.shared.item(for: item.id)?.resumeSecs ?? item.positionSecs)
            : item.positionSecs
        let coordinator = PlayerCoordinator(
            api: api,
            ratingKey: item.id,
            mediaType: item.mediaType,
            showRatingKey: item.grandparentRatingKey,
            seasonRatingKey: item.parentRatingKey,
            resumePosition: resumePosition,
            metadata: meta,
            offlineAsset: offlineAsset
        )
        coordinator.present(from: vc)
        return coordinator
    }

    /// Poster grid whose column count follows the library-density preference, so a phone shows three
    /// columns by default and two on request; wider containers add columns on top of that.
    @MainActor static func gridLayout(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let containerWidth = environment.container.effectiveContentSize.width
        let columns = gridColumns(forWidth: containerWidth)
        let gutter: CGFloat = 10
        let availableWidth = containerWidth - (Space.m * 2) - (gutter * CGFloat(columns - 1))
        let itemWidth = floor(availableWidth / CGFloat(columns))
        let estimatedHeight = floor(itemWidth * Size.posterAspect) + Size.captionBlockHeight

        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .estimated(estimatedHeight))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimatedHeight))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(gutter)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Space.s + 2
        section.contentInsets = NSDirectionalEdgeInsets(top: Space.s, leading: Space.m, bottom: Space.m, trailing: Space.m)
        return section
    }

    /// A horizontally scrolling rail; at the largest accessibility sizes it becomes a vertical grid
    /// of `columns` so captions have room to wrap.
    @MainActor static func railSection(width: CGFloat, estimatedHeight: CGFloat, columns: Int?) -> NSCollectionLayoutSection {
        let layoutSection: NSCollectionLayoutSection
        if let columns {
            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .estimated(estimatedHeight))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimatedHeight))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
            group.interItemSpacing = .fixed(Theme.Space.s)
            layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.interGroupSpacing = Theme.Space.m
        } else {
            let size = NSCollectionLayoutSize(widthDimension: .absolute(width), heightDimension: .estimated(estimatedHeight))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
            layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
            layoutSection.interGroupSpacing = Theme.Space.s
        }
        layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.m, bottom: Theme.Space.xs, trailing: Theme.Space.m)
        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(51))
        layoutSection.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top),
        ]
        return layoutSection
    }

    @MainActor static func gridColumns(forWidth width: CGFloat) -> Int {
        let preferred = Preferences.libraryColumns
        if width < 500 { return preferred }
        if width < 800 { return preferred + 2 }
        return preferred + 3
    }

    /// Standard flat-card surface for grouped list cells so every inset-grouped screen shares one look.
    @MainActor static func groupedCellBackground() -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Color.surface
        background.cornerRadius = Radius.m
        return background
    }

    @MainActor static func groupedListConfiguration() -> UICollectionLayoutListConfiguration {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.backgroundColor = Color.canvas
        return config
    }
}
