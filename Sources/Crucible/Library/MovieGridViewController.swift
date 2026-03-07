@preconcurrency import UIKit

final class MovieGridViewController: UICollectionViewController {
    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Int, MediaSummary>!
    private var loadTask: Task<Void, Never>?
    private var currentPage = 1
    private var totalPages = 1
    private var isLoadingNextPage = false
    private var currentSort = "title"
    private var currentGenre: String?
    private var allGenres: [String] = []

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
        let cellReg = UICollectionView.CellRegistration<UICollectionViewCell, MediaSummary> { [unowned self] cell, _, item in
            var config = PosterContentConfiguration()
            config.posterPath = item.posterPath
            config.blurhash = item.posterBlurhash
            config.title = item.title
            if let year = item.year { config.subtitle = "\(year)" }
            config.baseURL = self.api.baseURL
            cell.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }
    }

    private func setupNavigationBar() {
        let sortMenu = UIMenu(title: "Sort", children: [
            UIAction(title: "Title", state: currentSort == "title" ? .on : .off) { [weak self] _ in self?.setSort("title") },
            UIAction(title: "Year", state: currentSort == "year" ? .on : .off) { [weak self] _ in self?.setSort("year") },
            UIAction(title: "Added", state: currentSort == "added" ? .on : .off) { [weak self] _ in self?.setSort("added") },
            UIAction(title: "Rating", state: currentSort == "rating" ? .on : .off) { [weak self] _ in self?.setSort("rating") },
        ])

        let sortButton = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: sortMenu)
        let filterButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), primaryAction: nil)
        parent?.navigationItem.rightBarButtonItems = [filterButton, sortButton]

        Task { [weak self] in
            guard let self else { return }
            do {
                let genres: [String] = try await api.request(.listGenres)
                self.allGenres = genres
                self.updateFilterMenu()
            } catch {}
        }
    }

    private func updateFilterMenu() {
        var actions: [UIAction] = [
            UIAction(title: "All", state: currentGenre == nil ? .on : .off) { [weak self] _ in self?.setGenre(nil) },
        ]
        for genre in allGenres {
            actions.append(UIAction(title: genre, state: currentGenre == genre ? .on : .off) { [weak self] _ in self?.setGenre(genre) })
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
        currentPage = 1
        totalPages = 1
        loadPage(1)
    }

    private func loadPage(_ page: Int) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response: PaginatedResponse<MediaSummary> = try await api.request(
                    .listMovies(page: page, sort: currentSort, genre: currentGenre)
                )
                guard !Task.isCancelled else { return }
                totalPages = response.totalPages
                currentPage = response.page

                var snapshot = dataSource.snapshot()
                if page == 1 {
                    snapshot = NSDiffableDataSourceSnapshot<Int, MediaSummary>()
                    snapshot.appendSections([0])
                }
                snapshot.appendItems(response.items, toSection: 0)
                await dataSource.apply(snapshot, animatingDifferences: page > 1)

                if response.items.isEmpty && page == 1 {
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

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let detail = MediaDetailViewController(api: api, mediaId: item.id, mediaType: "movie")
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
                UIAction(title: "Mark Watched", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                    guard let self else { return }
                    Task { try? await self.api.requestVoid(.markWatched(id: item.id)) }
                },
                UIAction(title: "Mark Unwatched", image: UIImage(systemName: "circle")) { [weak self] _ in
                    guard let self else { return }
                    Task { try? await self.api.requestVoid(.markUnwatched(id: item.id)) }
                },
            ])
        })
    }
}

extension MovieGridViewController: UICollectionViewDataSourcePrefetching {
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
