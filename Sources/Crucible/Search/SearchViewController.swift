@preconcurrency import UIKit

final class SearchViewController: UICollectionViewController, UISearchResultsUpdating {
    private typealias DataSource = UICollectionViewDiffableDataSource<SearchSection, SearchItem>
    private typealias Snapshot = NSDiffableDataSourceSnapshot<SearchSection, SearchItem>

    private let api: APIClient
    private var dataSource: DataSource!
    private let searchController = UISearchController(searchResultsController: nil)
    private var searchTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var genres: [SearchGenre] = []
    private var recentlyAdded: [PlexMetadata] = []
    private var results: SearchResults?
    private var resultsQuery: String?
    private var activeQuery: String?
    private var downloadObserver: UUID?
    private var playerCoordinator: PlayerCoordinator?

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let downloadObserver {
            Task { @MainActor in DownloadManager.shared.removeObserver(downloadObserver) }
        }
    }

    private var currentQuery: String {
        (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        currentQuery.count >= 2
    }

    private var scope: SearchScope {
        SearchScope(rawValue: searchController.searchBar.selectedScopeButtonIndex) ?? .all
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Search"
        view.backgroundColor = Theme.Color.canvas
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always

        configureSearchController()
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.keyboardDismissMode = .onDrag
        collectionView.collectionViewLayout = createLayout()
        configureDataSource()

        downloadObserver = DownloadManager.shared.addObserver { [weak self] _ in
            self?.refreshTopResultDownloadState()
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (vc: SearchViewController, _: UITraitCollection) in
            vc.collectionView.collectionViewLayout.invalidateLayout()
        }

        showIdle()
        loadIdleContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !isSearching {
            showIdle()
            loadIdleContent()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        searchTask?.cancel()
        idleTask?.cancel()
        if activeQuery != resultsQuery { activeQuery = nil }
    }

    private func configureSearchController() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        let searchBar = searchController.searchBar
        searchBar.placeholder = "Movies, shows, episodes"
        searchBar.tintColor = Theme.Color.accentText
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.returnKeyType = .search
        searchBar.scopeButtonTitles = SearchScope.allCases.map(\.title)
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self, let section = self.section(at: sectionIndex) else {
                return Self.emptySection()
            }
            return self.layoutSection(for: section, environment: environment)
        }
    }

    private func section(at index: Int) -> SearchSection? {
        let sections = dataSource?.snapshot().sectionIdentifiers ?? []
        return sections.indices.contains(index) ? sections[index] : nil
    }

    private static func emptySection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(1))
        let item = NSCollectionLayoutItem(layoutSize: size)
        return NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [item]))
    }

    private func layoutSection(for section: SearchSection, environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let layoutSection: NSCollectionLayoutSection
        switch section {
        case .recent: layoutSection = chipsSection()
        case .browse: layoutSection = browseSection()
        case .topResult: layoutSection = topResultSection()
        case .episodes: layoutSection = episodesSection()
        case .recentlyAdded: layoutSection = posterSection(environment: environment, forceGrid: false)
        case .movies, .shows: layoutSection = posterSection(environment: environment, forceGrid: scope != .all)
        }
        if section.title != nil {
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44))
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: size, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top
            )
            layoutSection.boundarySupplementaryItems = [header]
        }
        return layoutSection
    }

    private func chipsSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .estimated(80), heightDimension: .estimated(FilterChipsView.height))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = Theme.Space.xs
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.m, bottom: Theme.Space.xs, trailing: Theme.Space.m)
        return section
    }

    private func browseSection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.5), heightDimension: .estimated(76))
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(76))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: 2)
        group.interItemSpacing = .fixed(Theme.Space.xs)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Theme.Space.xs
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.m, bottom: Theme.Space.xs, trailing: Theme.Space.m)
        return section
    }

    private func topResultSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(138))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let section = NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [item]))
        section.contentInsets = NSDirectionalEdgeInsets(top: Theme.Space.s, leading: Theme.Space.m, bottom: 0, trailing: Theme.Space.m)
        return section
    }

    private func episodesSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(58))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let section = NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [item]))
        section.interGroupSpacing = Theme.Space.s
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.m, bottom: Theme.Space.m, trailing: Theme.Space.m)
        return section
    }

    private func posterSection(environment: NSCollectionLayoutEnvironment, forceGrid: Bool) -> NSCollectionLayoutSection {
        let isAccessibilitySize = environment.traitCollection.preferredContentSizeCategory >= .accessibilityExtraExtraLarge
        if forceGrid || isAccessibilitySize {
            return Theme.gridLayout(environment: environment)
        }
        let height = Theme.Size.posterRailWidth * Theme.Size.posterAspect + Theme.Size.captionBlockHeight
        let size = NSCollectionLayoutSize(widthDimension: .absolute(Theme.Size.posterRailWidth), heightDimension: .estimated(height))
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = Theme.Space.s
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.m, bottom: Theme.Space.m, trailing: Theme.Space.m)
        return section
    }

    private func configureDataSource() {
        let chipReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, title in
            var config = SearchChipConfiguration()
            config.title = title
            cell.contentConfiguration = config
            SearchCellEffects.installPressEffect(on: cell)
        }
        let genreReg = UICollectionView.CellRegistration<UICollectionViewCell, SearchGenre> { cell, _, genre in
            var config = SearchGenreConfiguration()
            config.title = genre.title
            cell.contentConfiguration = config
            SearchCellEffects.installPressEffect(on: cell)
        }
        let posterReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, item in
            cell.contentConfiguration = PosterContentConfiguration.search(item)
            SearchCellEffects.installPressEffect(on: cell)
        }
        let topReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { [weak self] cell, _, item in
            guard let self else { return }
            cell.contentConfiguration = self.topResultConfiguration(for: item)
            SearchCellEffects.installPressEffect(on: cell)
        }
        let episodeReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { [weak self] cell, _, item in
            var config = SearchEpisodeConfiguration()
            config.thumbPath = item.thumb ?? item.grandparentThumb
            config.title = item.grandparentTitle ?? item.title
            config.subtitle = [SearchFormat.episodeCode(item), item.title].compactMap { $0 }.joined(separator: " · ")
            config.query = self?.resultsQuery
            config.progress = item.progressPercent > 0 ? item.progressPercent : nil
            cell.contentConfiguration = config
            SearchCellEffects.installPressEffect(on: cell)
        }

        dataSource = DataSource(collectionView: collectionView) { cv, indexPath, item in
            switch item {
            case .recent(let title):
                return cv.dequeueConfiguredReusableCell(using: chipReg, for: indexPath, item: title)
            case .genre(let genre):
                return cv.dequeueConfiguredReusableCell(using: genreReg, for: indexPath, item: genre)
            case .recentlyAdded(let metadata), .movie(let metadata), .show(let metadata):
                return cv.dequeueConfiguredReusableCell(using: posterReg, for: indexPath, item: metadata)
            case .top(let metadata):
                return cv.dequeueConfiguredReusableCell(using: topReg, for: indexPath, item: metadata)
            case .episode(let metadata):
                return cv.dequeueConfiguredReusableCell(using: episodeReg, for: indexPath, item: metadata)
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            guard let section = self?.section(at: indexPath.section) else { return }
            var config = SearchHeaderConfiguration()
            config.title = section.title ?? ""
            if section == .recent {
                config.actionTitle = "Clear"
                config.onAction = { [weak self] in self?.clearRecents() }
            }
            cell.contentConfiguration = config
        }
        dataSource.supplementaryViewProvider = { cv, _, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func topResultConfiguration(for item: PlexMetadata) -> TopResultConfiguration {
        var config = TopResultConfiguration()
        config.posterPath = item.mediaType == "episode" ? (item.grandparentThumb ?? item.thumb) : item.thumb
        config.title = item.mediaType == "episode" ? (item.grandparentTitle ?? item.title) : item.title
        config.meta = SearchFormat.typeLine(for: item)
        config.query = resultsQuery
        config.canPlay = item.mediaType != "show"
        config.placeholderIcon = item.mediaType == "movie" ? "film" : "tv"
        config.downloadState = SearchDownloadState(item: item)
        config.onPlay = { [weak self] in
            Haptics.light()
            self?.quickPlay(item)
        }
        config.onDownload = {
            Haptics.medium()
            DownloadManager.shared.enqueue(metadata: item)
        }
        if let menuAction = downloadMenuAction(for: item) {
            config.downloadMenu = UIMenu(children: [menuAction])
        }
        return config
    }

    private func downloadMenuAction(for item: PlexMetadata) -> UIMenuElement? {
        item.mediaType == "show" ? nil : DownloadMenu.action(for: item)
    }

    private func refreshTopResultDownloadState() {
        var snapshot = dataSource.snapshot()
        let tops = snapshot.itemIdentifiers(inSection: .topResult)
        guard snapshot.sectionIdentifiers.contains(.topResult), !tops.isEmpty else { return }
        snapshot.reconfigureItems(tops)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func loadIdleContent() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            guard let self else { return }
            async let loadedGenres = SearchLoader.genres(api: api)
            async let loadedRecent = SearchLoader.recentlyAdded(api: api)
            let (newGenres, newRecent) = await (loadedGenres, loadedRecent)
            guard !Task.isCancelled else { return }
            genres = newGenres
            recentlyAdded = newRecent
            if !isSearching { showIdle() }
        }
    }

    private func showIdle() {
        var snapshot = Snapshot()
        let recents = Preferences.recentSearches
        if !recents.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems(recents.map { .recent($0) }, toSection: .recent)
        }
        if !genres.isEmpty {
            snapshot.appendSections([.browse])
            snapshot.appendItems(genres.map { .genre($0) }, toSection: .browse)
        }
        if !recentlyAdded.isEmpty {
            snapshot.appendSections([.recentlyAdded])
            snapshot.appendItems(recentlyAdded.map { .recentlyAdded($0) }, toSection: .recentlyAdded)
        }
        dataSource.apply(snapshot, animatingDifferences: false)

        if snapshot.itemIdentifiers.isEmpty {
            var config = UIContentUnavailableConfiguration.search()
            config.text = "Search your library"
            config.secondaryText = "Find movies, shows and episodes."
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func clearRecents() {
        Preferences.recentSearches = []
        Haptics.light()
        showIdle()
    }

    private func remember(query: String) {
        guard query.count >= 2 else { return }
        var recents = Preferences.recentSearches.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        recents.insert(query, at: 0)
        Preferences.recentSearches = recents
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = currentQuery
        guard query.count >= 2 else {
            searchTask?.cancel()
            activeQuery = nil
            results = nil
            resultsQuery = nil
            showIdle()
            return
        }
        if query == resultsQuery {
            renderResults()
        } else if query != activeQuery {
            performSearch(query: query, debounce: true)
        }
    }

    private func performSearch(query: String, debounce: Bool) {
        searchTask?.cancel()
        activeQuery = query
        if resultsQuery == nil { showLoading() }
        searchTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled, let self else { return }
            do {
                let container = try await api.requestContainer(.search(query: query))
                guard !Task.isCancelled else { return }
                results = SearchResults(hubs: container.Hub ?? [])
                resultsQuery = query
                renderResults()
            } catch {
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
                AppLogger.error("Search failed query=\(query): \(error.localizedDescription)", .networking)
                activeQuery = nil
                showFailure(error, query: query)
            }
        }
    }

    private func showLoading() {
        dataSource.apply(Snapshot(), animatingDifferences: false)
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
    }

    private func showFailure(_ error: Error, query: String) {
        dataSource.apply(Snapshot(), animatingDifferences: false)
        results = nil
        resultsQuery = nil
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "wifi.exclamationmark")
        config.text = "Search Failed"
        config.secondaryText = error.localizedDescription
        var button = UIButton.Configuration.filled()
        button.title = "Try Again"
        button.cornerStyle = .capsule
        button.baseBackgroundColor = Theme.Color.accent
        button.baseForegroundColor = Theme.Color.onAccent
        config.button = button
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in
            guard let self, self.currentQuery == query else { return }
            self.performSearch(query: query, debounce: false)
        }
        contentUnavailableConfiguration = config
    }

    private func renderResults() {
        guard let results, let query = resultsQuery else { return }
        let parts = results.parts(for: scope)
        var snapshot = Snapshot()
        if let top = parts.top {
            snapshot.appendSections([.topResult])
            snapshot.appendItems([.top(top)], toSection: .topResult)
        }
        if !parts.movies.isEmpty {
            snapshot.appendSections([.movies])
            snapshot.appendItems(parts.movies.map { .movie($0) }, toSection: .movies)
        }
        if !parts.shows.isEmpty {
            snapshot.appendSections([.shows])
            snapshot.appendItems(parts.shows.map { .show($0) }, toSection: .shows)
        }
        if !parts.episodes.isEmpty {
            snapshot.appendSections([.episodes])
            snapshot.appendItems(parts.episodes.map { .episode($0) }, toSection: .episodes)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.collectionViewLayout.invalidateLayout()

        if parts.isEmpty {
            var config = UIContentUnavailableConfiguration.search()
            config.text = "No results for \u{201C}\(query)\u{201D}"
            config.secondaryText = scope == .all ? "Check the spelling or try a different search." : "Try the All scope."
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .recent(let query):
            Haptics.selection()
            apply(recentQuery: query)
        case .genre(let genre):
            Haptics.selection()
            navigationController?.pushViewController(GenreBrowseViewController(api: api, genre: genre), animated: true)
        case .recentlyAdded(let metadata):
            open(metadata)
        case .top(let metadata), .movie(let metadata), .show(let metadata), .episode(let metadata):
            remember(query: currentQuery)
            open(metadata)
        }
    }

    private func apply(recentQuery query: String) {
        searchController.isActive = true
        searchController.searchBar.text = query
        searchController.searchBar.selectedScopeButtonIndex = SearchScope.all.rawValue
        if query == resultsQuery {
            renderResults()
        } else {
            performSearch(query: query, debounce: false)
        }
    }

    private func open(_ item: PlexMetadata) {
        let controller: UIViewController
        switch item.mediaType {
        case "show":
            controller = ShowDetailViewController(api: api, showRatingKey: item.id)
        case "season":
            controller = ShowDetailViewController(api: api, showRatingKey: item.parentRatingKey ?? item.id, initialSeasonKey: item.id)
        case "episode":
            controller = MediaDetailViewController(
                api: api,
                ratingKey: item.id,
                mediaType: "episode",
                showRatingKey: item.grandparentRatingKey,
                seasonRatingKey: item.parentRatingKey
            )
        default:
            controller = MediaDetailViewController(api: api, ratingKey: item.id, mediaType: "movie")
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        if case .recent(let query) = item {
            return recentMenu(for: query)
        }
        guard let metadata = item.metadata else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: self.menuActions(for: metadata))
        })
    }

    private func recentMenu(for query: String) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let remove = UIAction(title: "Remove", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                Preferences.recentSearches = Preferences.recentSearches.filter { $0 != query }
                self?.showIdle()
            }
            return UIMenu(children: [remove])
        })
    }

    private func menuActions(for item: PlexMetadata) -> [UIMenuElement] {
        var actions = [UIMenuElement]()
        let isPlayable = item.mediaType == "movie" || item.mediaType == "episode"
        if isPlayable {
            actions.append(UIAction(title: item.positionSecs > 0 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                Haptics.light()
                self?.quickPlay(item)
            })
        }
        if let showKey = Self.showKey(for: item) {
            actions.append(UIAction(title: "Go to Show", image: UIImage(systemName: "tv")) { [weak self] _ in
                guard let self else { return }
                self.navigationController?.pushViewController(ShowDetailViewController(api: self.api, showRatingKey: showKey), animated: true)
            })
        }
        if isPlayable {
            actions.append(DownloadMenu.action(for: item))
            actions.append(watchedAction(for: item))
        }
        return actions
    }

    private static func showKey(for item: PlexMetadata) -> String? {
        switch item.mediaType {
        case "episode": return item.grandparentRatingKey
        case "season": return item.parentRatingKey
        default: return nil
        }
    }

    private func watchedAction(for item: PlexMetadata) -> UIAction {
        UIAction(
            title: item.isWatched ? "Mark Unwatched" : "Mark Watched",
            image: UIImage(systemName: item.isWatched ? "eye.slash" : "eye")
        ) { [weak self] _ in
            guard let self else { return }
            Haptics.light()
            Task {
                if item.isWatched {
                    try? await self.api.requestVoid(.unscrobble(ratingKey: item.id))
                } else {
                    try? await self.api.requestVoid(.scrobble(ratingKey: item.id))
                }
                await self.api.invalidateCache()
            }
        }
    }

    private func quickPlay(_ item: PlexMetadata) {
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }
}
