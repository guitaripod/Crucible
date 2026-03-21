@preconcurrency import UIKit

final class MovieGridViewController: UICollectionViewController {
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
    private var currentGenre: String?
    private var allGenres: [(key: String, title: String)] = []
    private var continueWatchingItems: [PlexMetadata] = []

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
        setupNavigationBar()

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [unowned self] _ in resetAndLoad() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        collectionView.prefetchDataSource = self
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if dataSource.snapshot().numberOfItems == 0 {
            loadHubs()
            loadPage(offset: 0)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44))
        let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)

        return UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let sectionId = dataSource.snapshot().sectionIdentifiers[sectionIndex]

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
            config.title = item.metadata.title
            if item.section == "cw" {
                if item.metadata.mediaType == "episode", let show = item.metadata.grandparentTitle {
                    config.title = show
                    var sub = [String]()
                    if let code = Formatters.episodeCode(item.metadata.parentIndex, item.metadata.index) { sub.append(code) }
                    sub.append(item.metadata.title)
                    config.subtitle = sub.joined(separator: " · ")
                    config.placeholderIcon = "tv"
                }
                config.progress = item.metadata.progressPercent
                config.showPlayButton = true
                config.onQuickPlay = { [weak self] in
                    self?.quickPlay(item.metadata)
                }
            } else {
                if let year = item.metadata.year { config.subtitle = "\(year)" }
            }
            cell.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { cell, _, indexPath in
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

    private func setupNavigationBar() {
        let sortMenu = UIMenu(title: "Sort", children: [
            UIAction(title: "Title", state: currentSort == "titleSort:asc" ? .on : .off) { [weak self] _ in self?.setSort("titleSort:asc") },
            UIAction(title: "Year", state: currentSort == "year:desc" ? .on : .off) { [weak self] _ in self?.setSort("year:desc") },
            UIAction(title: "Added", state: currentSort == "addedAt:desc" ? .on : .off) { [weak self] _ in self?.setSort("addedAt:desc") },
            UIAction(title: "Rating", state: currentSort == "rating:desc" ? .on : .off) { [weak self] _ in self?.setSort("rating:desc") },
        ])

        let sortButton = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: sortMenu)
        let filterButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), primaryAction: nil)
        let folderButton = UIBarButtonItem(image: UIImage(systemName: "folder"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let vc = FolderBrowserViewController(api: api, sectionId: sectionId, folderTitle: "Browse Folders")
            navigationController?.pushViewController(vc, animated: true)
        })
        parent?.navigationItem.rightBarButtonItems = [filterButton, sortButton, folderButton]

        Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.sectionGenres(sectionId: sectionId))
                let dirs = container.Directory ?? []
                self.allGenres = dirs.compactMap { d in
                    guard let key = d.key, let title = d.title else { return nil }
                    return (key: key, title: title)
                }
                self.updateFilterMenu()
            } catch {}
        }
    }

    private func updateFilterMenu() {
        var actions: [UIAction] = [
            UIAction(title: "All", state: currentGenre == nil ? .on : .off) { [weak self] _ in self?.setGenre(nil) },
        ]
        for genre in allGenres {
            actions.append(UIAction(title: genre.title, state: currentGenre == genre.key ? .on : .off) { [weak self] _ in self?.setGenre(genre.key) })
        }
        let menu = UIMenu(title: "Genre", children: actions)
        parent?.navigationItem.rightBarButtonItems?.first?.menu = menu
    }

    private func setSort(_ sort: String) {
        currentSort = sort
        setupNavigationBar()
        resetAndLoad()
    }

    private func setGenre(_ genre: String?) {
        currentGenre = genre
        updateFilterMenu()
        resetAndLoad()
    }

    private func resetAndLoad() {
        currentOffset = 0
        totalSize = 0
        loadHubs()
        loadPage(offset: 0)
    }

    private var gridItems: [PlexMetadata] = []

    private func loadPage(offset: Int) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(
                    .sectionItems(sectionId: sectionId, sort: currentSort, genre: currentGenre, start: offset, size: 50)
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
                    config.image = UIImage(systemName: "film")
                    config.text = "No movies in library"
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
        if m.mediaType == "show" {
            let vc = ShowDetailViewController(api: api, showRatingKey: m.id)
            navigationController?.pushViewController(vc, animated: true)
        } else if m.mediaType == "episode" {
            let detail = MediaDetailViewController(api: api, ratingKey: m.id, mediaType: "episode", showRatingKey: m.grandparentRatingKey, seasonRatingKey: m.parentRatingKey)
            navigationController?.pushViewController(detail, animated: true)
        } else {
            let detail = MediaDetailViewController(api: api, ratingKey: m.id, mediaType: "movie")
            navigationController?.pushViewController(detail, animated: true)
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
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: m.positionSecs > 0 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                    guard let self else { return }
                    self.quickPlay(m)
                },
                UIAction(title: m.isWatched ? "Mark Unwatched" : "Mark Watched", image: UIImage(systemName: m.isWatched ? "eye.slash" : "eye")) { [weak self] _ in
                    guard let self else { return }
                    Task {
                        if m.isWatched {
                            try? await self.api.requestVoid(.unscrobble(ratingKey: m.id))
                        } else {
                            try? await self.api.requestVoid(.scrobble(ratingKey: m.id))
                        }
                        self.resetAndLoad()
                    }
                },
            ])
        })
    }

    private var playerCoordinator: PlayerCoordinator?

    private func quickPlay(_ item: PlexMetadata) {
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }
}

extension MovieGridViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let gridSection = dataSource.snapshot().indexOfSection(.grid)
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
