#if DEBUG
import CrucibleDesign
import UIKit

/// Every design-system component on one scrolling screen, fed by fixtures only. Launch the app with
/// `CRUCIBLE_GALLERY=1` (optionally `CRUCIBLE_GALLERY_STYLE=light`). Focus on a Continue Watching card
/// drives the hero text and the backdrop exactly like Home will.
final class TVDesignGalleryViewController: UIViewController, UICollectionViewDelegate {
    private enum Section: Int, CaseIterable {
        case hero
        case continueWatching
        case recentlyAdded
        case episodes
        case cast
        case genres
        case libraries
        case chips
        case buttons
        case settings
        case surface
        case grid
        case states

        var header: TVSectionHeader? {
            switch self {
            case .hero: nil
            case .continueWatching: TVSectionHeader(title: "Continue Watching")
            case .recentlyAdded: TVSectionHeader(title: "Recently Added", secondaryText: "9 titles", seeAllAction: {})
            case .episodes: TVSectionHeader(title: "Season 1", secondaryText: "5 episodes")
            case .cast: TVSectionHeader(title: "Cast & Crew")
            case .genres: TVSectionHeader(title: "Browse Genres")
            case .libraries: TVSectionHeader(title: "Libraries")
            case .chips: TVSectionHeader(title: "Chips")
            case .buttons: TVSectionHeader(title: "Buttons")
            case .settings: TVSectionHeader(title: "Settings Rows")
            case .surface: TVSectionHeader(title: "Focusable Surface")
            case .grid: TVSectionHeader(title: "Grid", secondaryText: "6 columns")
            case .states: TVSectionHeader(title: "States")
            }
        }
    }

    private enum Item: Hashable {
        case hero
        case landscape(TVCardItem)
        case poster(TVCardItem)
        case gridPoster(TVCardItem)
        case episode(TVCardItem)
        case person(TVCardItem)
        case genre(TVTileItem)
        case library(TVTileItem)
        case chip(TVChipItem)
        case buttons
        case row(TVRowItem)
        case surface
        case state(Int)
    }

    private let backdrop = TVBackdropView()
    private lazy var collectionView = TVCollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var chips = TVGalleryFixtures.chips
    private var rows = TVGalleryFixtures.rows
    private var currentHero = TVGalleryFixtures.continueWatching[0].hero
    private let focusMemory = TVFocusMemory()

    override func viewDidLoad() {
        super.viewDidLoad()
        TVImagePipeline.provider = TVGalleryArt.provider
        view.backgroundColor = Theme.Color.canvas
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        view.addSubview(backdrop)
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()
        applySnapshot()
        backdrop.show(path: TVGalleryFixtures.continueWatching[0].backdropPath)
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let section = Section(rawValue: index) else { return TVShelf.poster() }
            return self?.layout(for: section, environment: environment) ?? TVShelf.poster()
        }
    }

    private func layout(for section: Section, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        switch section {
        case .hero:
            let hero = TVShelf.hero()
            hero.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.topInset + 40, leading: 0, bottom: 0, trailing: 0)
            return hero
        case .continueWatching: return TVShelf.landscape()
        case .recentlyAdded: return TVShelf.poster()
        case .episodes: return TVShelf.episode()
        case .cast: return TVShelf.person()
        case .genres: return TVShelf.genre()
        case .libraries: return TVShelf.library()
        case .chips: return TVShelf.chips(header: true)
        case .buttons: return fixedShelf(widths: [1760], height: 140, header: true)
        case .settings:
            let list = TVRowList.section(environment: environment)
            let trailing = max(0, environment.container.effectiveContentSize.width - 900)
            list.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.shelfTopInset, leading: 0, bottom: TVMetrics.shelfBottomInset, trailing: trailing)
            list.boundarySupplementaryItems = [headerItem()]
            return list
        case .surface: return fixedShelf(widths: [780], height: 280, header: true)
        case .grid: return TVShelf.grid(columns: 6, header: true)
        case .states: return fixedShelf(widths: [560, 560, 560], height: 460, header: true)
        }
    }

    private func fixedShelf(widths: [CGFloat], height: CGFloat, header: Bool) -> NSCollectionLayoutSection {
        let items = widths.map { NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .absolute($0), heightDimension: .absolute(height))) }
        let total = widths.reduce(0, +) + TVMetrics.gutter * CGFloat(widths.count - 1)
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(widthDimension: .absolute(total), heightDimension: .absolute(height)),
            subitems: items
        )
        group.interItemSpacing = .fixed(TVMetrics.gutter)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: TVMetrics.shelfTopInset,
            leading: 0,
            bottom: TVMetrics.shelfBottomInset,
            trailing: 0
        )
        if header { section.boundarySupplementaryItems = [headerItem()] }
        return section
    }

    private func headerItem() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(TVMetrics.shelfHeaderHeight)),
            elementKind: TVShelf.headerKind,
            alignment: .top
        )
    }

    private func configureDataSource() {
        let hero = TVHeroCell.registration { [weak self] info in
            guard let self else { return }
            info.configure(self.currentHero)
        }
        let landscape = TVLandscapeCell.registration()
        let poster = TVPosterCell.registration()
        let episode = TVEpisodeCell.registration()
        let person = TVPersonCell.registration()
        let genre = TVGenreCell.registration()
        let library = TVLibraryTile.registration()
        let chip = TVChipCell.registration { [weak self] item in self?.select(chip: item) }
        let buttons = UICollectionView.CellRegistration<GalleryButtonsCell, Int> { _, _, _ in }
        let row = TVRowCell.registration()
        let surface = UICollectionView.CellRegistration<GallerySurfaceCell, Int> { _, _, _ in }
        let state = UICollectionView.CellRegistration<GalleryStateCell, Int> { cell, _, index in cell.configure(index: index) }
        let header = TVSectionHeaderView.registration { indexPath in Section(rawValue: indexPath.section)?.header }

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            let cell: UICollectionViewCell
            switch item {
            case .hero: cell = collectionView.dequeueConfiguredReusableCell(using: hero, for: indexPath, item: 0)
            case .landscape(let data): cell = collectionView.dequeueConfiguredReusableCell(using: landscape, for: indexPath, item: data)
            case .poster(let data), .gridPoster(let data): cell = collectionView.dequeueConfiguredReusableCell(using: poster, for: indexPath, item: data)
            case .episode(let data): cell = collectionView.dequeueConfiguredReusableCell(using: episode, for: indexPath, item: data)
            case .person(let data): cell = collectionView.dequeueConfiguredReusableCell(using: person, for: indexPath, item: data)
            case .genre(let data): cell = collectionView.dequeueConfiguredReusableCell(using: genre, for: indexPath, item: data)
            case .library(let data): cell = collectionView.dequeueConfiguredReusableCell(using: library, for: indexPath, item: data)
            case .chip(let data): cell = collectionView.dequeueConfiguredReusableCell(using: chip, for: indexPath, item: data)
            case .buttons: cell = collectionView.dequeueConfiguredReusableCell(using: buttons, for: indexPath, item: 0)
            case .row(let data): cell = collectionView.dequeueConfiguredReusableCell(using: row, for: indexPath, item: data)
            case .surface: cell = collectionView.dequeueConfiguredReusableCell(using: surface, for: indexPath, item: 0)
            case .state(let index): cell = collectionView.dequeueConfiguredReusableCell(using: state, for: indexPath, item: index)
            }
            cell.accessibilityIdentifier = Self.identifier(for: item, at: indexPath)
            return cell
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private static func identifier(for item: Item, at indexPath: IndexPath) -> String {
        let name = Section(rawValue: indexPath.section).map { "\($0)" } ?? "section"
        return "gallery.\(name).\(indexPath.item)"
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.hero], toSection: .hero)
        snapshot.appendItems(TVGalleryFixtures.continueWatching.map { .landscape($0.card) }, toSection: .continueWatching)
        snapshot.appendItems(TVGalleryFixtures.posters.map { .poster($0) }, toSection: .recentlyAdded)
        snapshot.appendItems(TVGalleryFixtures.episodes.map { .episode($0) }, toSection: .episodes)
        snapshot.appendItems(TVGalleryFixtures.people.map { .person($0) }, toSection: .cast)
        snapshot.appendItems(TVGalleryFixtures.genres.map { .genre($0) }, toSection: .genres)
        snapshot.appendItems(TVGalleryFixtures.libraries.map { .library($0) }, toSection: .libraries)
        snapshot.appendItems(chips.map { .chip($0) }, toSection: .chips)
        snapshot.appendItems([.buttons], toSection: .buttons)
        snapshot.appendItems(rows.map { .row($0) }, toSection: .settings)
        snapshot.appendItems([.surface], toSection: .surface)
        snapshot.appendItems(TVGalleryFixtures.gridPosters.map { .gridPoster($0) }, toSection: .grid)
        snapshot.appendItems([.state(0), .state(1), .state(2)], toSection: .states)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func select(chip selected: TVChipItem) {
        chips = chips.map { var chip = $0; chip.isSelected = chip.id == selected.id; return chip }
        var snapshot = dataSource.snapshot()
        snapshot.deleteItems(snapshot.itemIdentifiers(inSection: .chips))
        snapshot.appendItems(chips.map { .chip($0) }, toSection: .chips)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .row(let item) = dataSource.itemIdentifier(for: indexPath), item.id == "skip" else { return }
        var flipped = item
        flipped.value = item.value == "On" ? "Off" : "On"
        rows = rows.map { $0.id == item.id ? flipped : $0 }
        var snapshot = dataSource.snapshot()
        snapshot.deleteItems(snapshot.itemIdentifiers(inSection: .settings))
        snapshot.appendItems(rows.map { .row($0) }, toSection: .settings)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        focusMemory.preferredIndexPath(in: collectionView)
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        focusMemory.record(context)
        guard let next = context.nextFocusedIndexPath,
              case .landscape(let card)? = dataSource.itemIdentifier(for: next),
              let feature = TVGalleryFixtures.feature(for: card.id)
        else { return }
        currentHero = feature.hero
        backdrop.show(path: feature.backdropPath)
        if let hero = collectionView.cellForItem(at: IndexPath(item: 0, section: Section.hero.rawValue)) as? TVHeroCell {
            hero.infoView.configure(feature.hero, animated: true)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first else { return nil }
        switch dataSource.itemIdentifier(for: indexPath) {
        case .landscape, .poster, .gridPoster, .episode:
            return TVContextMenu.configuration(menu: UIMenu(title: "", children: [
                UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { _ in },
                UIAction(title: "Play from Beginning", image: UIImage(systemName: "gobackward")) { _ in },
                UIAction(title: "Mark Watched", image: UIImage(systemName: "checkmark.circle")) { _ in },
                UIAction(title: "View Details", image: UIImage(systemName: "info.circle")) { _ in },
            ]))
        default:
            return nil
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        backdrop.dimming = max(0, min(1, scrollView.contentOffset.y / 520))
    }
}

private final class GalleryButtonsCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        let menu = UIMenu(title: "", children: ["English (Atmos 5.1)", "French (Stereo)"].map { UIAction(title: $0) { _ in } })
        let buttons = [
            TVButton.make(.primary, title: "Resume · 42m left", symbol: "play.fill") {},
            TVButton.make(.glass, title: "Start Over", symbol: "gobackward") {},
            TVButton.make(.glass, title: "Mark Watched", symbol: "checkmark") {},
            TVButton.menuButton(title: "Audio", menu: menu),
            TVButton.make(.plain, title: "More", symbol: "chevron.right", symbolTrailing: true) {},
        ]
        for (index, button) in buttons.enumerated() { button.accessibilityIdentifier = "gallery.button.\(index)" }
        let stack = UIStackView(arrangedSubviews: buttons + [UIView()])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Theme.Space.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }
}

private final class GallerySurfaceCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        let tile = GalleryStatsTile()
        tile.accessibilityIdentifier = "gallery.surface.tile"
        tile.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tile)
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: contentView.topAnchor),
            tile.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            tile.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }
}

private final class GalleryStatsTile: TVFocusableSurface {
    init() {
        super.init(cornerRadius: Theme.Radius.l)
        let eyebrow = UILabel()
        eyebrow.text = "THIS WEEK"
        eyebrow.font = Theme.Font.caption1
        eyebrow.textColor = Theme.Color.accentText
        let total = UILabel()
        total.text = "12h 40m"
        total.font = Theme.Font.title2
        total.textColor = Theme.Color.label
        let delta = UILabel()
        delta.text = "+2h 05m vs last week"
        delta.font = Theme.Font.callout
        delta.textColor = Theme.Color.labelSecondary
        let text = UIStackView(arrangedSubviews: [eyebrow, total, delta, UIView()])
        text.axis = .vertical
        text.spacing = Theme.Space.xxs

        let bars = UIStackView(arrangedSubviews: [0.4, 0.7, 0.3, 0.9, 0.55, 1.0, 0.45].map { fraction -> UIView in
            let bar = UIView()
            bar.backgroundColor = Theme.Color.accent
            bar.layer.cornerRadius = 8
            bar.heightAnchor.constraint(equalToConstant: 160 * fraction).isActive = true
            bar.widthAnchor.constraint(equalToConstant: 28).isActive = true
            return bar
        })
        bars.axis = .horizontal
        bars.alignment = .bottom
        bars.spacing = Theme.Space.xs

        let row = UIStackView(arrangedSubviews: [text, bars])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
        accessibilityLabel = "This week, 12 hours 40 minutes, plus 2 hours 5 minutes versus last week"
        contextMenuProvider = { UIMenu(title: "", children: [UIAction(title: "Open Statistics", image: UIImage(systemName: "chart.bar")) { _ in }]) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private final class GalleryStateCell: UICollectionViewCell {
    private let stateView = TVStateView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        contentView.backgroundColor = Theme.Color.surface
        contentView.layer.cornerRadius = Theme.Radius.l
        contentView.layer.cornerCurve = .continuous
        stateView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    func configure(index: Int) {
        switch index {
        case 0: stateView.show(.loading(title: "Loading Library"))
        case 1: stateView.show(.empty(title: "No Matches", message: "Nothing fits these filters.", symbol: "line.3.horizontal.decrease.circle", action: TVStateView.Action(title: "Clear Filters") {}))
        default: stateView.show(.error(title: "Couldn't Load Library", message: "Check the connection and try again.", retryTitle: "Try Again") {})
        }
    }
}
#endif
