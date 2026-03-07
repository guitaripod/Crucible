@preconcurrency import UIKit

final class ShowGridViewController: UICollectionViewController {
    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Int, TvShowSummary>!
    private var loadTask: Task<Void, Never>?
    private var currentPage = 1
    private var totalPages = 1
    private var isLoadingNextPage = false
    private var currentSort = "name"

    init(api: APIClient) {
        self.api = api
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
            loadPage(1)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
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
            group.interItemSpacing = .fixed(12)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 16
            section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
            return section
        }
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewCell, TvShowSummary> { [unowned self] cell, _, item in
            var config = PosterContentConfiguration()
            config.posterPath = item.posterPath
            config.blurhash = item.posterBlurhash
            config.title = item.name
            var parts = [String]()
            parts.append(item.seasonCount == 1 ? "1 Season" : "\(item.seasonCount) Seasons")
            parts.append("\(item.episodeCount) Ep")
            config.subtitle = parts.joined(separator: " · ")
            config.placeholderIcon = "tv"
            if item.episodeCount > 0 {
                config.progress = Double(item.watchedCount) / Double(item.episodeCount)
            }
            config.baseURL = self.api.baseURL
            cell.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }
    }

    private func setupNavigationBar() {
        let sortMenu = UIMenu(title: "Sort", children: [
            UIAction(title: "Name", state: currentSort == "name" ? .on : .off) { [weak self] _ in self?.setSort("name") },
            UIAction(title: "Added", state: currentSort == "added" ? .on : .off) { [weak self] _ in self?.setSort("added") },
            UIAction(title: "Rating", state: currentSort == "rating" ? .on : .off) { [weak self] _ in self?.setSort("rating") },
        ])
        parent?.navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: sortMenu),
        ]
    }

    private func setSort(_ sort: String) {
        currentSort = sort
        setupNavigationBar()
        resetAndLoad()
    }

    private func resetAndLoad() {
        currentPage = 1
        totalPages = 1
        loadPage(1)
    }

    private func loadPage(_ page: Int) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response: PaginatedResponse<TvShowSummary> = try await api.request(
                    .listShows(page: page, sort: currentSort)
                )
                guard !Task.isCancelled else { return }
                totalPages = response.totalPages
                currentPage = response.page

                var snapshot = dataSource.snapshot()
                if page == 1 {
                    snapshot = NSDiffableDataSourceSnapshot<Int, TvShowSummary>()
                    snapshot.appendSections([0])
                }
                snapshot.appendItems(response.items, toSection: 0)
                await dataSource.apply(snapshot, animatingDifferences: page > 1)

                if response.items.isEmpty && page == 1 {
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
        let detail = ShowDetailViewController(api: api, showId: item.id)
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
            return UIMenu(children: [
                UIAction(title: "Mark All Watched", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                    guard let self else { return }
                    Task { try? await self.api.requestVoid(.markShowWatched(showId: item.id)) }
                },
                UIAction(title: "Mark All Unwatched", image: UIImage(systemName: "circle")) { [weak self] _ in
                    guard let self else { return }
                    Task { try? await self.api.requestVoid(.markShowUnwatched(showId: item.id)) }
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
           currentPage < totalPages,
           !isLoadingNextPage
        {
            isLoadingNextPage = true
            loadPage(currentPage + 1)
        }
    }
}
