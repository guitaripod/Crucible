@preconcurrency import UIKit

final class ShowGridViewController: UICollectionViewController {
    enum SectionKind: Int, Hashable {
        case continueWatching, grid
    }

    struct GridItem: Hashable {
        let metadata: PlexMetadata
        let section: String

        static func == (lhs: GridItem, rhs: GridItem) -> Bool {
            lhs.metadata.id == rhs.metadata.id && lhs.section == rhs.section
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(metadata.id)
            hasher.combine(section)
        }
    }

    private let api: APIClient
    private let sectionId: String
    private var dataSource: UICollectionViewDiffableDataSource<SectionKind, GridItem>!
    private var loadTask: Task<Void, Never>?
    private var currentOffset = 0
    private var totalSize = 0
    private var isLoadingNextPage = false
    private var currentSort = "titleSort:asc"
    private var continueWatchingItems: [PlexMetadata] = []
    private var gridItems: [PlexMetadata] = []

    init(api: APIClient, sectionId: String) {
        self.api = api
        self.sectionId = sectionId
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDataSource()
        collectionView.collectionViewLayout = createLayout()

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [unowned self] _ in resetAndLoad() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        collectionView.prefetchDataSource = self
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        applyNavItems()
        if dataSource.snapshot().numberOfItems == 0 {
            loadHubs()
            loadPage(offset: 0)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        (parent ?? self).navigationItem.rightBarButtonItems = nil
        loadTask?.cancel()
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44))
        let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)

        return UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let identifiers = dataSource.snapshot().sectionIdentifiers
            guard sectionIndex < identifiers.count else { return nil }
            let sectionId = identifiers[sectionIndex]

            if sectionId == .continueWatching {
                let cardWidth: CGFloat = 140
                let cardHeight: CGFloat = 210
                let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(cardWidth), heightDimension: .absolute(cardHeight))
                let item = NSCollectionLayoutItem(layoutSize: itemSize)
                let groupSize = NSCollectionLayoutSize(widthDimension: .absolute(cardWidth), heightDimension: .absolute(cardHeight))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
                let section = NSCollectionLayoutSection(group: group)
                section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
                section.interGroupSpacing = Theme.spacing
                section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.padding, bottom: Theme.padding, trailing: Theme.padding)
                section.boundarySupplementaryItems = [header]
                return section
            }

            return Theme.gridLayout(environment: environment)
        }
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewCell, GridItem> { [weak self] cell, _, item in
            guard let self else { return }
            var config = PosterContentConfiguration()
            config.posterPath = item.metadata.thumb ?? item.metadata.grandparentThumb
            if item.section == "cw" {
                if let show = item.metadata.grandparentTitle {
                    config.title = show
                    var sub = [String]()
                    if let code = Formatters.episodeCode(item.metadata.parentIndex, item.metadata.index) { sub.append(code) }
                    sub.append(item.metadata.title)
                    config.subtitle = sub.joined(separator: " · ")
                } else {
                    config.title = item.metadata.title
                }
                config.placeholderIcon = "tv"
                config.progress = item.metadata.progressPercent
                config.showPlayButton = true
                config.onQuickPlay = { [weak self] in
                    self?.quickPlay(item.metadata)
                }
            } else {
                config.title = item.metadata.title
                var parts = [String]()
                let seasons = item.metadata.childCount ?? 0
                parts.append(seasons == 1 ? "1 Season" : "\(seasons) Seasons")
                let eps = item.metadata.leafCount ?? 0
                parts.append("\(eps) Ep")
                config.subtitle = parts.joined(separator: " · ")
                config.placeholderIcon = "tv"
                if eps > 0, let watched = item.metadata.viewedLeafCount {
                    config.progress = Double(watched) / Double(eps)
                }
            }
            cell.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { cell, _, _ in
            var config = SectionHeaderConfiguration()
            config.title = "Continue Watching"
            cell.contentConfiguration = config
        }

        dataSource.supplementaryViewProvider = { cv, kind, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func loadHubs() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.sectionHubs(sectionId: sectionId))
                guard !Task.isCancelled else { return }
                var items = [PlexMetadata]()
                for hub in container.Hub ?? [] {
                    let id = (hub.hubIdentifier ?? "").lowercased()
                    if id.contains("continue") || id.contains("inprogress") || id.contains("ondeck") {
                        items.append(contentsOf: hub.Metadata ?? [])
                    }
                }
                continueWatchingItems = items
                applyFullSnapshot()
            } catch {}
        }
    }

    private lazy var optionsButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), menu: nil)

    private func applyNavItems() {
        (parent ?? self).navigationItem.rightBarButtonItems = [optionsButton]
        refreshOptionsMenu()
    }

    private func refreshOptionsMenu() {
        optionsButton.menu = buildOptionsMenu()
    }

    private func buildOptionsMenu() -> UIMenu {
        let sort = UIMenu(title: "Sort By", options: .displayInline, children: [
            sortAction("Name", "titleSort:asc"),
            sortAction("Recently Added", "addedAt:desc"),
            sortAction("Rating", "rating:desc"),
        ])
        let browse = UIAction(title: "Browse Folders", image: UIImage(systemName: "folder")) { [weak self] _ in
            guard let self else { return }
            let vc = FolderBrowserViewController(api: api, sectionId: sectionId, folderTitle: "Browse Folders")
            navigationController?.pushViewController(vc, animated: true)
        }
        return UIMenu(children: [sort, UIMenu(options: .displayInline, children: [browse])])
    }

    private func sortAction(_ title: String, _ sort: String) -> UIAction {
        UIAction(title: title, state: currentSort == sort ? .on : .off) { [weak self] _ in self?.setSort(sort) }
    }

    private func setSort(_ sort: String) {
        currentSort = sort
        refreshOptionsMenu()
        resetAndLoad()
    }

    private func resetAndLoad() {
        currentOffset = 0
        totalSize = 0
        loadHubs()
        loadPage(offset: 0)
    }

    private func loadPage(offset: Int) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(
                    .sectionItems(sectionId: sectionId, sort: currentSort, start: offset, size: 50)
                )
                guard !Task.isCancelled else { return }

                totalSize = container.totalSize ?? 0
                let items = container.Metadata ?? []

                if offset == 0 {
                    gridItems = items
                } else {
                    gridItems.append(contentsOf: items)
                }
                currentOffset = offset + items.count
                applyFullSnapshot()

                if items.isEmpty && offset == 0 && continueWatchingItems.isEmpty {
                    var config = UIContentUnavailableConfiguration.empty()
                    config.image = UIImage(systemName: "tv")
                    config.text = "No shows in library"
                    contentUnavailableConfiguration = config
                } else {
                    contentUnavailableConfiguration = nil
                }

                isLoadingNextPage = false
                collectionView.refreshControl?.endRefreshing()
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingNextPage = false
                collectionView.refreshControl?.endRefreshing()
            }
        }
    }

    private func applyFullSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<SectionKind, GridItem>()

        if !continueWatchingItems.isEmpty {
            snapshot.appendSections([.continueWatching])
            snapshot.appendItems(continueWatchingItems.map { GridItem(metadata: $0, section: "cw") }, toSection: .continueWatching)
        }

        snapshot.appendSections([.grid])
        snapshot.appendItems(gridItems.map { GridItem(metadata: $0, section: "grid") }, toSection: .grid)

        Task {
            await dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let m = item.metadata
        if item.section == "cw", m.mediaType != "show", m.positionSecs > 0 {
            quickPlay(m)
            return
        }
        openDetail(m)
    }

    private func openDetail(_ m: PlexMetadata) {
        if m.mediaType == "episode" {
            let detail = MediaDetailViewController(
                api: api,
                ratingKey: m.id,
                mediaType: "episode",
                showRatingKey: m.grandparentRatingKey,
                seasonRatingKey: m.parentRatingKey
            )
            navigationController?.pushViewController(detail, animated: true)
        } else {
            navigationController?.pushViewController(ShowDetailViewController(api: api, showRatingKey: m.id), animated: true)
        }
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let m = item.metadata
        let watched = m.viewedLeafCount ?? 0
        let total = m.leafCount ?? 0
        let allWatched = total > 0 && watched >= total
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            var actions = [UIMenuElement]()
            if m.mediaType == "episode" {
                actions.append(UIAction(title: m.positionSecs > 0 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                    guard let self else { return }
                    self.quickPlay(m)
                })
            }
            actions.append(UIAction(title: "View Details", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                self?.openDetail(m)
            })
            if m.mediaType == "episode", let showKey = m.grandparentRatingKey {
                actions.append(UIAction(title: "Go to Show", image: UIImage(systemName: "tv")) { [weak self] _ in
                    guard let self else { return }
                    self.navigationController?.pushViewController(ShowDetailViewController(api: self.api, showRatingKey: showKey), animated: true)
                })
            }
            actions.append(UIAction(title: allWatched ? "Mark All Unwatched" : "Mark All Watched", image: UIImage(systemName: allWatched ? "eye.slash" : "checkmark.circle.fill")) { [weak self] _ in
                guard let self else { return }
                Task {
                    if allWatched {
                        try? await self.api.requestVoid(.unscrobble(ratingKey: m.id))
                    } else {
                        try? await self.api.requestVoid(.scrobble(ratingKey: m.id))
                    }
                    self.resetAndLoad()
                }
            })
            return UIMenu(children: actions)
        })
    }

    private var playerCoordinator: PlayerCoordinator?

    private func quickPlay(_ item: PlexMetadata) {
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }
}

extension ShowGridViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let gridSection = dataSource.snapshot().sectionIdentifiers.firstIndex(of: .grid) else { return }
        let gridPaths = indexPaths.filter { $0.section == gridSection }
        guard !gridPaths.isEmpty else { return }
        let itemCount = dataSource.snapshot().numberOfItems(inSection: .grid)
        let threshold = itemCount - 10
        if gridPaths.contains(where: { $0.item >= threshold }),
           currentOffset < totalSize,
           !isLoadingNextPage
        {
            isLoadingNextPage = true
            loadPage(offset: currentOffset)
        }
    }
}
