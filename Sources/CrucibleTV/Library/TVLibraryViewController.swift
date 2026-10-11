import CrucibleCore
import CrucibleDesign
import UIKit

/// One library as a screen: a header with the title, count, watch filters and Genre and Sort menus,
/// a Recently Watched shelf (unfiltered only), and the poster grid with an A-Z rail on the trailing
/// edge. Everything that is not drawing lives in `LibraryGridModel`.
final class TVLibraryViewController: TVScreenViewController {
    enum Section: Hashable {
        case header, recents, grid
    }

    enum Item: Hashable {
        case header
        case recent(String)
        case media(String)
    }

    /// Where a row of posters is scrolled to on a jump, just under the floating tab bar.
    private static let jumpClearance = TVMetrics.tabBarClearance

    /// How long the grid waits for Recently Watched before it is shown without the shelf.
    private static let revealDeadline = Duration.milliseconds(1500)

    private let env: TVAppEnvironment
    private let section: LibrarySection
    private let model: LibraryGridModel
    private let rail = TVAlphabetRail()
    private let railFade = TVGradientView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var pendingFocus: IndexPath?
    private let recentCells = NSMapTable<NSString, UICollectionViewCell>(keyOptions: .copyIn, valueOptions: .weakMemory)
    private var hasRevealedContent = false
    private var hasPassedRevealDeadline = false
    private var shelfInserted = false
    private var shownState: String?
    private lazy var revealSlot = makeTaskSlot()
    private lazy var actions = TVLibraryItemActions(env: env, kind: section.kind, presenter: self) { [weak self] item, watched in
        self?.model.setWatched(ratingKey: item.id, watched: watched)
    }

    init(env: TVAppEnvironment, section: LibrarySection) {
        self.env = env
        self.section = section
        model = LibraryGridModel(api: env.api, sectionId: section.id, kind: section.kind, offersContinueBanner: false)
        super.init(layout: UICollectionViewLayout())
        title = section.title
        model.onUpdate = { [weak self] update in
            self?.modelDidUpdate(update)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.prefetchDataSource = self
        setupRail()
        configureDataSource()
        collectionView.collectionViewLayout = makeLayout()
        applySnapshot()
        model.loadGenres()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        startRevealDeadline()
        model.appear(visibleGridIndex: firstVisibleGridIndex)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappear()
    }

    /// The grid position on screen, so a deeply scrolled grid refreshes around it on return.
    private var firstVisibleGridIndex: Int {
        guard let grid = dataSource.snapshot().indexOfSection(.grid) else { return 0 }
        return collectionView.indexPathsForVisibleItems.filter { $0.section == grid }.map(\.item).min() ?? 0
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        guard !isShowingState,
              let indexPath = indexPathForPreferredFocusedView(in: collectionView),
              let cell = visibleCell(at: indexPath)
        else { return super.preferredFocusEnvironments }
        return [cell]
    }

    /// The cell for `indexPath`. A cell inside the horizontally scrolling shelf is not reported by the
    /// collection view, so the shelf's cells are tracked as they are configured.
    private func visibleCell(at indexPath: IndexPath) -> UICollectionViewCell? {
        if case .recent(let id) = dataSource.itemIdentifier(for: indexPath) {
            guard let cell = recentCells.object(forKey: id as NSString),
                  cell.window != nil,
                  (cell as? TVCardCell)?.item?.id == id
            else { return nil }
            return cell
        }
        return collectionView.cellForItem(at: indexPath)
    }

    /// The first poster on screen: the first Recently Watched card when the shelf is shown, otherwise
    /// the first grid poster.
    override func initialFocusIndexPath() -> IndexPath? {
        let snapshot = dataSource.snapshot()
        if let recents = snapshot.indexOfSection(.recents), snapshot.numberOfItems(inSection: .recents) > 0 {
            return IndexPath(item: 0, section: recents)
        }
        if let grid = snapshot.indexOfSection(.grid), snapshot.numberOfItems(inSection: .grid) > 0 {
            return IndexPath(item: 0, section: grid)
        }
        return nil
    }

    override func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        pendingFocus ?? super.indexPathForPreferredFocusedView(in: collectionView)
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
            guard let self, dataSource.snapshot().sectionIdentifiers.indices.contains(index) else { return TVShelf.grid() }
            switch dataSource.snapshot().sectionIdentifiers[index] {
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
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(180))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let section = NSCollectionLayoutSection(group: NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item]))
        section.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.tabBarClearance, leading: 0, bottom: TVMetrics.shelfVerticalInset, trailing: 0)
        return section
    }

    private func configureDataSource() {
        let headerRegistration = UICollectionView.CellRegistration<TVHostCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.showLibraryHeader(headerContent())
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
        adopt(dataSource)
    }

    private func headerContent() -> TVLibraryHeaderContent {
        let options = model.options
        var content = TVLibraryHeaderContent(
            title: section.title,
            count: countText(),
            chips: LibraryWatchFilter.allCases.map { TVChipItem(id: $0.rawValue, title: $0.title, isSelected: options.isChipSelected($0)) },
            genreTitle: options.genre == nil ? "Genre" : options.genreTitle(in: model.genres),
            isGenreSelected: options.genre != nil,
            genres: model.genres.map { .init(key: $0.key, title: $0.title, isSelected: options.genre == $0.key) },
            sortTitle: "Sort",
            sorts: section.kind.sortOptions.map { .init(key: $0.key, title: $0.title, isSelected: options.sort == $0.key) }
        )
        content.handlers = .init(
            onFilter: { [weak self] in self?.model.selectChip($0) },
            onGenre: { [weak self] in self?.model.setGenre($0) },
            onSort: { [weak self] in self?.model.setSort($0) },
            onBrowseFolders: { [weak self] in self?.browseFolders() }
        )
        return content
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
        case .pageLoaded:
            revealContentIfReady()
            if hasRevealedContent { applySnapshot() }
            applyContentState()
        case .recents:
            revealContentIfReady()
            if hasRevealedContent {
                if !shelfInserted, !isFocusInGrid { shelfInserted = true }
                applySnapshot()
            }
            applyContentState()
        case .pageFailed:
            applyContentState()
        case .continueItem:
            break
        case .alphabet:
            updateRail()
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.header])
        snapshot.appendItems([.header], toSection: .header)
        let recents = shelfInserted ? model.visibleRecents : []
        if !recents.isEmpty {
            snapshot.appendSections([.recents])
            snapshot.appendItems(recents.map { Item.recent($0.id) }, toSection: .recents)
        }
        snapshot.appendSections([.grid])
        snapshot.appendItems(model.gridIds.map(Item.media), toSection: .grid)
        dataSource.applyReconfiguringExisting(snapshot)
        updateRail()
    }

    private func reconfigureHeader() {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(.header) != nil else { return }
        snapshot.reconfigureItems([.header])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The first page and the Recently Watched shelf are shown together: a shelf that appeared later would
    /// push the posters, and the focus on them, down the screen. A slow history request must not hold the
    /// grid back, so after `revealDeadline` the grid is shown without the shelf. The shelf then joins only
    /// while the focus is outside the grid (see `isFocusInGrid`), so nothing moves under the user.
    private func revealContentIfReady() {
        guard !hasRevealedContent, model.pager.hasLoaded, model.hasLoadedRecents || hasPassedRevealDeadline else { return }
        hasRevealedContent = true
        shelfInserted = model.hasLoadedRecents
        revealSlot.cancel()
    }

    private func startRevealDeadline() {
        guard !hasRevealedContent else { return }
        revealSlot.run { [weak self] in
            try? await Task.sleep(for: Self.revealDeadline)
            guard !Task.isCancelled, let self else { return }
            hasPassedRevealDeadline = true
            revealContentIfReady()
            if hasRevealedContent { applySnapshot() }
            applyContentState()
        }
    }

    private func isGrid(_ section: Int?) -> Bool {
        section.map { dataSource.sectionIdentifier(for: $0) == .grid } ?? false
    }

    private var isFocusInGrid: Bool {
        isGrid(TVPlayPauseShortcut.focusedIndexPath(in: collectionView)?.section)
    }

    /// Adds a shelf that arrived late once the focus has left the grid.
    private func insertDeferredShelfIfSafe(focusedSection: Int?) {
        guard hasRevealedContent, !shelfInserted, model.hasLoadedRecents, !model.visibleRecents.isEmpty, !isGrid(focusedSection) else { return }
        shelfInserted = true
        Task { [weak self] in self?.applySnapshot() }
    }

    /// Shows what the model's state calls for. The host is only asked when the state itself changes:
    /// asking on every page would move the focus off the chip that was just pressed.
    private func applyContentState() {
        let state = model.contentState
        let key: String
        switch state {
        case .content: key = hasRevealedContent ? "content" : "loading"
        case .loading: key = "loading"
        case .failed(let message): key = "failed \(message)"
        case .noMatches: key = "noMatches"
        case .empty: key = "empty"
        }
        if key != shownState {
            shownState = key
            switch state {
            case .content:
                if hasRevealedContent { showContent() } else { show(state: .loading(title: nil)) }
            case .loading:
                show(state: .loading(title: nil))
            case .failed(let message):
                show(state: .error(title: "Couldn’t Load Library", message: message, retryTitle: "Try Again", retry: { [weak self] in
                    self?.model.refreshAll()
                }))
            case .noMatches:
                show(state: .empty(
                    title: "No Matches",
                    message: "Nothing in this library matches the current filters.",
                    symbol: "line.3.horizontal.decrease.circle",
                    action: .init(title: "Clear Filters") { [weak self] in self?.model.clearFilters() }
                ))
            case .empty:
                show(state: .empty(
                    title: section.kind.emptyTitle,
                    message: "Add media to this library on your Plex server to see it here.",
                    symbol: section.kind.placeholderIcon,
                    action: .init(title: "Check Again") { [weak self] in self?.model.refreshAll() }
                ))
            }
        }
        updateRail()
    }

    private func updateRail() {
        let visible = !isShowingState && model.offersAlphabetJump
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
        TVNavigation.push(TVFolderBrowserViewController(env: env, source: .section(section.id), title: "Browse Folders", kind: section.kind), from: self)
    }

    private func showAllRecent() {
        TVNavigation.push(TVRecentlyWatchedViewController(env: env, section: section, items: model.recentItems), from: self)
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

    override func playFocused(at indexPath: IndexPath) -> Bool {
        guard let (item, isRecent) = libraryItem(at: indexPath) else { return false }
        return actions.play(item, isRecent: isRecent)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let (item, isRecent) = libraryItem(at: indexPath) else { return }
        actions.select(item, isRecent: isRecent)
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
        return TVContextMenu.configuration(menu: actions.menu(for: item, isRecent: isRecent))
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.collectionView(collectionView, didUpdateFocusIn: context, with: coordinator)
        insertDeferredShelfIfSafe(focusedSection: context.nextFocusedIndexPath?.section)
        guard let next = context.nextFocusedIndexPath, case .media = dataSource.itemIdentifier(for: next) else { return }
        rail.currentLetter = model.letter(atGridIndex: next.item)
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
