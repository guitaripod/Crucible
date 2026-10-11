import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

final class SearchViewController: UICollectionViewController, UISearchResultsUpdating {
    private typealias DataSource = UICollectionViewDiffableDataSource<SearchSection, SearchItem>
    private typealias Snapshot = NSDiffableDataSourceSnapshot<SearchSection, SearchItem>

    private let api: APIClient
    private var dataSource: DataSource!
    private let searchController = UISearchController(searchResultsController: nil)
    private let session: SearchSession
    private var downloadObserver: UUID?
    private var playerCoordinator: PlayerCoordinator?

    init(api: APIClient) {
        self.api = api
        session = SearchSession(loader: SearchLoader(api: api))
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let downloadObserver {
            Task { @MainActor in DownloadManager.shared.removeObserver(downloadObserver) }
        }
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

        session.onChange = { [weak self] state in self?.render(state) }
        session.start()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.resume()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.suspend()
    }

    private func configureSearchController() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        let searchBar = searchController.searchBar
        searchBar.placeholder = SearchCopy.placeholder
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
            let model = SearchEpisodeModel(item: item)
            var config = SearchEpisodeConfiguration()
            config.thumbPath = model.thumbPath
            config.title = model.title
            config.subtitle = model.subtitle
            config.query = self?.session.resultsQuery
            config.progress = model.progress
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
                config.actionTitle = SearchCopy.clearRecents
                config.onAction = { [weak self] in self?.clearRecents() }
            }
            cell.contentConfiguration = config
        }
        dataSource.supplementaryViewProvider = { cv, _, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func topResultConfiguration(for item: PlexMetadata) -> TopResultConfiguration {
        let model = SearchTopResultModel(item: item)
        var config = TopResultConfiguration()
        config.posterPath = model.posterPath
        config.title = model.title
        config.meta = model.meta
        config.query = session.resultsQuery
        config.canPlay = model.canPlay
        config.placeholderIcon = model.placeholderIcon
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

    private func render(_ state: SearchState) {
        switch state {
        case .idle(let content): showIdle(content)
        case .loading: showLoading()
        case .results(_, let parts): renderResults(parts)
        case .empty(let query, let scope): renderEmpty(query: query, scope: scope)
        case .failed(let query, let message): showFailure(message: message, query: query)
        }
    }

    private func showIdle(_ content: SearchIdleContent) {
        var snapshot = Snapshot()
        if !content.recents.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems(content.recents.map { .recent($0) }, toSection: .recent)
        }
        if !content.genres.isEmpty {
            snapshot.appendSections([.browse])
            snapshot.appendItems(content.genres.map { .genre($0) }, toSection: .browse)
        }
        if !content.recentlyAdded.isEmpty {
            snapshot.appendSections([.recentlyAdded])
            snapshot.appendItems(content.recentlyAdded.map { .recentlyAdded($0) }, toSection: .recentlyAdded)
        }
        dataSource.apply(snapshot, animatingDifferences: false)

        if content.isEmpty {
            var config = UIContentUnavailableConfiguration.search()
            config.text = SearchCopy.idleTitle
            config.secondaryText = SearchCopy.idleMessage
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func clearRecents() {
        Haptics.light()
        session.clearRecents()
    }

    func updateSearchResults(for searchController: UISearchController) {
        session.update(query: searchController.searchBar.text, scope: scope)
    }

    private func showLoading() {
        dataSource.apply(Snapshot(), animatingDifferences: false)
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
    }

    private func showFailure(message: String, query: String) {
        dataSource.apply(Snapshot(), animatingDifferences: false)
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "wifi.exclamationmark")
        config.text = SearchCopy.failureTitle
        config.secondaryText = message
        var button = UIButton.Configuration.filled()
        button.title = SearchCopy.retry
        button.cornerStyle = .capsule
        button.baseBackgroundColor = Theme.Color.accent
        button.baseForegroundColor = Theme.Color.onAccent
        config.button = button
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in
            self?.session.retry(query)
        }
        contentUnavailableConfiguration = config
    }

    private func renderResults(_ parts: SearchResults.Parts) {
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
        contentUnavailableConfiguration = nil
    }

    private func renderEmpty(query: String, scope: SearchScope) {
        renderResults(.empty)
        var config = UIContentUnavailableConfiguration.search()
        config.text = SearchCopy.noResultsTitle(query: query)
        config.secondaryText = SearchCopy.noResultsHint(scope: scope)
        contentUnavailableConfiguration = config
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
            session.rememberCurrentQuery()
            open(metadata)
        }
    }

    private func apply(recentQuery query: String) {
        searchController.isActive = true
        searchController.searchBar.text = query
        searchController.searchBar.selectedScopeButtonIndex = SearchScope.all.rawValue
        session.select(recent: query)
    }

    private func open(_ item: PlexMetadata) {
        let controller: UIViewController
        switch SearchDestination(item: item) {
        case .show(let ratingKey, let initialSeasonKey):
            controller = ShowDetailViewController(api: api, showRatingKey: ratingKey, initialSeasonKey: initialSeasonKey)
        case .episode(let ratingKey, let showRatingKey, let seasonRatingKey):
            controller = MediaDetailViewController(
                api: api,
                ratingKey: ratingKey,
                mediaType: "episode",
                showRatingKey: showRatingKey,
                seasonRatingKey: seasonRatingKey
            )
        case .movie(let ratingKey):
            controller = MediaDetailViewController(api: api, ratingKey: ratingKey, mediaType: "movie")
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
            let remove = UIAction(title: SearchCopy.removeRecent, image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self?.session.removeRecent(query)
            }
            return UIMenu(children: [remove])
        })
    }

    private func menuActions(for item: PlexMetadata) -> [UIMenuElement] {
        var actions = [UIMenuElement]()
        let isPlayable = SearchItemActions.isPlayable(item)
        if isPlayable {
            actions.append(UIAction(title: SearchItemActions.playTitle(for: item), image: UIImage(systemName: "play.fill")) { [weak self] _ in
                Haptics.light()
                self?.quickPlay(item)
            })
        }
        if let showKey = SearchItemActions.showKey(for: item) {
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

    private func watchedAction(for item: PlexMetadata) -> UIAction {
        UIAction(
            title: SearchItemActions.watchedTitle(for: item),
            image: UIImage(systemName: item.isWatched ? "eye.slash" : "eye")
        ) { [weak self] _ in
            guard let self else { return }
            Haptics.light()
            Task {
                await SearchItemActions.toggleWatched(item, api: self.api)
            }
        }
    }

    private func quickPlay(_ item: PlexMetadata) {
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }
}
