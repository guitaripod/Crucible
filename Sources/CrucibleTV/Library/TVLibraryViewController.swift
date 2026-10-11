import CrucibleCore
import CrucibleDesign
import UIKit

/// One library as a screen: a header with the title, count, watch filters and Genre and Sort menus,
/// a Recently Watched shelf (unfiltered only), and the poster grid with an A-Z rail on the trailing
/// edge. Everything that is not drawing lives in `LibraryGridModel`.
final class TVLibraryViewController: UIViewController {
    enum Section: Hashable {
        case header, recents, grid
    }

    enum Item: Hashable {
        case header
        case recent(String)
        case media(String)
    }

    /// Where a row of posters is scrolled to on a jump, just under the floating tab bar.
    private static let jumpClearance: CGFloat = 130

    private let env: TVAppEnvironment
    private let section: LibrarySection
    private let model: LibraryGridModel
    private let collectionView: TVCollectionView
    private let stateView = TVStateView()
    private let rail = TVAlphabetRail()
    private let railFade = TVGradientView()
    private let focusMemory = TVFocusMemory()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var pendingFocus: IndexPath?
    private let recentCells = NSMapTable<NSString, UICollectionViewCell>(keyOptions: .copyIn, valueOptions: .weakMemory)
    private var hasRevealedContent = false

    init(env: TVAppEnvironment, section: LibrarySection) {
        self.env = env
        self.section = section
        model = LibraryGridModel(api: env.api, sectionId: section.id, kind: section.kind)
        collectionView = TVCollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        super.init(nibName: nil, bundle: nil)
        title = section.title
        model.onUpdate = { [weak self] update in
            self?.modelDidUpdate(update)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        setupCollectionView()
        setupState()
        setupRail()
        configureDataSource()
        collectionView.collectionViewLayout = makeLayout()
        applySnapshot()
        model.loadGenres()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        model.appear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappear()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard stateView.isHidden else { return [stateView] }
        if let indexPath = indexPathForPreferredFocusedView(in: collectionView), let cell = visibleCell(at: indexPath) {
            return [cell]
        }
        return [collectionView]
    }

    /// The cell for `indexPath`. A cell inside the horizontally scrolling shelf is not reported by the
    /// collection view, so the shelf's cells are tracked as they are configured.
    private func visibleCell(at indexPath: IndexPath) -> UICollectionViewCell? {
        if case .recent(let id) = dataSource.itemIdentifier(for: indexPath) {
            return recentCells.object(forKey: id as NSString)
        }
        return collectionView.cellForItem(at: indexPath)
    }

    private func setupCollectionView() {
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.onPlayPause = { [weak self] indexPath in
            self?.playItem(at: indexPath)
        }
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupState() {
        stateView.isHidden = true
        stateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupRail() {
        railFade.setColors(
            [Theme.Color.canvas.withAlphaComponent(0), Theme.Color.canvas],
            locations: [0, 0.25],
            from: CGPoint(x: 0, y: 0.5),
            to: CGPoint(x: 1, y: 0.5)
        )
        railFade.isHidden = true
        railFade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(railFade)
        NSLayoutConstraint.activate([
            railFade.topAnchor.constraint(equalTo: view.topAnchor),
            railFade.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            railFade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            railFade.widthAnchor.constraint(equalToConstant: TVAlphabetRail.fadeWidth),
        ])
        rail.isHidden = true
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.onSelect = { [weak self] letter in
            self?.jump(to: letter)
        }
        view.addSubview(rail)
        let guide = view.safeAreaLayoutGuide
        let centered = rail.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            rail.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            rail.widthAnchor.constraint(equalToConstant: TVAlphabetRail.width),
            rail.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: Self.jumpClearance),
            rail.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor),
            centered,
        ])
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let self else { return nil }
            let sections = dataSource.snapshot().sectionIdentifiers
            guard sections.indices.contains(index) else { return nil }
            switch sections[index] {
            case .header:
                return Self.headerSection()
            case .recents:
                return TVShelf.poster()
            case .grid:
                return TVShelf.grid()
            }
        }
    }

    private static func headerSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(TVLibraryHeaderContentView.height)
        )
        let item = NSCollectionLayoutItem(layoutSize: size)
        let section = NSCollectionLayoutSection(group: NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item]))
        section.contentInsets = NSDirectionalEdgeInsets(top: TVScreenTitle.topInset, leading: 0, bottom: TVMetrics.shelfVerticalInset, trailing: 0)
        return section
    }

    private func configureDataSource() {
        let headerRegistration = UICollectionView.CellRegistration<TVLibraryHeaderCell, Item> { [weak self] cell, _, _ in
            cell.contentConfiguration = self?.headerConfiguration()
        }
        let posterRegistration = TVPosterCell.registration()
        let kind = section.kind
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            switch item {
            case .header:
                return collectionView.dequeueConfiguredReusableCell(using: headerRegistration, for: indexPath, item: item)
            case .recent(let id):
                let card = self?.model.recentItem(withId: id).map { TVCardItem(recentItem: $0, kind: kind) } ?? TVCardItem(id: id, title: "")
                let cell = collectionView.dequeueConfiguredReusableCell(using: posterRegistration, for: indexPath, item: card)
                cell.accessibilityIdentifier = "tv.library.recent.\(id)"
                self?.recentCells.setObject(cell, forKey: id as NSString)
                return cell
            case .media(let id):
                let card = self?.model.item(withId: id).map { TVCardItem(gridItem: $0, kind: kind) } ?? TVCardItem(id: id, title: "")
                let cell = collectionView.dequeueConfiguredReusableCell(using: posterRegistration, for: indexPath, item: card)
                cell.accessibilityIdentifier = "tv.library.media.\(id)"
                return cell
            }
        }
        let headerViewRegistration = TVSectionHeaderView.registration { [weak self] indexPath in
            guard let self, dataSource.sectionIdentifier(for: indexPath.section) == .recents else { return nil }
            return TVSectionHeader(title: "Recently Watched", seeAllAction: { [weak self] in self?.showAllRecent() })
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerViewRegistration, for: indexPath)
        }
    }

    private func headerConfiguration() -> TVLibraryHeaderConfiguration {
        let options = model.options
        let genres = model.genres.map {
            TVLibraryHeaderConfiguration.Choice(key: $0.key, title: $0.title, isSelected: options.genre == $0.key)
        }
        let sorts = section.kind.sortOptions.map {
            TVLibraryHeaderConfiguration.Choice(key: $0.key, title: $0.title, isSelected: options.sort == $0.key)
        }
        var configuration = TVLibraryHeaderConfiguration(
            title: section.title,
            count: countText(),
            chips: LibraryWatchFilter.allCases.map { .init(filter: $0, isSelected: options.isChipSelected($0)) },
            genreTitle: options.genre == nil ? "Genre" : options.genreTitle(in: model.genres),
            isGenreSelected: options.genre != nil,
            genres: genres,
            sortTitle: "Sort",
            sorts: sorts
        )
        configuration.handlers = .init(
            onFilter: { [weak self] in self?.model.selectChip($0) },
            onGenre: { [weak self] in self?.model.setGenre($0) },
            onSort: { [weak self] in self?.model.setSort($0) },
            onBrowseFolders: { [weak self] in self?.browseFolders() }
        )
        return configuration
    }

    /// "1,248 movies", or "12 movies · Filtered" while a filter narrows the grid; empty until the first page arrived.
    private func countText() -> String? {
        guard model.pager.hasLoaded else { return nil }
        let total = model.pager.totalSize
        let noun = section.kind == .movie ? (total == 1 ? "movie" : "movies") : (total == 1 ? "show" : "shows")
        let count = total.formatted(.number)
        return model.options.isFiltering ? "\(count) \(noun) · Filtered" : "\(count) \(noun)"
    }

    private func modelDidUpdate(_ update: LibraryGridModel.Update) {
        switch update {
        case .optionsChanged, .genres:
            reconfigureHeader()
            updateRail()
        case .contentState:
            applyContentState()
        case .pageLoaded, .recents:
            revealContentIfReady()
            applyContentState()
            if hasRevealedContent { applySnapshot() }
        case .pageFailed:
            applyContentState()
        case .continueItem:
            break
        case .alphabet:
            updateRail()
        }
    }

    private func applySnapshot() {
        let previous = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.header])
        snapshot.appendItems([.header], toSection: .header)
        let recents = model.visibleRecents
        if !recents.isEmpty {
            snapshot.appendSections([.recents])
            snapshot.appendItems(recents.map { Item.recent($0.id) }, toSection: .recents)
        }
        snapshot.appendSections([.grid])
        snapshot.appendItems(model.gridIds.map(Item.media), toSection: .grid)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { previous.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: false)
        updateRail()
    }

    private func reconfigureHeader() {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(.header) != nil else { return }
        snapshot.reconfigureItems([.header])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The first page and the Recently Watched shelf are shown together: a shelf that appeared later would
    /// push the posters, and the focus on them, down the screen.
    private func revealContentIfReady() {
        guard !hasRevealedContent, model.pager.hasLoaded, model.hasLoadedRecents else { return }
        hasRevealedContent = true
    }

    private func applyContentState() {
        let state = model.contentState
        let showsGrid = state == .content && hasRevealedContent
        let changedVisibility = collectionView.isHidden == showsGrid
        collectionView.isHidden = !showsGrid
        stateView.isHidden = showsGrid
        switch state {
        case .content:
            if !hasRevealedContent { stateView.show(.loading(title: nil)) }
        case .loading:
            stateView.show(.loading(title: nil))
        case .failed(let message):
            stateView.show(.error(title: "Couldn’t Load Library", message: message, retryTitle: "Try Again") { [weak self] in
                self?.model.refreshAll()
            })
        case .noMatches:
            stateView.show(.empty(
                title: "No Matches",
                message: "Nothing in this library matches the current filters.",
                symbol: "line.3.horizontal.decrease.circle",
                action: .init(title: "Clear Filters") { [weak self] in self?.model.clearFilters() }
            ))
        case .empty:
            stateView.show(.empty(
                title: section.kind.emptyTitle,
                message: "Add media to this library on your Plex server to see it here.",
                symbol: section.kind.placeholderIcon,
                action: .init(title: "Check Again") { [weak self] in self?.model.refreshAll() }
            ))
        }
        updateRail()
        if changedVisibility { setNeedsFocusUpdate() }
    }

    private func updateRail() {
        let visible = model.contentState == .content && model.offersAlphabetJump
        rail.isHidden = !visible
        railFade.isHidden = !visible
        guard visible, let alphabet = model.alphabet else { return }
        rail.update(letters: alphabet.availableLetters)
    }

    private func jump(to letter: String) {
        model.jump(to: letter) { [weak self] index in
            self?.scrollAndFocus(gridIndex: index)
        }
    }

    /// Scrolls the row holding the grid item to the top of the screen and moves the focus onto it.
    private func scrollAndFocus(gridIndex: Int) {
        let count = model.gridIds.count
        guard count > 0, let section = dataSource.snapshot().indexOfSection(.grid) else { return }
        let target = IndexPath(item: min(max(gridIndex, 0), count - 1), section: section)
        guard let frame = collectionView.layoutAttributesForItem(at: target)?.frame else { return }
        let maximum = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        collectionView.setContentOffset(CGPoint(x: 0, y: min(max(frame.minY - Self.jumpClearance, 0), maximum)), animated: false)
        collectionView.layoutIfNeeded()
        pendingFocus = target
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        pendingFocus = nil
    }

    private func browseFolders() {
        let browser = TVFolderBrowserViewController(env: env, source: .section(section.id), title: "Browse Folders")
        navigationController?.pushViewController(browser, animated: true)
    }

    private func showAllRecent() {
        let screen = TVRecentlyWatchedViewController(env: env, section: section, items: model.recentItems)
        navigationController?.pushViewController(screen, animated: true)
    }

    private func libraryItem(at indexPath: IndexPath) -> (item: PlexMetadata, isRecent: Bool)? {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .media(let id):
            return model.item(withId: id).map { ($0, false) }
        case .recent(let id):
            return model.recentItem(withId: id).map { ($0, true) }
        case .header, nil:
            return nil
        }
    }

    private func playItem(at indexPath: IndexPath) {
        guard let (item, _) = libraryItem(at: indexPath), item.mediaType != "show" else { return }
        TVScreens.play(env, request: TVPlaybackRequest(item: item), from: self)
    }

    private func menu(for item: PlexMetadata, isRecent: Bool) -> UIMenu {
        let actions = isRecent
            ? LibraryItemAction.recent(for: item, kind: section.kind)
            : LibraryItemAction.grid(for: item, kind: section.kind)
        return UIMenu(libraryActions: actions) { [weak self] action in
            self?.perform(action, on: item, isRecent: isRecent)
        }
    }

    private func perform(_ action: LibraryItemAction, on item: PlexMetadata, isRecent: Bool) {
        switch action.kind {
        case .play:
            TVScreens.play(env, request: TVPlaybackRequest(item: item, resumeSeconds: isRecent ? 0 : nil), from: self)
        case .setWatched(let watched):
            model.setWatched(ratingKey: item.id, watched: watched)
        case .goToShow(let showKey):
            TVScreens.open(.show(ratingKey: showKey), env: env, on: navigationController)
        case .viewDetails:
            TVScreens.open(isRecent ? .media(item) : LibraryDestination(browsing: item), env: env, on: navigationController)
        }
    }
}

extension TVLibraryViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let (item, isRecent) = libraryItem(at: indexPath) else { return }
        let destination = isRecent ? LibraryDestination(recent: item, kind: section.kind) : LibraryDestination(browsing: item)
        TVScreens.open(destination, env: env, on: navigationController)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard case .media = dataSource.itemIdentifier(for: indexPath) else { return }
        model.loadNextPageIfNeeded(near: indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let (item, isRecent) = libraryItem(at: indexPath) else { return nil }
        return TVContextMenu.configuration(menu: menu(for: item, isRecent: isRecent))
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        if let pendingFocus { return pendingFocus }
        if let remembered = focusMemory.preferredIndexPath(in: collectionView) { return remembered }
        let snapshot = dataSource.snapshot()
        if let recents = snapshot.indexOfSection(.recents), snapshot.numberOfItems(inSection: .recents) > 0 {
            return IndexPath(item: 0, section: recents)
        }
        if let grid = snapshot.indexOfSection(.grid), snapshot.numberOfItems(inSection: .grid) > 0 {
            return IndexPath(item: 0, section: grid)
        }
        return nil
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        guard let next = context.nextFocusedIndexPath, dataSource.itemIdentifier(for: next) != .header else { return }
        focusMemory.record(context)
        if case .media = dataSource.itemIdentifier(for: next) {
            rail.currentLetter = model.letter(atGridIndex: next.item)
        }
    }
}

extension TVLibraryViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let grid = dataSource.snapshot().indexOfSection(.grid),
              let furthest = indexPaths.filter({ $0.section == grid }).map(\.item).max()
        else { return }
        model.loadNextPageIfNeeded(near: furthest)
    }
}
