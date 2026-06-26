@preconcurrency import UIKit

final class SearchViewController: UICollectionViewController, UISearchResultsUpdating {
    private let api: APIClient
    private var searchTask: Task<Void, Never>?
    private var dataSource: UICollectionViewDiffableDataSource<Int, PlexMetadata>!
    private let searchController = UISearchController()

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search"
        navigationController?.navigationBar.prefersLargeTitles = true

        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Movies, shows, episodes..."
        searchController.searchBar.tintColor = .systemOrange
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        collectionView.collectionViewLayout = createLayout()
        configureDataSource()

        var config = UIContentUnavailableConfiguration.search()
        config.text = "Search your library"
        contentUnavailableConfiguration = config
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        searchTask?.cancel()
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfig.showsSeparators = true
        return UICollectionViewCompositionalLayout.list(using: listConfig)
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, result in
            var config = SearchResultConfiguration()
            config.posterPath = result.thumb ?? result.grandparentThumb
            config.title = result.title
            config.mediaType = result.mediaType

            var subtitleParts = [String]()
            if let year = result.year { subtitleParts.append("\(year)") }
            if let code = Formatters.episodeCode(result.parentIndex, result.index) {
                subtitleParts.append(code)
            }
            if let showName = result.grandparentTitle { subtitleParts.append(showName) }
            config.subtitle = subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")
            cell.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: item)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        searchTask?.cancel()
        guard let query = searchController.searchBar.text, query.count >= 2 else {
            Task { [weak self] in
                guard let self else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Int, PlexMetadata>()
                snapshot.appendSections([0])
                await dataSource.apply(snapshot)
                var config = UIContentUnavailableConfiguration.search()
                config.text = "Search your library"
                contentUnavailableConfiguration = config
            }
            return
        }

        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            do {
                let container = try await api.requestContainer(.search(query: query))
                guard !Task.isCancelled else { return }

                var results = [PlexMetadata]()
                for hub in container.Hub ?? [] {
                    results.append(contentsOf: hub.Metadata ?? [])
                }

                var seen = Set<String>()
                results = results.filter { seen.insert($0.id).inserted }

                var snapshot = NSDiffableDataSourceSnapshot<Int, PlexMetadata>()
                snapshot.appendSections([0])
                snapshot.appendItems(results, toSection: 0)
                await dataSource.apply(snapshot, animatingDifferences: false)

                if results.isEmpty {
                    var config = UIContentUnavailableConfiguration.search()
                    config.text = "No results for \"\(query)\""
                    contentUnavailableConfiguration = config
                } else {
                    contentUnavailableConfiguration = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let result = dataSource.itemIdentifier(for: indexPath) else { return }

        switch result.mediaType {
        case "show":
            let vc = ShowDetailViewController(api: api, showRatingKey: result.id)
            navigationController?.pushViewController(vc, animated: true)
        case "episode":
            let vc = MediaDetailViewController(
                api: api,
                ratingKey: result.id,
                mediaType: "episode",
                showRatingKey: result.grandparentRatingKey,
                seasonRatingKey: result.parentRatingKey
            )
            navigationController?.pushViewController(vc, animated: true)
        default:
            let vc = MediaDetailViewController(api: api, ratingKey: result.id, mediaType: "movie")
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let m = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            var actions = [UIMenuElement]()
            if m.mediaType != "show" {
                actions.append(UIAction(title: m.positionSecs > 0 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                    self?.quickPlay(m)
                })
            }
            if m.mediaType == "episode", let showKey = m.grandparentRatingKey {
                actions.append(UIAction(title: "Go to Show", image: UIImage(systemName: "tv")) { [weak self] _ in
                    guard let self else { return }
                    self.navigationController?.pushViewController(ShowDetailViewController(api: self.api, showRatingKey: showKey), animated: true)
                })
            }
            actions.append(UIAction(title: m.isWatched ? "Mark Unwatched" : "Mark Watched", image: UIImage(systemName: m.isWatched ? "eye.slash" : "eye")) { [weak self] _ in
                guard let self else { return }
                Task {
                    if m.isWatched {
                        try? await self.api.requestVoid(.unscrobble(ratingKey: m.id))
                    } else {
                        try? await self.api.requestVoid(.scrobble(ratingKey: m.id))
                    }
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
