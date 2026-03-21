@preconcurrency import UIKit

final class ShowGridViewController: UICollectionViewController {
    private let api: APIClient
    private let sectionId: String
    private var dataSource: UICollectionViewDiffableDataSource<Int, PlexMetadata>!
    private var loadTask: Task<Void, Never>?
    private var currentOffset = 0
    private var totalSize = 0
    private var isLoadingNextPage = false
    private var currentSort = "titleSort:asc"

    init(api: APIClient, sectionId: String) {
        self.api = api
        self.sectionId = sectionId
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.collectionViewLayout = createLayout()
        configureDataSource()
        setupNavigationBar()

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [unowned self] _ in resetAndLoad() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        collectionView.prefetchDataSource = self
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if dataSource.snapshot().numberOfItems == 0 {
            loadPage(offset: 0)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in Theme.gridLayout(environment: environment) }
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, item in
            var config = PosterContentConfiguration()
            config.posterPath = item.thumb
            config.title = item.title
            var parts = [String]()
            let seasons = item.childCount ?? 0
            parts.append(seasons == 1 ? "1 Season" : "\(seasons) Seasons")
            let eps = item.leafCount ?? 0
            parts.append("\(eps) Ep")
            config.subtitle = parts.joined(separator: " · ")
            config.placeholderIcon = "tv"
            if eps > 0, let watched = item.viewedLeafCount {
                config.progress = Double(watched) / Double(eps)
            }
            cell.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }
    }

    private func setupNavigationBar() {
        let sortMenu = UIMenu(title: "Sort", children: [
            UIAction(title: "Name", state: currentSort == "titleSort:asc" ? .on : .off) { [weak self] _ in self?.setSort("titleSort:asc") },
            UIAction(title: "Added", state: currentSort == "addedAt:desc" ? .on : .off) { [weak self] _ in self?.setSort("addedAt:desc") },
            UIAction(title: "Rating", state: currentSort == "rating:desc" ? .on : .off) { [weak self] _ in self?.setSort("rating:desc") },
        ])
        let folderButton = UIBarButtonItem(image: UIImage(systemName: "folder"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            let vc = FolderBrowserViewController(api: api, sectionId: sectionId, folderTitle: "Browse Folders")
            navigationController?.pushViewController(vc, animated: true)
        })
        parent?.navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: sortMenu),
            folderButton,
        ]
    }

    private func setSort(_ sort: String) {
        currentSort = sort
        setupNavigationBar()
        resetAndLoad()
    }

    private func resetAndLoad() {
        currentOffset = 0
        totalSize = 0
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

                var snapshot = dataSource.snapshot()
                if offset == 0 {
                    snapshot = NSDiffableDataSourceSnapshot<Int, PlexMetadata>()
                    snapshot.appendSections([0])
                }
                snapshot.appendItems(items, toSection: 0)
                currentOffset = offset + items.count
                await dataSource.apply(snapshot, animatingDifferences: offset > 0)

                if items.isEmpty && offset == 0 {
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

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let detail = ShowDetailViewController(api: api, showRatingKey: item.id)
        navigationController?.pushViewController(detail, animated: true)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            let watched = item.viewedLeafCount ?? 0
            let total = item.leafCount ?? 0
            let allWatched = total > 0 && watched >= total
            return UIMenu(children: [
                UIAction(title: allWatched ? "Mark All Unwatched" : "Mark All Watched", image: UIImage(systemName: allWatched ? "eye.slash" : "checkmark.circle.fill")) { [weak self] _ in
                    guard let self else { return }
                    Task {
                        if allWatched {
                            try? await self.api.requestVoid(.unscrobble(ratingKey: item.id))
                        } else {
                            try? await self.api.requestVoid(.scrobble(ratingKey: item.id))
                        }
                        self.resetAndLoad()
                    }
                },
            ])
        })
    }
}

extension ShowGridViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let itemCount = dataSource.snapshot().numberOfItems
        let threshold = itemCount - 10
        if indexPaths.contains(where: { $0.item >= threshold }),
           currentOffset < totalSize,
           !isLoadingNextPage
        {
            isLoadingNextPage = true
            loadPage(offset: currentOffset)
        }
    }
}
