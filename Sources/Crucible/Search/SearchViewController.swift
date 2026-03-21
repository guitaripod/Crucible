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
            config.mediaType = result.type

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
                results = results.filter { seen.insert($0.ratingKey).inserted }

                var snapshot = NSDiffableDataSourceSnapshot<Int, PlexMetadata>()
                snapshot.appendSections([0])
                snapshot.appendItems(results, toSection: 0)
                await dataSource.apply(snapshot, animatingDifferences: true)

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

        switch result.type {
        case "show":
            let vc = ShowDetailViewController(api: api, showRatingKey: result.ratingKey)
            navigationController?.pushViewController(vc, animated: true)
        case "episode":
            let vc = MediaDetailViewController(
                api: api,
                ratingKey: result.ratingKey,
                mediaType: "episode",
                showRatingKey: result.grandparentRatingKey,
                seasonRatingKey: result.parentRatingKey
            )
            navigationController?.pushViewController(vc, animated: true)
        default:
            let vc = MediaDetailViewController(api: api, ratingKey: result.ratingKey, mediaType: "movie")
            navigationController?.pushViewController(vc, animated: true)
        }
    }
}
