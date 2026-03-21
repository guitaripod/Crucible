import UIKit

enum Theme {
    static let accent = UIColor.systemOrange
    static let accentSubtle = UIColor.systemOrange.withAlphaComponent(0.15)

    static let cornerRadius: CGFloat = 12
    static let cornerRadiusSmall: CGFloat = 6
    static let cornerRadiusLarge: CGFloat = 16

    static let padding: CGFloat = 16
    static let spacingSmall: CGFloat = 8
    static let spacingMedium: CGFloat = 12
    static let spacing: CGFloat = 10
    static let buttonHeight: CGFloat = 44

    @MainActor static func quickPlay(api: APIClient, item: PlexMetadata, from vc: UIViewController) -> PlayerCoordinator {
        let meta = PlayerCoordinator.Metadata(
            title: item.title,
            showName: item.grandparentTitle,
            seasonNumber: item.parentIndex,
            episodeNumber: item.index,
            posterPath: item.thumb ?? item.grandparentThumb,
            duration: item.durationSecs
        )
        let coordinator = PlayerCoordinator(
            api: api,
            ratingKey: item.id,
            mediaType: item.mediaType,
            showRatingKey: item.grandparentRatingKey,
            seasonRatingKey: item.parentRatingKey,
            resumePosition: item.positionSecs,
            metadata: meta
        )
        coordinator.present(from: vc)
        return coordinator
    }

    static func gridLayout(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = environment.container.effectiveContentSize.width
        let columns: Int
        if width < 400 { columns = 2 }
        else if width < 700 { columns = 3 }
        else { columns = 4 }

        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
            heightDimension: .estimated(280)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(280))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        group.interItemSpacing = .fixed(spacing)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = padding
        section.contentInsets = NSDirectionalEdgeInsets(top: spacingMedium, leading: padding, bottom: padding, trailing: padding)
        return section
    }
}
