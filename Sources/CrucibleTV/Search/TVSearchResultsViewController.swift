import CrucibleCore
import CrucibleDesign
import UIKit

/// Everything under the system search field: the idle shelves (recent searches, genres, recently
/// added) and, once the query is long enough, the scope chips with the grouped results. The shared
/// `SearchSession` decides what to show; this controller only renders its states on the shared
/// screen host.
final class TVSearchResultsViewController: TVScreenViewController, UISearchResultsUpdating {
    private typealias DataSource = UICollectionViewDiffableDataSource<TVSearchSection, TVSearchItem>
    private typealias Snapshot = NSDiffableDataSourceSnapshot<TVSearchSection, TVSearchItem>

    private static let tourSearchSettle: Duration = .seconds(2)

    private let env: TVAppEnvironment
    private let session: SearchSession
    private var dataSource: DataSource!
    private var scope: SearchScope = .all
    private var resultsQuery: String?
    private var renderedKey: String?
    private var watchedOverrides: [String: Bool] = [:]
    private var pendingWatched = Set<String>()
    private lazy var tourSlot = makeTaskSlot()
    private var isTourSearchPending = false

    weak var searchController: UISearchController?
    weak var host: UIViewController?

    init(env: TVAppEnvironment) {
        self.env = env
        session = SearchSession(loader: SearchLoader(api: env.api))
        super.init(layout: UICollectionViewLayout())
        collectionView.collectionViewLayout = makeLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
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
        recordTourSearchIfPending()
    }

    func updateSearchResults(for searchController: UISearchController) {
        session.update(query: searchController.searchBar.text, scope: scope)
    }

    private var currentText: String? {
        searchController?.searchBar.text
    }

    private var presenter: UIViewController {
        tabBarController ?? host ?? self
    }

    /// The search container presents its search controller, so an alert goes on top of that one: the
    /// container itself always has something presented.
    private var alertPresenter: UIViewController {
        searchController ?? presenter
    }

    private var navigator: UIViewController {
        host ?? self
    }

    private func render(_ state: SearchState) {
        switch state {
        case .idle(let content):
            cancelTourSearch()
            discardOverrides(for: "idle")
            resultsQuery = nil
            renderIdle(content)
        case .loading:
            cancelTourSearch()
            showMessage(.loading(title: nil))
        case .results(let query, let parts):
            discardOverrides(for: query)
            resultsQuery = query
            renderResults(parts)
        case .empty(let query, let emptyScope):
            cancelTourSearch()
            discardOverrides(for: query)
            resultsQuery = query
            renderEmpty(query: query, scope: emptyScope)
        case .failed(let query, let message):
            cancelTourSearch()
            showMessage(.error(title: SearchCopy.failureTitle, message: message, retryTitle: SearchCopy.retry) { [weak self] in
                self?.session.retry(query)
            })
        }
    }

    /// A watched mark the user just made stands in for the server's answer until the next query
    /// brings fresh data, so each query starts without any.
    private func discardOverrides(for key: String) {
        if renderedKey != key { watchedOverrides = [:] }
        renderedKey = key
    }

    private func showMessage(_ state: TVStateView.State) {
        show(state: state)
        dataSource.apply(Snapshot(), animatingDifferences: false)
    }

    private func renderIdle(_ content: SearchIdleContent) {
        guard !content.isEmpty else {
            showMessage(.empty(title: SearchCopy.idleTitle, message: SearchCopy.idleMessage, symbol: "magnifyingglass", action: nil))
            return
        }
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
        dataSource.applyReconfiguringExisting(snapshot)
        showContent()
    }

    private func renderResults(_ parts: SearchResults.Parts) {
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
        dataSource.applyReconfiguringExisting(snapshot)
        collectionView.collectionViewLayout.invalidateLayout()
        showContent()
        scheduleTourSearch()
    }

    /// Ticks the demo tour's Search step once results have stayed on screen without another keystroke, or when the screen is
    /// left with results showing. Ticking on the first partial query would earn the finale while the viewer is still typing, and it
    /// would cover the keyboard mid-word.
    private func scheduleTourSearch() {
        isTourSearchPending = true
        tourSlot.run { [weak self] in
            try? await Task.sleep(for: Self.tourSearchSettle)
            guard !Task.isCancelled else { return }
            self?.recordTourSearchIfPending()
        }
    }

    private func cancelTourSearch() {
        isTourSearchPending = false
        tourSlot.cancel()
    }

    private func recordTourSearchIfPending() {
        guard isTourSearchPending else { return }
        isTourSearchPending = false
        DemoTour.shared.record(.search)
    }

    private func renderEmpty(query: String, scope emptyScope: SearchScope) {
        let action = emptyScope == .all ? nil : TVStateView.Action(title: "Search All") { [weak self] in
            self?.select(scope: .all)
        }
        showMessage(.empty(
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
        return sections[safe: index]
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
        let top = TVHostCell.registration { [weak self] (item: PlexMetadata) -> UIView in
            self?.topResultView(for: item) ?? UIView()
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
        adopt(dataSource)

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
            return TVChipItem(
                id: "scope.\(chipScope.rawValue)",
                title: chipScope.title,
                isSelected: chipScope == scope,
                accessibilityHint: "Filters the results"
            )
        case .recent(let query):
            return TVChipItem(
                id: "recent.\(query)",
                title: query,
                symbol: "clock.arrow.circlepath",
                accessibilityLabel: "Recent search, \(query)",
                accessibilityHint: "Searches again"
            )
        case .clearRecents:
            return TVChipItem(
                id: "recent.clear",
                title: SearchCopy.clearRecents,
                symbol: "xmark",
                accessibilityLabel: "Clear recent searches",
                accessibilityHint: "Removes every recent search"
            )
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

    private func topResultView(for item: PlexMetadata) -> UIView {
        let model = SearchTopResultModel(item: item)
        return TVSearchTopResultView(
            card: TVSearchCards.topResult(item, query: resultsQuery),
            playTitle: model.canPlay ? SearchItemActions.playTitle(for: item) : nil,
            openTitle: Self.openTitle(for: item),
            onPlay: { [weak self] in
                self?.session.rememberCurrentQuery()
                self?.play(item)
            },
            onOpen: { [weak self] in
                self?.session.rememberCurrentQuery()
                self?.open(item)
            }
        )
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
            TVNavigation.push(TVGenreBrowseViewController(env: env, genre: genre), from: navigator)
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
                playFromBeginning: { [weak self] in self?.play(metadata, fromBeginning: true) },
                openDetails: { [weak self] in self?.open(metadata) },
                goToShow: { [weak self] showKey in self?.openShow(showKey) },
                setWatched: { [weak self] watched in self?.setWatched(watched, item: metadata) }
              )
        else { return nil }
        return TVContextMenu.configuration(menu: menu)
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath),
              let metadata = item.metadata,
              SearchItemActions.isPlayable(metadata)
        else { return false }
        if item.isSearchResult {
            session.rememberCurrentQuery()
        }
        play(metadata)
        return true
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
        TVNavigation.push(screen, from: navigator)
    }

    private func openShow(_ showKey: String) {
        TVNavigation.push(TVScreens.showDetail(env, ratingKey: showKey, initialSeasonKey: nil), from: navigator)
    }

    private func play(_ item: PlexMetadata, fromBeginning: Bool = false) {
        TVScreens.play(
            env,
            request: TVPlaybackRequest(item: item, resumeSeconds: fromBeginning ? 0 : nil),
            from: presenter
        )
    }

    /// Shows the new watched state at once and tells the server; if the server refuses, the card goes
    /// back to what it showed and an alert says so. A second change of the same title waits for the first.
    private func setWatched(_ watched: Bool, item: PlexMetadata) {
        let ratingKey = item.id
        guard pendingWatched.insert(ratingKey).inserted else { return }
        let previous = watchedOverrides[ratingKey]
        watchedOverrides[ratingKey] = watched
        reconfigure(ratingKey)
        let api = env.api
        Task { [weak self] in
            do {
                try await WatchedService.setWatched(watched, ratingKey: ratingKey, api: api)
                self?.pendingWatched.remove(ratingKey)
            } catch {
                guard let self else { return }
                pendingWatched.remove(ratingKey)
                watchedOverrides[ratingKey] = previous
                reconfigure(ratingKey)
                await presentFailure(title: SearchCopy.watchedFailureTitle(watched: watched), message: error.localizedDescription)
            }
        }
    }

    /// The server usually refuses while the long-press menu is still closing, and `presentAlert` declines
    /// to stack on it, so this waits for the menu to finish. TODO(ds): `presentAlert` could queue behind a
    /// dismissing controller itself.
    private func presentFailure(title: String, message: String) async {
        for _ in 0..<20 {
            if alertPresenter.presentAlert(title: title, message: message) != nil { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func reconfigure(_ ratingKey: String) {
        var snapshot = dataSource.snapshot()
        let affected = snapshot.itemIdentifiers.filter { $0.metadata?.id == ratingKey }
        guard !affected.isEmpty else { return }
        snapshot.reconfigureItems(affected)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}
