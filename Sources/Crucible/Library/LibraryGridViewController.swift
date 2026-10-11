import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

@MainActor
protocol LibraryGridHosting: AnyObject {
    func libraryGridDidUpdateOptions(_ grid: LibraryGridViewController)
}

/// One library section as a poster grid: filter chips, a Continue banner, paged posters and an
/// A–Z scrubber. Hosted by `LibraryViewController`, or pushed on its own (from Settings), in which
/// case it installs its own navigation-bar controls.
class LibraryGridViewController: UIViewController {
    enum Section: Hashable {
        case header, recentlyWatched, grid
    }

    enum Item: Hashable {
        case header
        case recent(String)
        case media(String)
    }

    let collectionView: UICollectionView
    let kind: LibraryGridKind
    let sectionId: String
    private let api: APIClient
    private let model: LibraryGridModel
    private let scrubber = AlphabetScrubberView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    private var downloadObserver: UUID?
    private var playerCoordinator: PlayerCoordinator?

    private lazy var optionsItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: LibraryGridOptions.optionsImage(filtering: false), menu: nil)
        item.accessibilityLabel = "Sort and Filter"
        return item
    }()

    private lazy var gridSizeItem = LibraryGridSizeMenu.barButtonItem { [weak self] in
        self?.reloadGridLayout()
    }

    init(api: APIClient, sectionId: String, kind: LibraryGridKind) {
        self.api = api
        self.sectionId = sectionId
        self.kind = kind
        self.model = LibraryGridModel(api: api, sectionId: sectionId, kind: kind)
        self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        super.init(nibName: nil, bundle: nil)
        model.onUpdate = { [weak self] update in
            self?.modelDidUpdate(update)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let downloadObserver {
            Task { @MainActor in DownloadManager.shared.removeObserver(downloadObserver) }
        }
    }

    var isFiltering: Bool { model.options.isFiltering }

    private var host: LibraryGridHosting? { parent as? LibraryGridHosting }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        navigationItem.largeTitleDisplayMode = .always
        setupCollectionView()
        setupScrubber()
        configureDataSource()
        collectionView.collectionViewLayout = makeLayout()
        applySnapshot()
        model.loadGenres()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: LibraryGridViewController, _: UITraitCollection) in
            controller.reloadGridLayout()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        AppLogger.info("\(kind.logName) appeared section=\(sectionId)", .ui)
        installControls()
        observeDownloads()
        model.appear(visibleGridIndex: firstVisibleGridIndex)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappear()
        if let downloadObserver {
            DownloadManager.shared.removeObserver(downloadObserver)
            self.downloadObserver = nil
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateScrubberVisibility()
    }

    /// The grid position the user is at, so a deeply scrolled grid refreshes around it.
    private var firstVisibleGridIndex: Int {
        guard let section = dataSource.snapshot().indexOfSection(.grid) else { return 0 }
        return collectionView.indexPathsForVisibleItems.filter { $0.section == section }.map(\.item).min() ?? 0
    }

    private func setupCollectionView() {
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            self?.model.refreshAll()
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
    }

    private func setupScrubber() {
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.isHidden = true
        scrubber.alpha = 0
        scrubber.onLetter = { [weak self] letter in
            self?.jump(to: letter)
        }
        view.addSubview(scrubber)
        let safe = view.safeAreaLayoutGuide
        let centered = scrubber.centerYAnchor.constraint(equalTo: safe.centerYAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scrubber.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: 2),
            scrubber.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: Theme.Space.xs),
            scrubber.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor, constant: -Theme.Space.xs),
            centered,
        ])
    }


    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let sections = dataSource.snapshot().sectionIdentifiers
            guard sections.indices.contains(sectionIndex) else { return nil }
            switch sections[sectionIndex] {
            case .header:
                return Self.headerSection()
            case .recentlyWatched:
                return Self.recentSection(environment: environment)
            case .grid:
                return Theme.gridLayout(environment: environment)
            }
        }
    }

    private static func headerSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        return NSCollectionLayoutSection(group: group)
    }

    private static func recentSection(environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        Theme.railSection(
            width: Theme.Size.posterRailWidth,
            estimatedHeight: Theme.Size.posterRailWidth * Theme.Size.posterAspect + Theme.Size.captionBlockHeight,
            columns: environment.traitCollection.preferredContentSizeCategory >= .accessibilityExtraLarge ? 2 : nil
        )
    }

    /// Re-flows the grid after the column preference changes; the layout reads the preference on
    /// every pass, so a fresh layout is all it takes.
    func reloadGridLayout() {
        guard isViewLoaded else { return }
        let animated = view.window != nil && !UIAccessibility.isReduceMotionEnabled
        collectionView.setCollectionViewLayout(makeLayout(), animated: animated)
        updateScrubberVisibility()
    }


    private func configureDataSource() {
        let posterRegistration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let item = model.item(withId: id) else {
                cell.contentConfiguration = PosterContentConfiguration()
                return
            }
            cell.contentConfiguration = posterConfiguration(for: item)
        }

        let recentRegistration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let item = model.recentItem(withId: id) else {
                cell.contentConfiguration = PosterContentConfiguration()
                return
            }
            cell.contentConfiguration = RecentlyWatchedActions.posterConfiguration(for: item, kind: kind)
        }

        let headerRegistration = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = headerConfiguration()
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .header:
                return collectionView.dequeueConfiguredReusableCell(using: headerRegistration, for: indexPath, item: item)
            case .recent(let id):
                return collectionView.dequeueConfiguredReusableCell(using: recentRegistration, for: indexPath, item: id)
            case .media(let id):
                return collectionView.dequeueConfiguredReusableCell(using: posterRegistration, for: indexPath, item: id)
            }
        }

        let railHeaderRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, _ in
            var config = SectionHeaderConfiguration()
            config.title = "Recently Watched"
            config.actionTitle = "See All"
            config.onAction = { [weak self] in self?.showAllRecent() }
            cell.contentConfiguration = config
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: railHeaderRegistration, for: indexPath)
        }
    }

    private func posterConfiguration(for item: PlexMetadata) -> PosterContentConfiguration {
        var config = LibraryPoster(grid: item, kind: kind).configuration
        if kind == .movie {
            config.isDownloaded = DownloadManager.shared.item(for: item.id)?.state == .completed
        }
        return config
    }

    private func headerConfiguration() -> LibraryHeaderConfiguration {
        var config = LibraryHeaderConfiguration()
        config.chips = chips()
        config.onChipSelect = { [weak self] id in
            self?.selectChip(id)
        }
        if let item = model.continueItem {
            config.banner = ContinueBannerModel(item: item)
            config.onBannerPlay = { [weak self] in
                self?.quickPlay(item)
            }
            config.onBannerDetails = { [weak self] in
                self?.openDetail(item)
            }
        }
        return config
    }

    private func applySnapshot() {
        let previous = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.header])
        snapshot.appendItems([.header], toSection: .header)
        let recents = model.visibleRecents
        if !recents.isEmpty {
            snapshot.appendSections([.recentlyWatched])
            snapshot.appendItems(recents.map { Item.recent($0.id) }, toSection: .recentlyWatched)
        }
        snapshot.appendSections([.grid])
        snapshot.appendItems(model.gridIds.map(Item.media), toSection: .grid)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { $0 != .header && previous.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: false)
        updateScrubberVisibility()
        updateCurrentLetter()
    }

    private func reconfigureHeader() {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(.header) != nil else { return }
        snapshot.reconfigureItems([.header])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigureVisiblePosters() {
        let visible = collectionView.indexPathsForVisibleItems.compactMap { dataSource.itemIdentifier(for: $0) }
            .filter { if case .media = $0 { return true } else { return false } }
        guard !visible.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(visible)
        dataSource.apply(snapshot, animatingDifferences: false)
    }


    private func modelDidUpdate(_ update: LibraryGridModel.Update) {
        switch update {
        case .optionsChanged:
            optionsDidChange()
            scrollToTop()
        case .contentState:
            applyContentState()
        case .pageLoaded:
            endRefreshing()
            applyContentState()
            applySnapshot()
        case .pageFailed:
            endRefreshing()
            applyContentState()
        case .continueItem:
            reconfigureHeader()
            applySnapshot()
        case .recents:
            applySnapshot()
        case .genres:
            optionsDidChange()
        case .alphabet:
            updateScrubberVisibility()
            updateCurrentLetter()
        }
    }

    private func endRefreshing() {
        guard let refresh = collectionView.refreshControl, refresh.isRefreshing else { return }
        refresh.endRefreshing()
        Haptics.soft()
    }

    private func applyContentState() {
        switch model.contentState {
        case .content:
            contentUnavailableConfiguration = nil
        case .loading:
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        case .failed(let message):
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "exclamationmark.triangle")
            config.text = "Couldn’t Load Library"
            config.secondaryText = message
            config.button = ThemeButton.primaryConfiguration(title: "Retry")
            config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                self?.contentUnavailableConfiguration = nil
                self?.model.refreshAll()
            }
            contentUnavailableConfiguration = config
        case .noMatches:
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
            config.text = "No Matches"
            config.secondaryText = "Nothing in this library matches the current filters."
            config.button = ThemeButton.primaryConfiguration(title: "Clear Filters")
            config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                self?.clearFilters()
            }
            contentUnavailableConfiguration = config
        case .empty:
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: kind.placeholderIcon)
            config.text = kind.emptyTitle
            config.secondaryText = "Add media to this library on your Plex server to see it here."
            contentUnavailableConfiguration = config
        }
    }

    private func clearFilters() {
        Haptics.selection()
        model.clearFilters()
    }

    private func optionsDidChange() {
        reconfigureHeader()
        if let host {
            host.libraryGridDidUpdateOptions(self)
        } else {
            refreshOwnControls()
        }
        updateScrubberVisibility()
    }

    private func selectChip(_ id: String) {
        guard let filter = LibraryWatchFilter(rawValue: id) else { return }
        model.selectChip(filter)
    }

    private func chips() -> [FilterChipsView.Chip] {
        let options = model.options
        var chips = LibraryWatchFilter.allCases.map { filter in
            FilterChipsView.Chip(id: filter.rawValue, title: filter.title, isSelected: options.isChipSelected(filter))
        }
        if !model.genres.isEmpty {
            chips.append(FilterChipsView.Chip(id: "genre", title: options.genreTitle(in: model.genres), isSelected: options.genre != nil, menu: genreMenu(title: "Genre")))
        }
        chips.append(FilterChipsView.Chip(id: "sort", title: "Sort: \(options.sortTitle(for: kind))", menu: sortMenu(title: "Sort By", inline: false)))
        return chips
    }

    func optionsMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            sortMenu(title: "Sort By", inline: true),
            UIMenu(title: "Show", options: .displayInline, children: LibraryWatchFilter.allCases.map { filter in
                UIAction(title: filter.title, image: UIImage(systemName: filter.symbol), state: model.options.watch == filter ? .on : .off) { [weak self] _ in
                    Haptics.selection()
                    self?.model.setWatch(filter)
                }
            }),
        ]
        if !model.genres.isEmpty {
            children.append(genreMenu(title: model.options.genreTitle(in: model.genres), image: UIImage(systemName: "tag")))
        }
        if host == nil {
            children.append(UIMenu(options: .displayInline, children: [
                UIAction(title: "Browse Folders", image: UIImage(systemName: "folder")) { [weak self] _ in
                    self?.openFolderBrowser()
                },
            ]))
        }
        return UIMenu(children: children)
    }

    private func sortMenu(title: String, inline: Bool) -> UIMenu {
        UIMenu(title: title, options: inline ? .displayInline : [], children: kind.sortOptions.map { option in
            UIAction(title: option.title, state: model.options.sort == option.key ? .on : .off) { [weak self] _ in
                Haptics.selection()
                self?.model.setSort(option.key)
            }
        })
    }

    private func genreMenu(title: String, image: UIImage? = nil) -> UIMenu {
        var actions = [UIAction(title: "All Genres", state: model.options.genre == nil ? .on : .off) { [weak self] _ in
            Haptics.selection()
            self?.model.setGenre(nil)
        }]
        actions += model.genres.map { genre in
            UIAction(title: genre.title, state: model.options.genre == genre.key ? .on : .off) { [weak self] _ in
                Haptics.selection()
                self?.model.setGenre(genre.key)
            }
        }
        return UIMenu(title: title, image: image, children: actions)
    }

    /// Stand-alone grids (pushed from Settings) have no library host, so they carry the grid-size and
    /// options buttons themselves.
    private func installControls() {
        guard host == nil else {
            host?.libraryGridDidUpdateOptions(self)
            return
        }
        refreshOwnControls()
        navigationItem.rightBarButtonItems = [optionsItem, gridSizeItem]
    }

    private func refreshOwnControls() {
        optionsItem.menu = optionsMenu()
        optionsItem.image = LibraryGridOptions.optionsImage(filtering: model.options.isFiltering)
    }


    private func updateScrubberVisibility() {
        guard isViewLoaded else { return }
        let available = view.safeAreaLayoutGuide.layoutFrame.height - Theme.Space.m
        let needed = scrubber.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
        let visible = model.offersAlphabetJump
            && contentUnavailableConfiguration == nil
            && needed <= available
        collectionView.showsVerticalScrollIndicator = !visible
        guard visible == scrubber.isHidden else { return }
        if visible { scrubber.isHidden = false }
        let animations = { self.scrubber.alpha = visible ? 1 : 0 }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self, !visible, self.scrubber.alpha == 0 else { return }
            self.scrubber.isHidden = true
        }
        if view.window == nil || UIAccessibility.isReduceMotionEnabled {
            animations()
            completion(true)
        } else {
            UIView.animate(withDuration: 0.2, animations: animations, completion: completion)
        }
    }

    private func jump(to letter: String) {
        model.jump(to: letter) { [weak self] index in
            self?.scrollToGridIndex(index)
        }
    }

    /// Estimated cell heights make one long jump land slightly off, so the scroll is repeated after
    /// the layout has measured the cells around the target.
    private func scrollToGridIndex(_ index: Int) {
        let count = model.gridIds.count
        guard count > 0, let section = dataSource.snapshot().indexOfSection(.grid) else { return }
        let target = IndexPath(item: min(max(index, 0), count - 1), section: section)
        collectionView.scrollToItem(at: target, at: .top, animated: false)
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: target, at: .top, animated: false)
    }

    private func scrollToTop() {
        let top = -collectionView.adjustedContentInset.top
        guard collectionView.contentOffset.y > top else { return }
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: top), animated: false)
    }

    private func updateCurrentLetter() {
        guard !scrubber.isHidden, !scrubber.isTracking, model.alphabet != nil,
              let section = dataSource.snapshot().indexOfSection(.grid) else { return }
        let first = collectionView.indexPathsForVisibleItems.filter { $0.section == section }.min()
        scrubber.setCurrentLetter(first.flatMap { model.letter(atGridIndex: $0.item) })
    }


    private func observeDownloads() {
        guard kind == .movie, downloadObserver == nil else { return }
        downloadObserver = DownloadManager.shared.addObserver { [weak self] event in
            switch event {
            case .changed, .finished, .failed:
                self?.reconfigureVisiblePosters()
            case .progress:
                break
            }
        }
    }


    func openFolderBrowser() {
        AppLogger.info("Folder browse tapped section=\(sectionId)", .ui)
        navigationController?.pushViewController(FolderBrowserViewController(api: api, source: .section(sectionId), folderTitle: "Browse Folders"), animated: true)
    }

    private func showAllRecent() {
        Haptics.selection()
        let grid = RecentlyWatchedGridViewController(api: api, sectionId: sectionId, kind: kind, items: model.recentItems)
        navigationController?.pushViewController(grid, animated: true)
    }

    private func openDetail(_ item: PlexMetadata, zoomingFrom source: Item? = nil) {
        guard let destination = LibraryDestination(browsing: item) else { return }
        push(destination.viewController(api: api), zoomingFrom: source)
    }

    private func push(_ detail: UIViewController, zoomingFrom source: Item?) {
        if #available(iOS 18.0, *), let source {
            detail.preferredTransition = .zoom { [weak self] _ in
                self?.posterCell(for: source)
            }
        }
        navigationController?.pushViewController(detail, animated: true)
    }

    private func posterCell(for item: Item) -> UIView? {
        guard let indexPath = dataSource.indexPath(for: item) else { return nil }
        return collectionView.cellForItem(at: indexPath)
    }

    private func quickPlay(_ item: PlexMetadata) {
        Haptics.light()
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }

    private func setWatched(_ item: PlexMetadata, watched: Bool) {
        Haptics.light()
        model.setWatched(ratingKey: item.id, watched: watched)
    }

    private func contextMenu(for item: PlexMetadata) -> UIMenu {
        var elements: [UIMenuElement] = LibraryItemAction.grid(for: item, kind: kind).map { action in
            action.menuAction { [weak self] in
                self?.perform(action, on: item)
            }
        }
        if kind == .movie {
            elements.insert(DownloadMenu.action(for: item), at: elements.count - 1)
        }
        return UIMenu(children: elements)
    }

    private func perform(_ action: LibraryItemAction, on item: PlexMetadata) {
        switch action.kind {
        case .play:
            quickPlay(item)
        case .setWatched(let watched):
            setWatched(item, watched: watched)
        case .viewDetails:
            openDetail(item)
        case .goToShow:
            return
        }
    }
}

extension LibraryGridViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != .header
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != .header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .media(let id):
            guard let item = model.item(withId: id) else { return }
            openDetail(item, zoomingFrom: .media(id))
        case .recent(let id):
            guard let item = model.recentItem(withId: id) else { return }
            push(RecentlyWatchedActions.destination(for: item, kind: kind, api: api), zoomingFrom: .recent(id))
        case .header, nil:
            return
        }
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
        guard let indexPath = indexPaths.first else { return nil }
        switch dataSource.itemIdentifier(for: indexPath) {
        case .media(let id):
            guard let item = model.item(withId: id) else { return nil }
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                self?.contextMenu(for: item)
            })
        case .recent(let id):
            guard let item = model.recentItem(withId: id) else { return nil }
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                guard let self else { return nil }
                return RecentlyWatchedActions.contextMenu(
                    for: item,
                    kind: kind,
                    api: api,
                    open: { [weak self] in self?.navigationController?.pushViewController($0, animated: true) },
                    play: { [weak self] in self?.quickPlay($0) }
                )
            })
        case .header, nil:
            return nil
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCurrentLetter()
    }
}

extension LibraryGridViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let section = dataSource.snapshot().indexOfSection(.grid),
              let furthest = indexPaths.filter({ $0.section == section }).map(\.item).max() else { return }
        model.loadNextPageIfNeeded(near: furthest)
    }
}
