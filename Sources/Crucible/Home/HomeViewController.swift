import CrucibleCore
import CrucibleDesign
import CrucibleStats
import MidgarCore
import os
@preconcurrency import UIKit

final class HomeViewController: UICollectionViewController {
    enum Section: Hashable {
        case skeleton, hero, continueWatching, upNext, week, recentlyAdded, watchlistReleases, rateWatched
    }

    enum Item: Hashable {
        case media(String, HomeBucket)
        case rate(String)
        case release(String)
        case missingNext(String)
        case week
        case skeleton
    }

    private let api: APIClient
    private let feed: HomeFeed
    private var loadTask: Task<Void, Never>?
    private var serverState: ServerStateFollower?
    private var weekTask: Task<Void, Never>?
    private var surpriseTask: Task<Void, Never>?
    private let surpriseMenuItem = UIBarButtonItem()
    private let serverMenuItem = UIBarButtonItem()
    private lazy var whatToWatchItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "wand.and.stars"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.openWhatToWatch()
        })
        item.accessibilityLabel = WatchCopy.title
        item.accessibilityIdentifier = "home.whatToWatch"
        return item
    }()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var preloaded: PlexMediaContainer?
    private var visibilityObserver: UUID?
    private var weekSummary: HomeWeekSummary?
    private var isShowingSkeleton = false
    private var skipNextAppearanceLoad = false
    private var playerCoordinator: PlayerCoordinator?
    private lazy var mediaDrag = MediaDragSource { [weak self] indexPath in self?.media(at: indexPath) }
    private weak var sectionGrid: HomeSectionGridViewController?
    private var heroHeight: CGFloat = 0
    private lazy var rateFeed = RatingAsksFeed(api: api)
    private var asks: [RatingAsk] = []
    private var pendingRated = Set<String>()
    private var asksTask: Task<Void, Never>?
    private var ledgerObserver: UUID?
    private var layoutObserver: UUID?
    private var releases: [WatchlistRelease] = []
    private var releasesObserver: UUID?
    private var releasesTask: Task<Void, Never>?
    private var missingNext: [MissingNext] = []
    private var missingNextObserver: UUID?
    private var missingNextTask: Task<Void, Never>?
    /// A pull to refresh also looks again for the next episodes the server lacks, once Home has reloaded.
    private var forceGaps = false

    init(api: APIClient, preloaded: PlexMediaContainer? = nil) {
        self.api = api
        self.feed = HomeFeed(api: api)
        self.preloaded = preloaded
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let visibilityObserver {
            Task { @MainActor in LibraryVisibility.removeObserver(visibilityObserver) }
        }
        if let ledgerObserver {
            Task { @MainActor in FinishedTitlesLedger.shared.removeObserver(ledgerObserver) }
        }
        if let layoutObserver {
            Task { @MainActor in HomeLayout.removeObserver(layoutObserver) }
        }
        if let releasesObserver {
            Task { @MainActor in WatchlistReleases.shared.removeObserver(releasesObserver) }
        }
        if let missingNextObserver {
            Task { @MainActor in UpNextGaps.shared.removeObserver(missingNextObserver) }
        }
        asksTask?.cancel()
        releasesTask?.cancel()
        missingNextTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Home", comment: "Navigation title of the Home tab")
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.allowsKeyboardFocus()
        collectionView.dragDelegate = mediaDrag
        collectionView.showsVerticalScrollIndicator = false
        configureNavButtons()
        configureDataSource()
        collectionView.collectionViewLayout = createLayout()

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            self?.forceGaps = true
            self?.loadData()
            self?.loadWeek()
            self?.loadReleases(force: true)
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
        visibilityObserver = LibraryVisibility.addObserver { [weak self] in
            self?.libraryVisibilityChanged()
        }
        layoutObserver = HomeLayout.addObserver { [weak self] in
            self?.libraryVisibilityChanged()
            self?.loadReleases(force: false)
        }
        releasesObserver = WatchlistReleases.shared.addObserver { [weak self] in
            self?.releasesChanged()
        }
        releases = WatchlistReleases.shared.releases()
        missingNextObserver = UpNextGaps.shared.addObserver { [weak self] in
            self?.missingNextChanged()
        }
        ledgerObserver = FinishedTitlesLedger.shared.addObserver { [weak self] in
            self?.asksChanged()
        }
        asks = rateFeed.current()
        followServerState()

        if let preloaded {
            self.preloaded = nil
            skipNextAppearanceLoad = true
            apply(container: preloaded, animated: false)
        } else if !hydrateFromSnapshot() {
            showSkeleton()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        updateServerMenu()
        loadWeek()
        loadAsks()
        loadReleases(force: false)
        _ = serverState?.takeStale()
        if skipNextAppearanceLoad {
            skipNextAppearanceLoad = false
        } else {
            loadData()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    /// Anything that moves Continue Watching, Up Next or Recently Added, here or on another device, reloads Home while it or its
    /// See All grid is on screen; otherwise Home reloads when it next appears, as it always does.
    private func followServerState() {
        serverState = ServerStateFollower(isOnScreen: { [weak self] in
            guard let self else { return false }
            return viewIfLoaded?.window != nil || sectionGrid?.viewIfLoaded?.window != nil
        }, refresh: { [weak self] in
            self?.loadData()
            self?.loadWeek()
        })
    }

    /// The hero grows with the window, so a resize or a rotation re-measures it. The pass can run inside a snapshot apply, so the
    /// hero is reconfigured once it is over rather than reentrantly.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = Theme.heroHeight(width: collectionView.bounds.width, height: collectionView.bounds.height)
        guard abs(height - heroHeight) > 0.5 else { return }
        heroHeight = height
        Task { @MainActor [weak self] in self?.reconfigureHero() }
    }

    private func reconfigureHero() {
        var snapshot = dataSource.snapshot()
        guard snapshot.sectionIdentifiers.contains(.hero) else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers(inSection: .hero))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Snapshot cache

    @discardableResult
    private func hydrateFromSnapshot() -> Bool {
        guard feed.hydrateFromSnapshot() else { return false }
        rebuildSnapshot(animated: false)
        return true
    }

    private func libraryVisibilityChanged() {
        asks = rateFeed.current()
        guard !isShowingSkeleton else { return }
        feed.reapplyLibraryVisibility()
        rebuildSnapshot(animated: true)
        contentUnavailableConfiguration = feed.isEmpty ? Self.emptyHomeConfiguration() : nil
        sectionGrid.map { $0.update(items: feed.arrangement.items(for: $0.bucket)) }
        loadWeek()
    }

    private static func emptyHomeConfiguration() -> UIContentUnavailableConfiguration {
        let copy = HomeStateCopy.empty(librariesAreFiltered: LibraryVisibility.isCustomized, rowsAreHidden: HomeLayout.contentRowsAreOff)
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "play.rectangle")
        config.text = copy.title
        config.secondaryText = copy.message
        return config
    }

    // MARK: - Content

    private func showSkeleton() {
        isShowingSkeleton = true
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.skeleton])
        snapshot.appendItems([.skeleton], toSection: .skeleton)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func rebuildSnapshot(animated: Bool) {
        let layout = feed.arrangement
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if let hero = layout.hero {
            snapshot.appendSections([.hero])
            snapshot.appendItems([.media(hero.id, .hero)], toSection: .hero)
        }
        for row in HomeLayout.visibleRows() {
            switch row {
            case .continueWatching where !layout.continueRail.isEmpty:
                snapshot.appendSections([.continueWatching])
                snapshot.appendItems(layout.continueRail.map { .media($0.id, .continueWatching) }, toSection: .continueWatching)
            case .upNext where !layout.upNext.isEmpty || (!layout.isEmpty && !missingNext.isEmpty):
                snapshot.appendSections([.upNext])
                snapshot.appendItems(layout.upNext.map { .media($0.id, .upNext) } + missingNext.map { .missingNext($0.id) }, toSection: .upNext)
            case .thisWeek where layout.showsWeekCard(hasWeekActivity: weekSummary?.isEmpty == false):
                snapshot.appendSections([.week])
                snapshot.appendItems([.week], toSection: .week)
            case .recentlyAdded where !layout.recent.isEmpty:
                snapshot.appendSections([.recentlyAdded])
                snapshot.appendItems(layout.recent.map { .media($0.id, .recentlyAdded) }, toSection: .recentlyAdded)
            case .watchlistReleases where !layout.isEmpty && !releases.isEmpty:
                snapshot.appendSections([.watchlistReleases])
                snapshot.appendItems(releases.map { .release($0.id) }, toSection: .watchlistReleases)
            case .rateWatched where !layout.isEmpty && !visibleAsks.isEmpty:
                snapshot.appendSections([.rateWatched])
                snapshot.appendItems(visibleAsks.map { .rate($0.id) }, toSection: .rateWatched)
            default:
                break
            }
        }

        let current = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { current.indexOfItem($0) != nil })

        let wasSkeleton = isShowingSkeleton
        isShowingSkeleton = false
        if wasSkeleton, !layout.isEmpty, view.window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: collectionView, duration: 0.25, options: .transitionCrossDissolve) {
                self.dataSource.apply(snapshot, animatingDifferences: false)
            }
        } else {
            dataSource.apply(snapshot, animatingDifferences: animated && !wasSkeleton)
        }
        refreshSectionGrid()
    }

    private func refreshSectionGrid() {
        guard let sectionGrid else { return }
        sectionGrid.update(items: feed.arrangement.items(for: sectionGrid.bucket))
    }

    // MARK: - Layout

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self,
                  let section = dataSource.snapshot().sectionIdentifiers[safe: sectionIndex] else { return nil }
            let hugeType = environment.traitCollection.preferredContentSizeCategory >= .accessibilityExtraLarge
            let room = Theme.Room(environment)
            switch section {
            case .skeleton:
                let layoutSection = Self.fullWidthSection(estimatedHeight: 420)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0)
                return layoutSection
            case .hero:
                let layoutSection = Self.fullWidthSection(estimatedHeight: Theme.Size.heroCardHeight)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: room.gutter, bottom: Theme.Space.xs, trailing: room.gutter)
                return layoutSection
            case .week:
                let layoutSection = Self.fullWidthSection(estimatedHeight: 96)
                var insets = Theme.sideInsets(environment)
                insets.top = Theme.Space.m
                insets.bottom = Theme.Space.xs
                layoutSection.contentInsets = insets
                return layoutSection
            case .continueWatching:
                let width = room.landscapeCardWidth
                return Theme.railSection(
                    width: width,
                    estimatedHeight: width * 9 / 16 + 52,
                    columns: hugeType ? 1 : nil,
                    gutter: room.gutter
                )
            case .upNext, .recentlyAdded, .watchlistReleases, .rateWatched:
                let width = room.posterRailWidth
                return Theme.railSection(
                    width: width,
                    estimatedHeight: width * Theme.Size.posterAspect + Theme.Size.captionBlockHeight,
                    columns: hugeType ? 2 : nil,
                    gutter: room.gutter
                )
            }
        }
    }

    private static func fullWidthSection(estimatedHeight: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimatedHeight))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        return NSCollectionLayoutSection(group: group)
    }

    // MARK: - Cells

    private func configureDataSource() {
        let heroReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let item = feed.item(id: id) else { return }
            cell.contentConfiguration = heroConfiguration(for: item)
        }

        let landscapeReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let item = self?.feed.item(id: id) else { return }
            cell.contentConfiguration = HomeMediaActions.landscapeConfiguration(for: item)
        }

        let posterReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, entry in
            guard case .media(let id, let bucket) = entry, let item = self?.feed.item(id: id) else { return }
            cell.contentConfiguration = HomeMediaActions.posterConfiguration(for: item, bucket: bucket)
        }

        let rateReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let ask = self?.asks.first(where: { $0.id == id }) else { return }
            cell.contentConfiguration = RateAskActions.posterConfiguration(for: ask)
            cell.accessibilityIdentifier = "home.rate.\(id)"
        }

        let missingNextReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let entry = self?.missingNext.first(where: { $0.id == id }) else { return }
            cell.contentConfiguration = HomeMediaActions.posterConfiguration(for: entry)
            cell.accessibilityIdentifier = "home.missingNext.\(entry.showRatingKey)"
        }

        let releaseReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let release = self?.releases.first(where: { $0.id == id }) else { return }
            cell.contentConfiguration = WatchlistReleaseActions.posterConfiguration(for: release)
            cell.accessibilityIdentifier = "home.release.\(release.discoverKey)"
        }

        let weekReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            cell.contentConfiguration = HomeWeekConfiguration(model: self?.weekSummary?.cardModel)
        }

        let skeletonReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { cell, _, _ in
            cell.contentConfiguration = HomeSkeletonConfiguration()
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .media(let id, .hero):
                return collectionView.dequeueConfiguredReusableCell(using: heroReg, for: indexPath, item: id)
            case .media(let id, .continueWatching):
                return collectionView.dequeueConfiguredReusableCell(using: landscapeReg, for: indexPath, item: id)
            case .media:
                return collectionView.dequeueConfiguredReusableCell(using: posterReg, for: indexPath, item: item)
            case .rate(let id):
                return collectionView.dequeueConfiguredReusableCell(using: rateReg, for: indexPath, item: id)
            case .release(let id):
                return collectionView.dequeueConfiguredReusableCell(using: releaseReg, for: indexPath, item: id)
            case .missingNext(let id):
                return collectionView.dequeueConfiguredReusableCell(using: missingNextReg, for: indexPath, item: id)
            case .week:
                return collectionView.dequeueConfiguredReusableCell(using: weekReg, for: indexPath, item: item)
            case .skeleton:
                return collectionView.dequeueConfiguredReusableCell(using: skeletonReg, for: indexPath, item: item)
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            guard let self, let section = dataSource.snapshot().sectionIdentifiers[safe: indexPath.section] else { return }
            var config = SectionHeaderConfiguration()
            switch section {
            case .continueWatching:
                config.title = feed.arrangement.title(for: .continueWatching)
            case .upNext:
                config.title = feed.arrangement.title(for: .upNext)
                if !feed.arrangement.upNext.isEmpty {
                    config.actionTitle = String(localized: "See All")
                    config.onAction = { [weak self] in self?.showAll(.upNext) }
                }
            case .recentlyAdded:
                config.title = feed.arrangement.title(for: .recentlyAdded)
                config.actionTitle = String(localized: "See All")
                config.onAction = { [weak self] in self?.showAll(.recentlyAdded) }
            case .watchlistReleases:
                config.title = WatchlistReleaseCopy.rowTitle
            case .rateWatched:
                config.title = RatingAskCopy.rowTitle
                config.actionTitle = String(localized: "See All")
                config.onAction = { [weak self] in self?.showAllAsks() }
            case .skeleton, .hero, .week:
                break
            }
            cell.contentConfiguration = config
        }

        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func heroConfiguration(for item: PlexMetadata) -> HomeHeroConfiguration {
        let model = feed.heroModel(for: item)
        var config = HomeHeroConfiguration()
        let id = model.id
        config.artwork = model.backdropPath.map { .backdrop($0) } ?? .none
        config.eyebrow = model.eyebrow
        config.title = model.title
        config.subtitle = model.subtitle
        config.actionTitle = model.actionTitle
        config.trailingText = model.trailingText
        config.progress = model.progress
        config.spokenLabel = model.spokenLabel
        config.minimumHeight = Theme.heroHeight(width: collectionView.bounds.width, height: collectionView.bounds.height)
        config.onPrimary = { [weak self] in self?.play(id: id) }
        config.onDetails = { [weak self] in self?.openDetail(id: id) }
        return config
    }

    // MARK: - Navigation bar

    private func configureNavButtons() {
        surpriseMenuItem.image = UIImage(systemName: "shuffle")
        surpriseMenuItem.accessibilityLabel = String(localized: "Surprise Me")
        let kinds: [(SurpriseMe.Kind, String)] = [
            (.any, "sparkles"),
            (.movie, "film"),
            (.show, "tv"),
        ]
        surpriseMenuItem.menu = UIMenu(title: String(localized: "Surprise Me"), children: kinds.map { kind, symbol in
            UIAction(title: kind.menuTitle, image: UIImage(systemName: symbol)) { [weak self] _ in self?.surprise(kind) }
        })

        serverMenuItem.image = UIImage(systemName: "server.rack")
        navigationItem.rightBarButtonItems = HostedBrain.isAvailable ? [serverMenuItem, surpriseMenuItem, whatToWatchItem] : [serverMenuItem, surpriseMenuItem]
        updateServerMenu()
    }

    private func updateServerMenu() {
        let connection = ServerBootstrap.connection()
        let name = connection?.serverName ?? String(localized: "Plex Server")
        let route = connection.map { HomeServerRoute.classify($0.serverURI) }
        let status = UIAction(
            title: String(localized: "Connected to \(name)"),
            image: UIImage(systemName: route?.symbol ?? "checkmark.circle.fill"),
            attributes: [.disabled],
            handler: { _ in }
        )
        status.subtitle = route.map { String(localized: "\($0.title) connection") }
        let switchServer = UIAction(title: String(localized: "Switch Server"), image: UIImage(systemName: "arrow.left.arrow.right")) { [weak self] _ in
            self?.presentServerSwitcher()
        }
        serverMenuItem.menu = UIMenu(children: DemoMode.shared.isActive ? [status] : [status, switchServer])
        serverMenuItem.accessibilityLabel = route.map { String(localized: "Server: \(name), \($0.title.lowercased())") } ?? String(localized: "Server: \(name)")
    }

    private func presentServerSwitcher() {
        Haptics.selection()
        let setup = ServerSetupViewController()
        setup.allowsCancel = true
        setup.onConnected = { [weak self] _ in
            if let scene = self?.view.window?.windowScene?.delegate as? SceneDelegate {
                scene.reconfigureRoot()
            }
        }
        let nav = UINavigationController(rootViewController: setup)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    // MARK: - Surprise Me

    func surprise(_ kind: SurpriseMe.Kind) {
        Haptics.selection()
        guard surpriseTask == nil else { return }
        surpriseTask = Task { [weak self] in
            guard let self else { return }
            defer { surpriseTask = nil }
            let pick: SurpriseMe.Target?
            do {
                pick = try await feed.surprise(kind)
            } catch let failure as SurpriseMe.LookupFailure {
                Haptics.error()
                presentSurpriseFailure(failure)
                return
            } catch {
                return
            }
            guard let pick else {
                Haptics.error()
                presentNothingToPick(kind)
                return
            }
            switch pick {
            case .movie(let ratingKey):
                navigationController?.pushViewController(MediaDetailViewController(api: api, ratingKey: ratingKey, mediaType: "movie"), animated: true)
            case .show(let ratingKey):
                navigationController?.pushViewController(ShowDetailViewController(api: api, showRatingKey: ratingKey), animated: true)
            }
        }
    }

    private func presentSurpriseFailure(_ failure: SurpriseMe.LookupFailure) {
        let alert = UIAlertController(title: SurpriseMe.lookupFailedTitle, message: failure.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func presentNothingToPick(_ kind: SurpriseMe.Kind) {
        let alert = UIAlertController(title: SurpriseMe.nothingToPickTitle, message: SurpriseMe.nothingToPickMessage(for: kind), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    // MARK: - Loading

    private func loadData() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await feed.refresh()
                WatchlistReleases.shared.noteOnServer(feed.fetchedItems)
                missingNext = UpNextGaps.shared.entries(nextUp: feed.nextUpItems)
                presentLoadedContent(animated: !isShowingSkeleton && dataSource.snapshot().numberOfItems > 0)
                loadMissingNext(force: forceGaps)
                forceGaps = false
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Home load failed: \(error.localizedDescription)", category: .networking)
                endRefreshing()
                showLoadError(error)
            }
        }
    }

    /// Keeps cached content on screen when a refresh fails; only an empty Home shows the error.
    private func showLoadError(_ error: Error) {
        guard feed.isEmpty else { return }
        if isShowingSkeleton {
            isShowingSkeleton = false
            dataSource.apply(NSDiffableDataSourceSnapshot<Section, Item>(), animatingDifferences: false)
        }
        let copy = HomeStateCopy.loadFailed(error)
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "wifi.exclamationmark")
        config.text = copy.title
        config.secondaryText = copy.message
        config.button = ThemeButton.primaryConfiguration(title: String(localized: "Retry"))
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in
            guard let self else { return }
            contentUnavailableConfiguration = nil
            showSkeleton()
            loadData()
        }
        contentUnavailableConfiguration = config
    }

    private func loadWeek() {
        guard let store = StatsManager.shared.store else {
            if weekSummary != nil {
                weekSummary = nil
                if !isShowingSkeleton { rebuildSnapshot(animated: true) }
            }
            return
        }
        weekTask?.cancel()
        weekTask = Task { [weak self] in
            let summary = await store.homeWeekSummaryOrNil()
            guard !Task.isCancelled, let self, summary != weekSummary else { return }
            weekSummary = summary
            if !isShowingSkeleton && !feed.isEmpty {
                rebuildSnapshot(animated: true)
            }
        }
    }

    private func apply(container: PlexMediaContainer, animated: Bool) {
        feed.apply(container: container)
        presentLoadedContent(animated: animated)
    }

    private func presentLoadedContent(animated: Bool) {
        rebuildSnapshot(animated: animated)
        endRefreshing()

        contentUnavailableConfiguration = feed.isEmpty ? Self.emptyHomeConfiguration() : nil
    }

    private func endRefreshing() {
        guard let refreshControl = collectionView.refreshControl, refreshControl.isRefreshing else { return }
        refreshControl.endRefreshing()
        Haptics.soft()
    }

    // MARK: - Interaction

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .media(let id, let bucket):
            guard let media = feed.item(id: id) else { return }
            switch HomeTapPolicy.action(for: media, in: bucket) {
            case .play: play(id: id)
            case .openDetail: openDetail(id: id)
            }
        case .rate(let id):
            guard let ask = asks.first(where: { $0.id == id }) else { return }
            rate(ask, source: collectionView.cellForItem(at: indexPath) ?? collectionView)
        case .release(let id):
            guard let release = releases.first(where: { $0.id == id }) else { return }
            WatchlistReleaseActions.open(release, api: api, from: self)
        case .missingNext(let id):
            guard let entry = missingNext.first(where: { $0.id == id }) else { return }
            navigationController?.pushViewController(ShowDetailViewController(api: api, showRatingKey: entry.showRatingKey, initialSeasonKey: entry.initialSeasonKey), animated: true)
        case .week:
            navigationController?.pushViewController(StatisticsViewController(api: api), animated: true)
        case .skeleton:
            break
        }
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        if case .rate(let id) = item, let ask = asks.first(where: { $0.id == id }) {
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                guard let self else { return nil }
                return RateAskActions.menu(
                    for: ask,
                    api: api,
                    navigation: { [weak self] in self?.navigationController },
                    rate: { [weak self] in
                        guard let self else { return }
                        rate(ask, source: collectionView.cellForItem(at: indexPath) ?? collectionView)
                    }
                )
            })
        }
        if case .missingNext(let id) = item, let entry = missingNext.first(where: { $0.id == id }), SeerrAccount.shared.isConnected {
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                guard let self else { return nil }
                return UIMenu(title: entry.showTitle, children: [
                    UIAction(title: SeerrCopy.request, image: UIImage(systemName: "plus.circle")) { [weak self] _ in
                        guard let self else { return }
                        SeerrRequestViewController.present(for: entry.showMetadata, api: api, isOnServer: true, from: self)
                    },
                ])
            })
        }
        if case .release(let id) = item, let release = releases.first(where: { $0.id == id }) {
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                guard let self else { return nil }
                return WatchlistReleaseActions.menu(for: release, api: api, host: self)
            })
        }
        guard case .media(let id, let bucket) = item, let media = feed.item(id: id) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return HomeMediaActions.contextMenu(
                for: media,
                in: bucket,
                api: api,
                navigation: { [weak self] in self?.navigationController },
                play: { [weak self] item in self?.play(id: item.id) },
                didChange: { [weak self] in self?.loadData() }
            ).addingNewWindow(for: media)
        })
    }

    private func media(at indexPath: IndexPath) -> PlexMetadata? {
        guard case .media(let id, _) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return feed.item(id: id)
    }

    // MARK: - Rate What You Watched

    private var visibleAsks: [RatingAsk] {
        asks.filter { !pendingRated.contains($0.id) }
    }

    private func loadAsks() {
        asksTask?.cancel()
        asksTask = Task { [weak self] in
            guard let self else { return }
            let loaded = await rateFeed.load()
            guard !Task.isCancelled else { return }
            adoptAsks(loaded)
        }
    }

    private func asksChanged() {
        adoptAsks(rateFeed.current())
    }

    private func adoptAsks(_ loaded: [RatingAsk]) {
        pendingRated = pendingRated.filter { key in loaded.contains { $0.id == key } }
        guard loaded != asks else { return }
        asks = loaded
        if !isShowingSkeleton { rebuildSnapshot(animated: true) }
    }

    private func rate(_ ask: RatingAsk, source: UIView) {
        RateAskActions.rate(ask, api: api, from: self, source: source) { [weak self] picked in
            guard let self else { return }
            if picked { pendingRated.insert(ask.id) } else { pendingRated.remove(ask.id) }
            if !isShowingSkeleton { rebuildSnapshot(animated: true) }
        }
    }

    // MARK: - Out Now on Your Watchlist

    /// Looks for new seasons and episodes of watchlisted shows while their row is on Home; a fresh look is reused unless the
    /// viewer pulled to refresh.
    private func loadReleases(force: Bool) {
        guard HomeLayout.isOn(.watchlistReleases), releasesTask == nil || force else { return }
        releasesTask?.cancel()
        releasesTask = Task { [weak self, api] in
            await WatchlistReleases.shared.refresh(api: api, force: force)
            self?.releasesTask = nil
        }
    }

    /// Looks for the next episode, aired but not on the server, of the shows the viewer is caught up on, once Home's own
    /// rows have said which shows the server has a next episode for.
    private func loadMissingNext(force: Bool) {
        guard HomeLayout.isOn(.upNext) else { return }
        let candidates = UpNextGaps.candidates(followed: FollowedShows.recentlyFinished(), nextUp: feed.nextUpItems)
        missingNextTask?.cancel()
        missingNextTask = Task { [api] in
            await UpNextGaps.shared.refresh(api: api, candidates: candidates, force: force)
        }
    }

    private func missingNextChanged() {
        let current = UpNextGaps.shared.entries(nextUp: feed.nextUpItems)
        guard current != missingNext else { return }
        missingNext = current
        if !isShowingSkeleton { rebuildSnapshot(animated: true) }
    }

    private func releasesChanged() {
        let current = WatchlistReleases.shared.releases()
        guard current != releases else { return }
        releases = current
        if !isShowingSkeleton { rebuildSnapshot(animated: true) }
    }

    private func showAllAsks() {
        navigationController?.pushViewController(RateWatchedViewController(api: api), animated: true)
    }

    private func showAll(_ bucket: HomeBucket) {
        let grid = HomeSectionGridViewController(
            api: api,
            title: feed.arrangement.title(for: bucket),
            bucket: bucket,
            items: feed.arrangement.items(for: bucket),
            onChange: { [weak self] in self?.loadData() }
        )
        grid.onAppear = { [weak self] in
            guard let self, serverState?.takeStale() == true else { return }
            loadData()
        }
        sectionGrid = grid
        navigationController?.pushViewController(grid, animated: true)
    }

    private func openDetail(id: String) {
        guard let media = feed.item(id: id) else { return }
        HomeMediaActions.openDetail(media, api: api, from: navigationController)
    }

    /// The title the Home hero offers to resume or start, for the demo tour's "Show me".
    /// Opens What to Watch on top of Home, as its bar button does.
    func openWhatToWatch() {
        guard !(navigationController?.topViewController is WhatToWatchViewController) else { return }
        navigationController?.pushViewController(WhatToWatchViewController(api: api), animated: true)
    }

    func playHighlightedTitle() {
        guard let media = feed.arrangement.hero ?? feed.arrangement.continueRail.first else { return }
        play(id: media.id)
    }

    /// Names from the library on screen, show names first, for a search the demo tour can type.
    var sampleTitles: [String] {
        let arrangement = feed.arrangement
        let items = (arrangement.hero.map { [$0] } ?? []) + arrangement.continueRail + arrangement.upNext + arrangement.recent
        return items.map { $0.grandparentTitle ?? $0.title }
    }

    /// An episode or film on Home that is not downloaded yet, for the demo tour's download step.
    var downloadCandidate: PlexMetadata? {
        let arrangement = feed.arrangement
        let items = (arrangement.hero.map { [$0] } ?? []) + arrangement.upNext + arrangement.continueRail + arrangement.recent
        return items.first { HomeMediaRules.isDownloadable($0) && DownloadManager.shared.item(for: $0.id) == nil }
    }

    private func play(id: String) {
        guard let media = feed.item(id: id) else { return }
        guard HomeTapPolicy.playOrDetail(for: media) == .play else {
            openDetail(id: id)
            return
        }
        Haptics.light()
        playerCoordinator = Theme.quickPlay(api: api, item: media, from: self)
    }
}

extension HomeViewController: CommandHandling {
    func canPerform(_ command: AppCommand) -> Bool {
        switch command {
        case .refresh: return !isShowingSkeleton
        case .play: return feed.arrangement.hero ?? feed.arrangement.continueRail.first != nil
        default: return false
        }
    }

    func perform(_ command: AppCommand) {
        switch command {
        case .refresh:
            loadData()
            loadWeek()
        case .play: playHighlightedTitle()
        default: break
        }
    }

    /// Space resumes what the Home hero offers, named in the menu bar.
    func title(for command: AppCommand) -> String? {
        guard command == .play, let item = feed.arrangement.hero ?? feed.arrangement.continueRail.first else { return nil }
        return String(localized: "\(feed.heroModel(for: item).actionTitle) \u{201C}\(item.grandparentTitle ?? item.title)\u{201D}")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
