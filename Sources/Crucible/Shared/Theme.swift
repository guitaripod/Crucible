import UIKit

enum Theme {
    enum Color {
        static let canvas = dynamic(dark: 0x181818, light: 0xF4F2EF)
        static let surface = dynamic(dark: 0x232221, light: 0xFFFFFF)
        static let surfaceRaised = dynamic(dark: 0x2D2B29, light: 0xEBE8E3)
        static let surfaceHigh = dynamic(dark: 0x3A3734, light: 0xDCD8D2)

        static let separator = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.09)
                : UIColor.black.withAlphaComponent(0.09)
        }

        static let label = dynamic(dark: 0xF6F3EF, light: 0x1A1816)

        static let labelSecondary = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: 0xF6F3EF).withAlphaComponent(0.68)
                : UIColor(hex: 0x1A1816).withAlphaComponent(0.72)
        }

        static let labelTertiary = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: 0xF6F3EF).withAlphaComponent(0.52)
                : UIColor(hex: 0x1A1816).withAlphaComponent(0.62)
        }

        static let accent = dynamic(dark: 0xFF9F0A, light: 0xFF9500)
        static let accentText = dynamic(dark: 0xFF9F0A, light: 0xA85800)
        static let onAccent = UIColor(hex: 0x1B1204)
        static let accentTint = accent.withAlphaComponent(0.16)

        static let destructive = UIColor.systemRed
        static let statusOK = UIColor.systemGreen

        static let onArt = UIColor.white
        static let onArtSecondary = UIColor.white.withAlphaComponent(0.78)
        static let artHairline = UIColor.white.withAlphaComponent(0.10)

        private static func dynamic(dark: UInt32, light: UInt32) -> UIColor {
            UIColor { trait in
                UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
            }
        }
    }

    enum Font {
        static var largeTitle: UIFont { scaled(.largeTitle, 34, .bold) }
        static var title1: UIFont { scaled(.title1, 28, .bold) }
        static var title2: UIFont { scaled(.title2, 22, .bold) }
        static var title3: UIFont { scaled(.title3, 20, .semibold) }
        static var headline: UIFont { scaled(.headline, 17, .semibold) }
        static var body: UIFont { scaled(.body, 17, .regular) }
        static var callout: UIFont { scaled(.callout, 16, .regular) }
        static var subheadline: UIFont { scaled(.subheadline, 15, .regular) }
        static var subheadlineSemibold: UIFont { scaled(.subheadline, 15, .semibold) }
        static var footnote: UIFont { scaled(.footnote, 13, .regular) }
        static var footnoteSemibold: UIFont { scaled(.footnote, 13, .semibold) }
        static var caption1: UIFont { scaled(.caption1, 12, .semibold) }
        static var caption1Regular: UIFont { scaled(.caption1, 12, .regular) }
        static var caption2: UIFont { scaled(.caption2, 11, .bold) }
        static var caption2Regular: UIFont { scaled(.caption2, 11, .regular) }
        static var buttonLabel: UIFont { scaled(.headline, 17, .semibold, maximum: 24) }

        static func scaled(_ style: UIFont.TextStyle, _ size: CGFloat, _ weight: UIFont.Weight, maximum: CGFloat? = nil) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            let metrics = UIFontMetrics(forTextStyle: style)
            if let maximum {
                return metrics.scaledFont(for: base, maximumPointSize: maximum)
            }
            return metrics.scaledFont(for: base)
        }
    }

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let xs: CGFloat = 6
        static let s: CGFloat = 10
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let hero: CGFloat = 28
    }

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

    static let accent = Color.accent
    static let accentSubtle = Color.accentTint

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

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
