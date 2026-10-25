import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Compositional sections shared by the movie/episode and show detail screens.
@MainActor
enum DetailLayout {
    /// A row that insets its own content by 16 points. On a large screen the row starts at the screen's gutter and its content stops at
    /// `maxWidth`, so buttons and text keep a readable length instead of spanning the window.
    static func fullWidth(
        top: CGFloat,
        bottom: CGFloat = 0,
        environment: NSCollectionLayoutEnvironment,
        maxWidth: CGFloat? = Theme.readableWidth
    ) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(52))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = rowInsets(top: top, bottom: bottom, environment: environment, maxWidth: maxWidth)
        return section
    }

    /// The section insets that place a self-insetting row as `fullWidth` describes.
    static func rowInsets(
        top: CGFloat,
        bottom: CGFloat = 0,
        environment: NSCollectionLayoutEnvironment,
        maxWidth: CGFloat? = Theme.readableWidth
    ) -> NSDirectionalEdgeInsets {
        let width = environment.container.effectiveContentSize.width
        let row = rowFrame(width: width, room: Theme.Room(environment), maxWidth: maxWidth)
        return NSDirectionalEdgeInsets(top: top, leading: row.leading, bottom: bottom, trailing: width - row.leading - row.width)
    }

    /// Where a self-insetting row sits in a screen `width` wide: flush on a phone, from the gutter and at most `maxWidth` of content on a
    /// large screen.
    private static func rowFrame(width: CGFloat, room: Theme.Room, maxWidth: CGFloat?) -> (leading: CGFloat, width: CGFloat) {
        guard room != .compact else { return (0, width) }
        let leading = room.gutter - Theme.Space.m
        let available = width - leading * 2
        let capped = maxWidth.map { min(available, $0 + Theme.Space.m * 2) } ?? available
        return (leading, capped)
    }

    /// The width of the text inside a full-width row, for measuring where a synopsis truncates.
    static func textWidth(in bounds: CGSize) -> CGFloat {
        let room = Theme.Room(width: bounds.width, height: bounds.height)
        return rowFrame(width: bounds.width, room: room, maxWidth: Theme.readableWidth).width - Theme.Space.m * 2
    }

    static func castRail(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let gutter = Theme.Room(environment).gutter
        let size = NSCollectionLayoutSize(widthDimension: .absolute(78), heightDimension: .estimated(118))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = 14
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: gutter, bottom: 0, trailing: gutter)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    /// Two facts to a row on a phone, three or four across a large screen.
    static func factsGrid(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let room = Theme.Room(environment)
        let columns = room == .compact ? 2 : (room == .regular ? 3 : 4)
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1 / CGFloat(columns)), heightDimension: .estimated(52))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(52))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(Theme.Space.m)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 14
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: room.gutter, bottom: 0, trailing: room.gutter)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    static func posterRail(_ environment: NSCollectionLayoutEnvironment, bottom: CGFloat = Theme.Space.xl) -> NSCollectionLayoutSection {
        let room = Theme.Room(environment)
        let width = room.posterRailWidth
        let size = NSCollectionLayoutSize(
            widthDimension: .absolute(width),
            heightDimension: .estimated(width * Theme.Size.posterAspect + Theme.Size.captionBlockHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = Theme.Space.s
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: room.gutter, bottom: bottom, trailing: room.gutter)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    static func header() -> NSCollectionLayoutBoundarySupplementaryItem {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(52))
        return NSCollectionLayoutBoundarySupplementaryItem(layoutSize: size, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    static func posterConfiguration(for item: PlexMetadata) -> PosterContentConfiguration {
        let card = DetailRelatedCard(item: item)
        return PosterContentConfiguration(
            posterPath: card.posterPath,
            title: card.title,
            subtitle: card.subtitle,
            progress: card.progress,
            placeholderIcon: card.isShow ? "tv" : "film",
            isUnwatched: card.isUnwatched,
            isDownloaded: DownloadManager.shared.isDownloaded(card.id)
        )
    }
}
