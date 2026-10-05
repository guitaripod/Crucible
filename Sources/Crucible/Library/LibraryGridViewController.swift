@preconcurrency import UIKit

@MainActor
protocol LibraryGridHosting: AnyObject {
    func libraryGridDidUpdateOptions(_ grid: LibraryGridViewController)
}

/// One library section as a poster grid: filter chips, a Continue banner, paged posters and an
/// A–Z scrubber. Hosted by `LibraryViewController`, or pushed on its own (from Settings), in which
/// case it installs its own navigation-bar controls.
class LibraryGridViewController: UIViewController {
    typealias PageCompletion = @MainActor @Sendable () -> Void

    enum Section: Hashable {
        case header, grid
    }

    enum Item: Hashable {
        case header
        case media(String)
    }

    private static let pageSize = 50
    private static let prefetchThreshold = 10

    let collectionView: UICollectionView
    let kind: LibraryGridKind
    let sectionId: String
    private let api: APIClient
    private let scrubber = AlphabetScrubberView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    private var options = LibraryGridOptions()
    private var genres: [(key: String, title: String)] = []
    private var gridIds: [String] = []
    private var metadataById: [String: PlexMetadata] = [:]
    private var serverOffset = 0
    private var totalSize = 0
    private var hasLoaded = false
    private var isLoadingPage = false
    private var continueItem: PlexMetadata?
    private var alphabet: LibraryAlphabetIndex?

    private var loadTask: Task<Void, Never>?
    private var hubsTask: Task<Void, Never>?
    private var alphabetTask: Task<Void, Never>?
    private var genresTask: Task<Void, Never>?
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
        self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        hubsTask?.cancel()
        alphabetTask?.cancel()
        genresTask?.cancel()
        if let downloadObserver {
            Task { @MainActor in DownloadManager.shared.removeObserver(downloadObserver) }
        }
    }

    var isFiltering: Bool { options.isFiltering }

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
        loadGenres()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: LibraryGridViewController, _: UITraitCollection) in
            controller.reloadGridLayout()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        AppLogger.info("\(kind.logName) appeared section=\(sectionId)", .ui)
        installControls()
        observeDownloads()
        loadHubs()
        if alphabet == nil { loadAlphabet() }
        if hasLoaded {
            reloadLoadedPages()
        } else {
            loadPage(offset: 0)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        isLoadingPage = false
        if let downloadObserver {
            DownloadManager.shared.removeObserver(downloadObserver)
            self.downloadObserver = nil
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateScrubberVisibility()
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
            self?.refreshAll()
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
            guard let self, let item = metadataById[id] else {
                cell.contentConfiguration = PosterContentConfiguration()
                return
            }
            cell.contentConfiguration = posterConfiguration(for: item)
        }

        let headerRegistration = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = headerConfiguration()
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .header:
                return collectionView.dequeueConfiguredReusableCell(using: headerRegistration, for: indexPath, item: item)
            case .media(let id):
                return collectionView.dequeueConfiguredReusableCell(using: posterRegistration, for: indexPath, item: id)
            }
        }
    }

    private func posterConfiguration(for item: PlexMetadata) -> PosterContentConfiguration {
        var config = PosterContentConfiguration()
        config.posterPath = item.thumb ?? item.grandparentThumb
        config.title = item.title
        config.subtitle = item.year.map(String.init)
        config.placeholderIcon = kind.placeholderIcon
        switch kind {
        case .movie:
            let progress = item.progressPercent
            config.progress = progress > 0 ? progress : nil
            config.isUnwatched = !item.isWatched && progress <= 0
            config.isDownloaded = DownloadManager.shared.item(for: item.id)?.state == .completed
        case .show:
            let unwatched = (item.leafCount ?? 0) - (item.viewedLeafCount ?? 0)
            config.unwatchedCount = unwatched > 0 ? unwatched : nil
        }
        return config
    }

    private func headerConfiguration() -> LibraryHeaderConfiguration {
        var config = LibraryHeaderConfiguration()
        config.chips = chips()
        config.onChipSelect = { [weak self] id in
            self?.selectChip(id)
        }
        if let item = continueItem {
            let detail = LibraryFormat.continueDetail(item)
            config.banner = ContinueBannerModel(
                itemId: item.id,
                detail: detail,
                artPath: item.art ?? item.grandparentArt ?? item.thumb,
                spokenLabel: "Continue \(detail)"
            )
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
        snapshot.appendSections([.header, .grid])
        snapshot.appendItems([.header], toSection: .header)
        snapshot.appendItems(gridIds.map(Item.media), toSection: .grid)
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
            .filter { $0 != .header }
        guard !visible.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(visible)
        dataSource.apply(snapshot, animatingDifferences: false)
    }


    private func refreshAll() {
        loadHubs()
        loadAlphabet()
        loadPage(offset: 0)
    }

    func loadPage(offset: Int, size: Int = pageSize, then completion: PageCompletion? = nil) {
        loadTask?.cancel()
        isLoadingPage = true
        if offset == 0 { showLoadingState() }
        let endpoint = options.endpoint(sectionId: sectionId, start: offset, size: size)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(endpoint)
                guard !Task.isCancelled else { return }
                let items = container.Metadata ?? []
                totalSize = container.totalSize ?? 0
                if offset == 0 {
                    replaceItems(items)
                } else {
                    appendItems(items)
                }
                serverOffset = offset + items.count
                hasLoaded = true
                isLoadingPage = false
                endRefreshing()
                applySnapshot()
                updateEmptyState(error: nil)
                completion?()
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("\(kind.logName) page fetch failed section=\(sectionId) offset=\(offset): \(error.localizedDescription)", .networking)
                isLoadingPage = false
                endRefreshing()
                if gridIds.isEmpty { updateEmptyState(error: error) }
            }
        }
    }

    /// Refetches every page already loaded in one request so the grid picks up watched/progress
    /// changes on return without collapsing pagination or scroll position.
    private func reloadLoadedPages() {
        loadPage(offset: 0, size: max(serverOffset, Self.pageSize))
    }

    private func replaceItems(_ items: [PlexMetadata]) {
        var seen = Set<String>()
        gridIds = items.map(\.id).filter { !$0.isEmpty && seen.insert($0).inserted }
        metadataById = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func appendItems(_ items: [PlexMetadata]) {
        var seen = Set(gridIds)
        for item in items where !item.id.isEmpty {
            metadataById[item.id] = item
            if seen.insert(item.id).inserted { gridIds.append(item.id) }
        }
    }

    private func loadNextPageIfNeeded(near index: Int) {
        guard index >= gridIds.count - Self.prefetchThreshold, serverOffset < totalSize, !isLoadingPage else { return }
        loadPage(offset: serverOffset)
    }

    private func endRefreshing() {
        guard let refresh = collectionView.refreshControl, refresh.isRefreshing else { return }
        refresh.endRefreshing()
        Haptics.soft()
    }

    private func loadHubs() {
        hubsTask?.cancel()
        hubsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.sectionHubs(sectionId: sectionId))
                guard !Task.isCancelled else { return }
                let candidates = (container.Hub ?? [])
                    .filter { hub in
                        let id = (hub.hubIdentifier ?? "").lowercased()
                        return id.contains("continue") || id.contains("inprogress") || id.contains("ondeck")
                    }
                    .flatMap { $0.Metadata ?? [] }
                let next = candidates.first { $0.mediaType != "show" && $0.positionSecs > 0 }
                guard next?.id != continueItem?.id || next?.viewOffset != continueItem?.viewOffset else { return }
                continueItem = next
                reconfigureHeader()
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("\(kind.logName) hubs fetch failed section=\(sectionId): \(error.localizedDescription)", .networking)
            }
        }
    }

    private func loadGenres() {
        genresTask?.cancel()
        genresTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.sectionGenres(sectionId: sectionId))
                guard !Task.isCancelled else { return }
                genres = (container.Directory ?? []).compactMap { dir in
                    guard let key = dir.key, let title = dir.title else { return nil }
                    return (key: key, title: title)
                }
                optionsDidChange()
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("\(kind.logName) genres fetch failed section=\(sectionId): \(error.localizedDescription)", .networking)
            }
        }
    }

    private func loadAlphabet() {
        alphabetTask?.cancel()
        alphabetTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response: LibraryFirstCharacterResponse = try await api.request(.sectionFirstCharacter(sectionId: sectionId))
                guard !Task.isCancelled else { return }
                alphabet = LibraryAlphabetIndex(entries: response.MediaContainer.Directory ?? [])
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("\(kind.logName) firstCharacter fetch failed section=\(sectionId): \(error.localizedDescription)", .networking)
                alphabet = LibraryAlphabetIndex(entries: [])
            }
            updateScrubberVisibility()
            updateCurrentLetter()
        }
    }


    private func showLoadingState() {
        guard gridIds.isEmpty else { return }
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
    }

    private func updateEmptyState(error: Error?) {
        if let error {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "exclamationmark.triangle")
            config.text = "Couldn’t Load Library"
            config.secondaryText = ConnectionError.message(for: error)
            config.button = ThemeButton.primaryConfiguration(title: "Retry")
            config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                self?.contentUnavailableConfiguration = nil
                self?.refreshAll()
            }
            contentUnavailableConfiguration = config
            return
        }
        guard gridIds.isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.empty()
        if options.isFiltering {
            config.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
            config.text = "No Matches"
            config.secondaryText = "Nothing in this library matches the current filters."
            config.button = ThemeButton.primaryConfiguration(title: "Clear Filters")
            config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                self?.clearFilters()
            }
        } else {
            config.image = UIImage(systemName: kind.placeholderIcon)
            config.text = kind.emptyTitle
            config.secondaryText = "Add media to this library on your Plex server to see it here."
        }
        contentUnavailableConfiguration = config
    }


    private func update(_ change: (inout LibraryGridOptions) -> Void) {
        var next = options
        change(&next)
        guard next != options else { return }
        options = next
        AppLogger.info("\(kind.logName) options sort=\(next.sort) genre=\(next.genre ?? "-") filter=\(next.watch.rawValue)", .ui)
        optionsDidChange()
        scrollToTop()
        loadPage(offset: 0)
    }

    private func clearFilters() {
        Haptics.selection()
        update {
            $0.genre = nil
            $0.watch = .all
        }
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

    /// "All" clears every filter, so it is only lit when nothing narrows the grid; the other two
    /// toggle the server-side watch filter and leave a chosen genre in place.
    private func selectChip(_ id: String) {
        guard let filter = LibraryWatchFilter(rawValue: id) else { return }
        update {
            $0.watch = filter
            if filter == .all { $0.genre = nil }
        }
    }

    private func chips() -> [FilterChipsView.Chip] {
        var chips = LibraryWatchFilter.allCases.map { filter in
            let selected = filter == .all ? !options.isFiltering : options.watch == filter
            return FilterChipsView.Chip(id: filter.rawValue, title: filter.title, isSelected: selected)
        }
        if !genres.isEmpty {
            let title = genres.first { $0.key == options.genre }?.title ?? "Genre"
            chips.append(FilterChipsView.Chip(id: "genre", title: title, isSelected: options.genre != nil, menu: genreMenu(title: "Genre")))
        }
        let sortTitle = kind.sortOptions.first { $0.key == options.sort }?.title ?? "Title"
        chips.append(FilterChipsView.Chip(id: "sort", title: "Sort: \(sortTitle)", menu: sortMenu(title: "Sort By", inline: false)))
        return chips
    }

    func optionsMenu() -> UIMenu {
        var children: [UIMenuElement] = [
            sortMenu(title: "Sort By", inline: true),
            UIMenu(title: "Show", options: .displayInline, children: LibraryWatchFilter.allCases.map { filter in
                UIAction(title: filter.title, image: UIImage(systemName: filter.symbol), state: options.watch == filter ? .on : .off) { [weak self] _ in
                    Haptics.selection()
                    self?.update { $0.watch = filter }
                }
            }),
        ]
        if !genres.isEmpty {
            let title = genres.first { $0.key == options.genre }?.title ?? "Genre"
            children.append(genreMenu(title: title, image: UIImage(systemName: "tag")))
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
            UIAction(title: option.title, state: options.sort == option.key ? .on : .off) { [weak self] _ in
                Haptics.selection()
                self?.update { $0.sort = option.key }
            }
        })
    }

    private func genreMenu(title: String, image: UIImage? = nil) -> UIMenu {
        var actions = [UIAction(title: "All Genres", state: options.genre == nil ? .on : .off) { [weak self] _ in
            Haptics.selection()
            self?.update { $0.genre = nil }
        }]
        actions += genres.map { genre in
            UIAction(title: genre.title, state: options.genre == genre.key ? .on : .off) { [weak self] _ in
                Haptics.selection()
                self?.update { $0.genre = genre.key }
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
        optionsItem.image = LibraryGridOptions.optionsImage(filtering: options.isFiltering)
    }


    private func updateScrubberVisibility() {
        guard isViewLoaded else { return }
        let available = view.safeAreaLayoutGuide.layoutFrame.height - Theme.Space.m
        let needed = scrubber.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height
        let visible = options.allowsAlphabetJump
            && alphabet?.isUsable == true
            && !gridIds.isEmpty
            && contentUnavailableConfiguration == nil
            && needed <= available
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
        guard let alphabet, let offset = alphabet.offset(for: letter) else { return }
        if offset < gridIds.count {
            scrollToGridIndex(offset)
            return
        }
        guard serverOffset < totalSize else {
            scrollToGridIndex(gridIds.count - 1)
            return
        }
        let needed = offset - serverOffset + Self.pageSize
        AppLogger.info("\(kind.logName) A–Z jump letter=\(letter) offset=\(offset) loading \(needed)", .ui)
        loadPage(offset: serverOffset, size: needed) { [weak self] in
            self?.scrollToGridIndex(offset)
        }
    }

    /// Estimated cell heights make one long jump land slightly off, so the scroll is repeated after
    /// the layout has measured the cells around the target.
    private func scrollToGridIndex(_ index: Int) {
        guard !gridIds.isEmpty, let section = dataSource.snapshot().indexOfSection(.grid) else { return }
        let target = IndexPath(item: min(max(index, 0), gridIds.count - 1), section: section)
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
        guard !scrubber.isHidden, !scrubber.isTracking, let alphabet,
              let section = dataSource.snapshot().indexOfSection(.grid) else { return }
        let first = collectionView.indexPathsForVisibleItems.filter { $0.section == section }.min()
        scrubber.setCurrentLetter(first.flatMap { alphabet.letter(atOffset: $0.item) })
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
        navigationController?.pushViewController(FolderBrowserViewController(api: api, sectionId: sectionId, folderTitle: "Browse Folders"), animated: true)
    }

    private func openDetail(_ item: PlexMetadata, zoomingFrom sourceId: String? = nil) {
        let detail: UIViewController
        if item.mediaType == "show" {
            detail = ShowDetailViewController(api: api, showRatingKey: item.id)
        } else {
            detail = MediaDetailViewController(
                api: api,
                ratingKey: item.id,
                mediaType: item.mediaType,
                showRatingKey: item.grandparentRatingKey,
                seasonRatingKey: item.parentRatingKey
            )
        }
        if #available(iOS 18.0, *), let sourceId {
            detail.preferredTransition = .zoom { [weak self] _ in
                self?.posterCell(for: sourceId)
            }
        }
        navigationController?.pushViewController(detail, animated: true)
    }

    private func posterCell(for id: String) -> UIView? {
        guard let indexPath = dataSource.indexPath(for: .media(id)) else { return nil }
        return collectionView.cellForItem(at: indexPath)
    }

    private func quickPlay(_ item: PlexMetadata) {
        Haptics.light()
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }

    private func setWatched(_ item: PlexMetadata, watched: Bool) {
        Haptics.light()
        Task { [weak self] in
            guard let self else { return }
            do {
                if watched {
                    try await api.requestVoid(.scrobble(ratingKey: item.id))
                } else {
                    try await api.requestVoid(.unscrobble(ratingKey: item.id))
                }
            } catch {
                AppLogger.error("\(kind.logName) mark watched=\(watched) failed ratingKey=\(item.id): \(error.localizedDescription)", .networking)
            }
            await api.invalidateCache()
            reloadLoadedPages()
            loadHubs()
        }
    }

    private func contextMenu(for item: PlexMetadata) -> UIMenu {
        var actions = [UIMenuElement]()
        switch kind {
        case .movie:
            actions.append(UIAction(title: item.positionSecs > 0 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                self?.quickPlay(item)
            })
            actions.append(UIAction(title: item.isWatched ? "Mark Unwatched" : "Mark Watched", image: UIImage(systemName: item.isWatched ? "eye.slash" : "eye")) { [weak self] _ in
                self?.setWatched(item, watched: !item.isWatched)
            })
            actions.append(DownloadMenu.action(for: item))
        case .show:
            let total = item.leafCount ?? 0
            let allWatched = total > 0 && (item.viewedLeafCount ?? 0) >= total
            actions.append(UIAction(title: allWatched ? "Mark All Unwatched" : "Mark All Watched", image: UIImage(systemName: allWatched ? "eye.slash" : "checkmark.circle")) { [weak self] _ in
                self?.setWatched(item, watched: !allWatched)
            })
        }
        actions.append(UIAction(title: "View Details", image: UIImage(systemName: "info.circle")) { [weak self] _ in
            self?.openDetail(item)
        })
        return UIMenu(children: actions)
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
        guard case .media(let id) = dataSource.itemIdentifier(for: indexPath), let item = metadataById[id] else { return }
        openDetail(item, zoomingFrom: id)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard case .media = dataSource.itemIdentifier(for: indexPath) else { return }
        loadNextPageIfNeeded(near: indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              case .media(let id) = dataSource.itemIdentifier(for: indexPath),
              let item = metadataById[id] else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            self?.contextMenu(for: item)
        })
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCurrentLetter()
    }
}

extension LibraryGridViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let section = dataSource.snapshot().indexOfSection(.grid),
              let furthest = indexPaths.filter({ $0.section == section }).map(\.item).max() else { return }
        loadNextPageIfNeeded(near: furthest)
    }
}
