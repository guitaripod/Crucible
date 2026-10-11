import UIKit

/// Compositional-layout section builders. Every screen assembles its shelves from these, so margins,
/// spacing and the room left for focus growth are decided once.
@MainActor
enum TVShelf {
    static let headerKind = "tv.shelf.header"

    /// Sections sit inside the safe area (80pt at the sides on tvOS), so the horizontal insets stay
    /// zero and the margin follows whatever the screen reports.
    private static let shelfInsets = NSDirectionalEdgeInsets(
        top: TVMetrics.shelfTopInset,
        leading: 0,
        bottom: TVMetrics.shelfBottomInset,
        trailing: 0
    )

    static func poster(header: Bool = true) -> NSCollectionLayoutSection {
        shelf(itemSize: TVCardStyle.poster.itemSize, header: header)
    }

    static func landscape(header: Bool = true) -> NSCollectionLayoutSection {
        shelf(itemSize: TVCardStyle.landscape.itemSize, header: header)
    }

    static func episode(header: Bool = true) -> NSCollectionLayoutSection {
        shelf(itemSize: TVCardStyle.episode.itemSize, header: header)
    }

    static func person(header: Bool = true) -> NSCollectionLayoutSection {
        shelf(itemSize: TVCardStyle.person.itemSize, header: header)
    }

    static func genre(header: Bool = true) -> NSCollectionLayoutSection {
        shelf(itemSize: TVMetrics.Card.genreSize, header: header)
    }

    static func library(header: Bool = true) -> NSCollectionLayoutSection {
        shelf(itemSize: TVMetrics.Card.libraryTileSize, header: header)
    }

    /// A horizontally scrolling row of self-sizing capsules (filters, seasons, recent searches).
    static func chips(header: Bool = false) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(
            widthDimension: .estimated(220),
            heightDimension: .absolute(TVMetrics.Control.chipHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        configureOrthogonal(section)
        section.contentInsets = shelfInsets
        if header { section.boundarySupplementaryItems = [headerItem()] }
        return section
    }

    /// A vertical grid; the card width is whatever divides the safe width into `columns` with 40pt gutters.
    static func grid(
        columns: Int = 6,
        itemHeight: CGFloat = TVCardStyle.poster.itemSize.height,
        header: Bool = false
    ) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
            heightDimension: .fractionalHeight(1)
        ))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(itemHeight)),
            repeatingSubitem: item,
            count: columns
        )
        group.interItemSpacing = .fixed(TVMetrics.gutter)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = TVMetrics.gridRowSpacing
        section.contentInsets = shelfInsets
        if header { section.boundarySupplementaryItems = [headerItem()] }
        return section
    }

    /// One full-width, fixed-height block above the shelves; hosts the hero info and never takes focus.
    static func hero(height: CGFloat = TVMetrics.Hero.height) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .fractionalHeight(1)
        ))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(height)),
            subitems: [item]
        )
        return NSCollectionLayoutSection(group: group)
    }

    private static func shelf(itemSize: CGSize, header: Bool) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(
            widthDimension: .absolute(itemSize.width),
            heightDimension: .absolute(itemSize.height)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        configureOrthogonal(section)
        section.contentInsets = shelfInsets
        if header { section.boundarySupplementaryItems = [headerItem()] }
        return section
    }

    private static func configureOrthogonal(_ section: NSCollectionLayoutSection) {
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = TVMetrics.gutter
    }

    private static func headerItem() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .absolute(TVMetrics.shelfHeaderHeight)
            ),
            elementKind: headerKind,
            alignment: .top
        )
    }
}
