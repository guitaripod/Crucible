import CrucibleCore
import CrucibleDesign
import UIKit

/// Everything under the system search field: the idle shelves (recent searches, genres, recently
/// added) and, once the query is long enough, the scope chips with the grouped results. The shared
/// `SearchSession` decides what to show; this controller only renders its states.
final class TVSearchResultsViewController: UIViewController, UISearchResultsUpdating, UICollectionViewDelegate {
    private typealias DataSource = UICollectionViewDiffableDataSource<TVSearchSection, TVSearchItem>
    private typealias Snapshot = NSDiffableDataSourceSnapshot<TVSearchSection, TVSearchItem>

    private let env: TVAppEnvironment
    private let session: SearchSession
    private lazy var collectionView = TVCollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private let stateView = TVStateView()
    private var dataSource: DataSource!
    private var scope: SearchScope = .all
    private var resultsQuery: String?
    private var watchedOverrides: [String: Bool] = [:]

    weak var searchController: UISearchController?
    weak var host: UIViewController?

    init(env: TVAppEnvironment) {
        self.env = env
        session = SearchSession(loader: SearchLoader(api: env.api))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.onPlayPause = { [weak self] indexPath in self?.playFocused(at: indexPath) }
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        view.addSubview(collectionView)
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        configureDataSource()
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

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        stateView.isHidden ? [collectionView] : [stateView]
    }

    func updateSearchResults(for searchController: UISearchController) {
        session.update(query: searchController.searchBar.text, scope: scope)
    }

    private var currentText: String? {
        searchController?.searchBar.text
    }

    private func render(_ state: SearchState) {
        switch state {
        case .idle(let content):
            resultsQuery = nil
            renderIdle(content)
        case .loading:
            showState(.loading(title: nil))
        case .results(let query, let parts):
            resultsQuery = query
            renderResults(parts)
        case .empty(let query, let emptyScope):
            resultsQuery = query
            renderEmpty(query: query, scope: emptyScope)
        case .failed(let query, let message):
            showState(.error(title: SearchCopy.failureTitle, message: message, retryTitle: SearchCopy.retry) { [weak self] in
                self?.session.retry(query)
            })
        }
    }

    private func showState(_ state: TVStateView.State) {
        dataSource.apply(Snapshot(), animatingDifferences: false)
        stateView.show(state)
        stateView.isHidden = false
        collectionView.isHidden = true
        refreshFocus()
    }

    private func showCollection() {
        stateView.isHidden = true
        collectionView.isHidden = false
    }

    private func refreshFocus() {
        setNeedsFocusUpdate()
    }

    private func renderIdle(_ content: SearchIdleContent) {
        guard !content.isEmpty else {
            showState(.empty(title: SearchCopy.idleTitle, message: SearchCopy.idleMessage, symbol: "magnifyingglass", action: nil))
            return
        }
        showCollection()
        var snapshot = Snapshot()
        if !content.recents.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems(content.recents.map { .recent($0) } + [.clearRecents], toSection: .recent)
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
    }

    private func renderResults(_ parts: SearchResults.Parts) {
        showCollection()
        var snapshot = Snapshot()
        snapshot.appendSections([.scopes])
        snapshot.appendItems(SearchScope.allCases.map { .scope($0) }, toSection: .scopes)
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
    }

    private func renderEmpty(query: String, scope emptyScope: SearchScope) {
        let action = emptyScope == .all ? nil : TVStateView.Action(title: "Search All") { [weak self] in
            self?.select(scope: .all)
        }
        showState(.empty(
            title: SearchCopy.noResultsTitle(query: query),
            message: SearchCopy.noResultsHint(scope: emptyScope),
            symbol: "magnifyingglass",
            action: action
        ))
    }

    private func select(scope newScope: SearchScope) {
        guard newScope != scope else { return }
        scope = newScope
        session.update(query: currentText, scope: newScope)
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let self, let section = self.section(at: index) else { return TVShelf.poster(header: false) }
            return self.layout(for: section)
        }
    }

    private func section(at index: Int) -> TVSearchSection? {
        let sections = dataSource?.snapshot().sectionIdentifiers ?? []
        return sections.indices.contains(index) ? sections[index] : nil
    }

    private func layout(for section: TVSearchSection) -> NSCollectionLayoutSection {
        let isFiltered = scope != .all
        switch section {
        case .scopes:
            let chips = TVShelf.chips()
            chips.contentInsets.bottom = TVMetrics.shelfTopInset
            return chips
        case .recent:
            return TVShelf.chips(header: true)
        case .browse:
            return TVShelf.genre()
        case .recentlyAdded:
            return TVShelf.poster()
        case .topResult:
            return Self.topResultSection()
        case .movies, .shows:
            return isFiltered ? TVShelf.grid(columns: 6, header: true) : TVShelf.poster()
        case .episodes:
            return isFiltered
                ? TVShelf.grid(columns: 4, itemHeight: TVCardStyle.landscape.itemSize.height, header: true)
                : TVShelf.landscape()
        }
    }

    private static func topResultSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(300))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: TVMetrics.shelfTopInset,
            leading: 0,
            bottom: TVMetrics.shelfBottomInset,
            trailing: 0
        )
        return section
    }

    private func configureDataSource() {
        let chips = UICollectionView.CellRegistration<TVChipCell, TVSearchItem> { [weak self] cell, _, item in
            guard let self, let chip = self.chip(for: item) else { return }
            cell.configure(
                with: chip,
                onSelect: { [weak self] _ in self?.activate(chip: item) },
                menu: { [weak self] _ in self?.menu(forChip: item) }
            )
        }
        let genres = TVGenreCell.registration()
        let posters = TVPosterCell.registration()
        let landscapes = TVLandscapeCell.registration()
        let top = UICollectionView.CellRegistration<TVSearchTopResultCell, PlexMetadata> { [weak self] cell, _, item in
            guard let self else { return }
            cell.contentConfiguration = self.topResultConfiguration(for: item)
        }

        dataSource = DataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            switch item {
            case .scope, .recent, .clearRecents:
                return collectionView.dequeueConfiguredReusableCell(using: chips, for: indexPath, item: item)
            case .genre(let genre):
                return collectionView.dequeueConfiguredReusableCell(using: genres, for: indexPath, item: TVSearchCards.genre(genre))
            case .recentlyAdded(let metadata), .movie(let metadata), .show(let metadata):
                let card = TVSearchCards.poster(metadata, watchedOverride: self?.watchedOverrides[metadata.id])
                return collectionView.dequeueConfiguredReusableCell(using: posters, for: indexPath, item: card)
            case .top(let metadata):
                return collectionView.dequeueConfiguredReusableCell(using: top, for: indexPath, item: metadata)
            case .episode(let metadata):
                let card = TVSearchCards.episode(
                    metadata, query: self?.resultsQuery, watchedOverride: self?.watchedOverrides[metadata.id]
                )
                return collectionView.dequeueConfiguredReusableCell(using: landscapes, for: indexPath, item: card)
            }
        }

        let headers = TVSectionHeaderView.registration { [weak self] indexPath in
            guard let title = self?.section(at: indexPath.section)?.title else { return nil }
            return TVSectionHeader(title: title)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headers, for: indexPath)
        }
    }

    private func chip(for item: TVSearchItem) -> TVChipItem? {
        switch item {
        case .scope(let chipScope):
            return TVChipItem(id: "scope.\(chipScope.rawValue)", title: chipScope.title, isSelected: chipScope == scope)
        case .recent(let query):
            return TVChipItem(id: "recent.\(query)", title: query, symbol: "clock.arrow.circlepath")
        case .clearRecents:
            return TVChipItem(id: "recent.clear", title: "Clear", symbol: "xmark")
        default:
            return nil
        }
    }

    private func activate(chip item: TVSearchItem) {
        switch item {
        case .scope(let chipScope):
            select(scope: chipScope)
        case .recent(let query):
            scope = .all
            searchController?.searchBar.text = query
            session.select(recent: query)
        case .clearRecents:
            session.clearRecents()
        default:
            break
        }
    }

    private func menu(forChip item: TVSearchItem) -> UIMenu? {
        guard case .recent(let query) = item else { return nil }
        let remove = UIAction(title: SearchCopy.removeRecent, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.session.removeRecent(query)
        }
        return UIMenu(children: [remove])
    }

    private func topResultConfiguration(for item: PlexMetadata) -> TVSearchTopResultConfiguration {
        let model = SearchTopResultModel(item: item)
        var config = TVSearchTopResultConfiguration()
        config.posterPath = model.posterPath
        config.placeholderSymbol = model.placeholderIcon
        config.title = model.title
        config.meta = model.meta
        config.query = resultsQuery
        config.playTitle = model.canPlay ? SearchItemActions.playTitle(for: item) : nil
        config.openTitle = Self.openTitle(for: item)
        config.onPlay = { [weak self] in
            self?.session.rememberCurrentQuery()
            self?.play(item)
        }
        config.onOpen = { [weak self] in
            self?.session.rememberCurrentQuery()
            self?.open(item)
        }
        return config
    }

    private static func openTitle(for item: PlexMetadata) -> String {
        switch item.mediaType {
        case "show": return "Open Show"
        case "episode": return "Open Episode"
        default: return "Open Movie"
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .genre(let genre):
            navigator?.pushViewController(TVGenreBrowseViewController(env: env, genre: genre), animated: true)
        case .recentlyAdded(let metadata):
            open(metadata)
        case .movie(let metadata), .show(let metadata), .episode(let metadata):
            session.rememberCurrentQuery()
            open(metadata)
        case .scope, .recent, .clearRecents, .top:
            break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let metadata = dataSource.itemIdentifier(for: indexPath)?.metadata,
              let menu = TVSearchMenus.menu(
                for: metadata,
                watched: watchedOverrides[metadata.id] ?? metadata.isWatched,
                play: { [weak self] in self?.play(metadata) },
                goToShow: { [weak self] showKey in self?.openShow(showKey) },
                toggleWatched: { [weak self] in self?.toggleWatched(metadata) }
              )
        else { return nil }
        return TVContextMenu.configuration(menu: menu)
    }

    private func playFocused(at indexPath: IndexPath) {
        guard let metadata = dataSource.itemIdentifier(for: indexPath)?.metadata, SearchItemActions.isPlayable(metadata) else { return }
        if dataSource.itemIdentifier(for: indexPath)?.isSearchResult == true {
            session.rememberCurrentQuery()
        }
        play(metadata)
    }

    private var navigator: UINavigationController? {
        host?.navigationController ?? navigationController
    }

    private func open(_ item: PlexMetadata) {
        let screen: UIViewController
        switch SearchDestination(item: item) {
        case .movie(let ratingKey):
            screen = TVScreens.movieDetail(env, ratingKey: ratingKey, mediaType: "movie")
        case .show(let ratingKey, let initialSeasonKey):
            screen = TVScreens.showDetail(env, ratingKey: ratingKey, initialSeasonKey: initialSeasonKey)
        case .episode(let ratingKey, _, _):
            screen = TVScreens.movieDetail(env, ratingKey: ratingKey, mediaType: "episode")
        }
        navigator?.pushViewController(screen, animated: true)
    }

    private func openShow(_ showKey: String) {
        navigator?.pushViewController(TVScreens.showDetail(env, ratingKey: showKey, initialSeasonKey: nil), animated: true)
    }

    private func play(_ item: PlexMetadata) {
        TVScreens.play(env, request: TVPlaybackRequest(item: item), from: tabBarController ?? host ?? self)
    }

    private func toggleWatched(_ item: PlexMetadata) {
        let watched = !(watchedOverrides[item.id] ?? item.isWatched)
        watchedOverrides[item.id] = watched
        reconfigure(item)
        let api = env.api
        let ratingKey = item.id
        Task { await SearchItemActions.setWatched(watched, ratingKey: ratingKey, api: api) }
    }

    private func reconfigure(_ item: PlexMetadata) {
        var snapshot = dataSource.snapshot()
        let affected = snapshot.itemIdentifiers.filter { $0.metadata?.id == item.id }
        snapshot.reconfigureItems(affected)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}
