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

    /// How much room a screen has, read from its own size (an iPad window, a Split View half, a phone) and never from the device, so a
    /// narrow iPad window lays out like a phone and a large one gets bigger artwork. A short screen (a phone on its side) stays compact.
    enum Room: Comparable {
        case compact, regular, wide

        init(width: CGFloat, height: CGFloat = .greatestFiniteMagnitude) {
            if width < 600 || height < 500 {
                self = .compact
            } else {
                self = width < 1000 ? .regular : .wide
            }
        }

        @MainActor
        init(_ environment: NSCollectionLayoutEnvironment) {
            let size = environment.container.effectiveContentSize
            self.init(width: size.width, height: environment.container.contentSize.height)
        }

        /// The side margin of content: the phone's 16 points, or the system's 20 once there is room, so rows line up with the large title.
        var gutter: CGFloat { self == .compact ? Space.m : 20 }

        var posterRailWidth: CGFloat {
            switch self {
            case .compact: return Size.posterRailWidth
            case .regular: return 150
            case .wide: return 170
            }
        }

        var landscapeCardWidth: CGFloat {
            switch self {
            case .compact: return Size.landscapeCardWidth
            case .regular: return 288
            case .wide: return 328
            }
        }

        var castWidth: CGFloat { self == .compact ? 78 : 96 }
    }

    /// The widest a column of running text or controls grows on a large screen before it reads as a banner.
    static let readableWidth: CGFloat = 720

    /// Insets that start a section at the gutter and, when `maxWidth` is given, stop it there so text and buttons keep a readable
    /// length on a large screen. On a phone this is the usual 16 points on both sides.
    @MainActor static func sideInsets(_ environment: NSCollectionLayoutEnvironment, maxWidth: CGFloat? = nil) -> NSDirectionalEdgeInsets {
        let room = Room(environment)
        let width = environment.container.effectiveContentSize.width
        let leading = room.gutter
        var trailing = room.gutter
        if let maxWidth, room != .compact {
            trailing = max(trailing, width - leading - maxWidth)
        }
        return NSDirectionalEdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing)
    }

    /// A list section kept to the readable width and centred once the screen is wide enough; a phone keeps the system list insets.
    @MainActor static func centerReadable(_ section: NSCollectionLayoutSection, _ environment: NSCollectionLayoutEnvironment, maxWidth: CGFloat = readableWidth) {
        let width = environment.container.effectiveContentSize.width
        let spare = width - section.contentInsets.leading - section.contentInsets.trailing - maxWidth
        guard Room(environment) != .compact, spare > 0 else { return }
        section.contentInsets.leading += spare / 2
        section.contentInsets.trailing += spare / 2
    }

    /// The Home hero: its phone height, taller with the width on a large screen, never more than half the screen.
    static func heroHeight(width: CGFloat, height: CGFloat) -> CGFloat {
        guard Room(width: width, height: height) != .compact else { return Size.heroCardHeight }
        return max(Size.heroCardHeight, min(width * 0.36, height * 0.5, 440))
    }

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
        let margin = Room(environment).gutter
        let availableWidth = containerWidth - (margin * 2) - (gutter * CGFloat(columns - 1))
        let itemWidth = floor(availableWidth / CGFloat(columns))
        let estimatedHeight = floor(itemWidth * Size.posterAspect) + Size.captionBlockHeight

        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .estimated(estimatedHeight))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimatedHeight))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(gutter)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Space.s + 2
        section.contentInsets = NSDirectionalEdgeInsets(top: Space.s, leading: margin, bottom: Space.m, trailing: margin)
        return section
    }

    /// A horizontally scrolling rail; at the largest accessibility sizes it becomes a vertical grid
    /// of `columns` so captions have room to wrap.
    @MainActor static func railSection(
        width: CGFloat,
        estimatedHeight: CGFloat,
        columns: Int?,
        gutter: CGFloat = Space.m
    ) -> NSCollectionLayoutSection {
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
        layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: gutter, bottom: Theme.Space.xs, trailing: gutter)
        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(51))
        layoutSection.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top),
        ]
        return layoutSection
    }

    /// A phone keeps the preferred count; wider containers add columns so a poster stays near its target width (larger for the
    /// two-column preference), never fewer than the phone's count plus two.
    @MainActor static func gridColumns(forWidth width: CGFloat, preferred: Int = Preferences.libraryColumns) -> Int {
        if width < 500 { return preferred }
        let target: CGFloat = preferred == 2 ? 200 : 150
        let fitting = Int((width - 30) / (target + 10))
        return max(preferred + 2, fitting)
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
