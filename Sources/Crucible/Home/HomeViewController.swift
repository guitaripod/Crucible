@preconcurrency import UIKit
import os

final class HomeViewController: UICollectionViewController {
    enum Section: Hashable {
        case skeleton, hero, continueWatching, upNext, week, recentlyAdded
    }

    enum Item: Hashable {
        case media(String, HomeBucket)
        case week
        case skeleton
    }

    private enum SurpriseKind {
        case any, movie, show
    }

    private enum SurpriseTarget: Hashable {
        case movie(String)
        case show(String)
    }

    /// What the Home sections show, derived from the three hub buckets.
    private struct Arrangement {
        var hero: PlexMetadata?
        var heroIsContinue = false
        var continueRail: [PlexMetadata] = []
        var upNext: [PlexMetadata] = []
        var recent: [PlexMetadata] = []

        var isEmpty: Bool { hero == nil && continueRail.isEmpty && upNext.isEmpty && recent.isEmpty }
    }

    private let api: APIClient
    private var loadTask: Task<Void, Never>?
    private var weekTask: Task<Void, Never>?
    private var surpriseTask: Task<Void, Never>?
    private let surpriseMenuItem = UIBarButtonItem()
    private let serverMenuItem = UIBarButtonItem()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var mediaById: [String: PlexMetadata] = [:]
    private var snapshotArt: [String: String] = [:]
    private var preloaded: PlexMediaContainer?
    private var continueItems: [PlexMetadata] = []
    private var onDeckItems: [PlexMetadata] = []
    private var recentItems: [PlexMetadata] = []
    private var arrangement = Arrangement()
    private var weekSummary: HomeWeekSummary?
    private var isShowingSkeleton = false
    private var skipNextAppearanceLoad = false
    private var playerCoordinator: PlayerCoordinator?
    private weak var sectionGrid: HomeSectionGridViewController?

    init(api: APIClient, preloaded: PlexMediaContainer? = nil) {
        self.api = api
        self.preloaded = preloaded
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.showsVerticalScrollIndicator = false
        configureNavButtons()
        configureDataSource()
        collectionView.collectionViewLayout = createLayout()

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            self?.loadData()
            self?.loadWeek()
        }, for: .valueChanged)
        collectionView.refreshControl = refresh

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

    // MARK: - Snapshot cache

    @discardableResult
    private func hydrateFromSnapshot() -> Bool {
        guard let machineId = ServerBootstrap.connection()?.machineIdentifier,
              let snapshotData = HomeSnapshotStore.loadSync(),
              snapshotData.machineIdentifier == machineId,
              !snapshotData.cards.isEmpty else { return false }

        var continueItems = [PlexMetadata]()
        var onDeckItems = [PlexMetadata]()
        var recentItems = [PlexMetadata]()
        var art = [String: String]()
        for card in snapshotData.cards {
            let media = PlexMetadata(homeCard: card)
            if let path = card.grandparentArt ?? card.art { art[media.id] = path }
            switch card.bucket {
            case "cw": continueItems.append(media)
            case "od": onDeckItems.append(media)
            default: recentItems.append(media)
            }
        }
        snapshotArt = art
        setContent(continueItems: continueItems, onDeckItems: onDeckItems, recentItems: recentItems)
        rebuildSnapshot(animated: false)
        return true
    }

    private static func homeCards(continueItems: [PlexMetadata], onDeckItems: [PlexMetadata], recentItems: [PlexMetadata]) -> [HomeCardSnapshot] {
        let cap = 20
        func card(_ item: PlexMetadata, _ bucket: String) -> HomeCardSnapshot {
            var card = item.homeCard(bucket: bucket)
            card.art = item.art
            card.grandparentArt = item.grandparentArt
            return card
        }
        return continueItems.prefix(cap).map { card($0, "cw") }
            + onDeckItems.prefix(cap).map { card($0, "od") }
            + recentItems.prefix(cap).map { card($0, "ra") }
    }

    private static func dedupe(_ items: [PlexMetadata]) -> [PlexMetadata] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Content

    private func setContent(continueItems: [PlexMetadata], onDeckItems: [PlexMetadata], recentItems: [PlexMetadata]) {
        self.continueItems = Self.dedupe(continueItems)
        self.onDeckItems = Self.dedupe(onDeckItems)
        self.recentItems = Self.dedupe(recentItems)
        mediaById = Dictionary(
            (self.continueItems + self.onDeckItems + self.recentItems).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        arrangement = Self.arrange(continueItems: self.continueItems, onDeckItems: self.onDeckItems, recentItems: self.recentItems)
    }

    /// The hero is the first Continue Watching item, else the first On Deck item; it is not repeated
    /// in the rails below, and Up Next skips anything already in Continue Watching.
    private static func arrange(continueItems: [PlexMetadata], onDeckItems: [PlexMetadata], recentItems: [PlexMetadata]) -> Arrangement {
        var result = Arrangement()
        result.recent = recentItems
        if let first = continueItems.first {
            result.hero = first
            result.heroIsContinue = true
            result.continueRail = Array(continueItems.dropFirst())
        } else if let first = onDeckItems.first {
            result.hero = first
        }
        let excluded = Set(continueItems.map(\.id)).union(result.hero.map { [$0.id] } ?? [])
        result.upNext = onDeckItems.filter { !excluded.contains($0.id) }
        return result
    }

    private func showSkeleton() {
        isShowingSkeleton = true
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.skeleton])
        snapshot.appendItems([.skeleton], toSection: .skeleton)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func rebuildSnapshot(animated: Bool) {
        let layout = arrangement
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if let hero = layout.hero {
            snapshot.appendSections([.hero])
            snapshot.appendItems([.media(hero.id, .hero)], toSection: .hero)
        }
        if !layout.continueRail.isEmpty {
            snapshot.appendSections([.continueWatching])
            snapshot.appendItems(layout.continueRail.map { .media($0.id, .continueWatching) }, toSection: .continueWatching)
        }
        if !layout.upNext.isEmpty {
            snapshot.appendSections([.upNext])
            snapshot.appendItems(layout.upNext.map { .media($0.id, .upNext) }, toSection: .upNext)
        }
        if !layout.isEmpty, let weekSummary, !weekSummary.isEmpty {
            snapshot.appendSections([.week])
            snapshot.appendItems([.week], toSection: .week)
        }
        if !layout.recent.isEmpty {
            snapshot.appendSections([.recentlyAdded])
            snapshot.appendItems(layout.recent.map { .media($0.id, .recentlyAdded) }, toSection: .recentlyAdded)
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

    private func items(for bucket: HomeBucket) -> [PlexMetadata] {
        switch bucket {
        case .hero: return arrangement.hero.map { [$0] } ?? []
        case .continueWatching: return arrangement.continueRail
        case .upNext: return arrangement.upNext
        case .recentlyAdded: return arrangement.recent
        }
    }

    private func refreshSectionGrid() {
        guard let sectionGrid else { return }
        sectionGrid.update(items: items(for: sectionGrid.bucket))
    }

    // MARK: - Layout

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self,
                  let section = dataSource.snapshot().sectionIdentifiers[safe: sectionIndex] else { return nil }
            let hugeType = environment.traitCollection.preferredContentSizeCategory >= .accessibilityExtraLarge
            switch section {
            case .skeleton:
                let layoutSection = Self.fullWidthSection(estimatedHeight: 420)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 0, trailing: 0)
                return layoutSection
            case .hero:
                let layoutSection = Self.fullWidthSection(estimatedHeight: Theme.Size.heroCardHeight)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: Theme.Space.m, bottom: Theme.Space.xs, trailing: Theme.Space.m)
                return layoutSection
            case .week:
                let layoutSection = Self.fullWidthSection(estimatedHeight: 96)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: Theme.Space.m, leading: Theme.Space.m, bottom: Theme.Space.xs, trailing: Theme.Space.m)
                return layoutSection
            case .continueWatching:
                return Theme.railSection(
                    width: Theme.Size.landscapeCardWidth,
                    estimatedHeight: Theme.Size.landscapeCardHeight + 52,
                    columns: hugeType ? 1 : nil
                )
            case .upNext, .recentlyAdded:
                return Theme.railSection(
                    width: Theme.Size.posterRailWidth,
                    estimatedHeight: Theme.Size.posterRailWidth * Theme.Size.posterAspect + Theme.Size.captionBlockHeight,
                    columns: hugeType ? 2 : nil
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
            guard let self, let item = mediaById[id] else { return }
            cell.contentConfiguration = heroConfiguration(for: item)
        }

        let landscapeReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let item = self?.mediaById[id] else { return }
            cell.contentConfiguration = HomeMediaActions.landscapeConfiguration(for: item)
        }

        let posterReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, entry in
            guard case .media(let id, let bucket) = entry, let item = self?.mediaById[id] else { return }
            cell.contentConfiguration = HomeMediaActions.posterConfiguration(for: item, bucket: bucket)
        }

        let weekReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            cell.contentConfiguration = HomeWeekConfiguration(summary: self?.weekSummary)
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
                config.title = "Continue Watching"
            case .upNext:
                config.title = "Up Next"
                config.actionTitle = "See All"
                config.onAction = { [weak self] in self?.showAll(.upNext, title: "Up Next") }
            case .recentlyAdded:
                config.title = "Recently Added"
                config.actionTitle = "See All"
                config.onAction = { [weak self] in self?.showAll(.recentlyAdded, title: "Recently Added") }
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
        var config = HomeHeroConfiguration()
        let id = item.id
        let resuming = item.positionSecs > 0
        config.artwork = heroBackdropPath(for: item).map { .backdrop($0) } ?? .none
        config.eyebrow = arrangement.heroIsContinue ? "Continue Watching" : "Up Next"
        config.title = HomeFormat.title(for: item)
        config.subtitle = HomeFormat.heroSubtitle(for: item)
        config.actionTitle = resuming ? "Resume" : "Play"
        config.trailingText = HomeFormat.remaining(item) ?? HomeFormat.runtime(item.durationSecs)
        config.progress = resuming ? item.progressPercent : nil

        let timePhrase: String? = {
            if let left = HomeFormat.remainingSeconds(item) { return "\(HomeFormat.spoken(left)) left" }
            return item.durationSecs > 0 ? HomeFormat.spoken(item.durationSecs) : nil
        }()
        let episode = item.mediaType == "episode" ? HomeFormat.spokenEpisode(season: item.parentIndex, episode: item.index) : nil
        config.spokenLabel = [
            "\(config.actionTitle) \(config.title)",
            episode,
            timePhrase,
        ].compactMap { $0 }.joined(separator: ", ")

        config.onPrimary = { [weak self] in self?.play(id: id) }
        config.onDetails = { [weak self] in self?.openDetail(id: id) }
        return config
    }

    /// Show backdrop for episodes, the item's own backdrop otherwise; the cached snapshot's art
    /// stands in on a cold launch, and the thumb is the last resort.
    private func heroBackdropPath(for item: PlexMetadata) -> String? {
        if item.mediaType == "episode" {
            return item.grandparentArt ?? item.art ?? snapshotArt[item.id] ?? item.thumb
        }
        return item.art ?? snapshotArt[item.id] ?? item.thumb ?? item.grandparentThumb
    }

    // MARK: - Navigation bar

    private func configureNavButtons() {
        surpriseMenuItem.image = UIImage(systemName: "shuffle")
        surpriseMenuItem.accessibilityLabel = "Surprise Me"
        let kinds: [(String, String, SurpriseKind)] = [
            ("Any", "sparkles", .any),
            ("Movie", "film", .movie),
            ("Show", "tv", .show),
        ]
        surpriseMenuItem.menu = UIMenu(title: "Surprise Me", children: kinds.map { title, symbol, kind in
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in self?.surprise(kind) }
        })

        serverMenuItem.image = UIImage(systemName: "server.rack")
        navigationItem.rightBarButtonItems = [serverMenuItem, surpriseMenuItem]
        updateServerMenu()
    }

    private func updateServerMenu() {
        let connection = ServerBootstrap.connection()
        let name = connection?.serverName ?? "Plex Server"
        let route = connection.map { HomeServerRoute.classify($0.serverURI) }
        let status = UIAction(
            title: "Connected to \(name)",
            image: UIImage(systemName: route?.symbol ?? "checkmark.circle.fill"),
            attributes: [.disabled],
            handler: { _ in }
        )
        status.subtitle = route.map { "\($0.title) connection" }
        let switchServer = UIAction(title: "Switch Server", image: UIImage(systemName: "arrow.left.arrow.right")) { [weak self] _ in
            self?.presentServerSwitcher()
        }
        serverMenuItem.menu = UIMenu(children: [status, switchServer])
        serverMenuItem.accessibilityLabel = route.map { "Server: \(name), \($0.title.lowercased())" } ?? "Server: \(name)"
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

    private func surprise(_ kind: SurpriseKind) {
        Haptics.selection()
        guard surpriseTask == nil else { return }
        surpriseTask = Task { [weak self] in
            guard let self else { return }
            defer { surpriseTask = nil }
            var pool = recentItems
            do {
                let container = try await api.requestContainer(.recentlyAdded(start: 0, size: 100))
                pool = (container.Metadata ?? []) + pool
            } catch {
                AppLogger.error("Surprise Me fetch failed, using cached Home items: \(error.localizedDescription)", .networking)
            }
            guard !Task.isCancelled else { return }
            let targets = Set(pool.compactMap { Self.surpriseTarget(for: $0, kind: kind) })
            guard let pick = targets.randomElement() else {
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

    private static func surpriseTarget(for item: PlexMetadata, kind: SurpriseKind) -> SurpriseTarget? {
        switch item.mediaType {
        case "movie":
            return kind == .show ? nil : .movie(item.id)
        case "show":
            return kind == .movie ? nil : .show(item.id)
        case "season":
            guard kind != .movie, let key = item.parentRatingKey else { return nil }
            return .show(key)
        case "episode":
            guard kind != .movie, let key = item.grandparentRatingKey else { return nil }
            return .show(key)
        default:
            return nil
        }
    }

    private func presentNothingToPick(_ kind: SurpriseKind) {
        let noun: String
        switch kind {
        case .any: noun = "titles"
        case .movie: noun = "movies"
        case .show: noun = "shows"
        }
        let alert = UIAlertController(title: "Nothing to Pick", message: "There are no recently added \(noun) to choose from.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Loading

    private func loadData() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.hubs())
                guard !Task.isCancelled else { return }
                apply(container: container, animated: !isShowingSkeleton && dataSource.snapshot().numberOfItems > 0)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("Home load failed: \(error.localizedDescription)", .networking)
                endRefreshing()
                showLoadError(error)
            }
        }
    }

    /// Keeps cached content on screen when a refresh fails; only an empty Home shows the error.
    private func showLoadError(_ error: Error) {
        guard arrangement.isEmpty else { return }
        if isShowingSkeleton {
            isShowingSkeleton = false
            dataSource.apply(NSDiffableDataSourceSnapshot<Section, Item>(), animatingDifferences: false)
        }
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "wifi.exclamationmark")
        config.text = "Couldn't Reach Server"
        config.secondaryText = ConnectionError.message(for: error)
        config.button = ThemeButton.primaryConfiguration(title: "Retry")
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
            let summary: HomeWeekSummary?
            do {
                summary = try await store.homeWeekSummary()
            } catch {
                AppLogger.error("Home week summary failed: \(error.localizedDescription)", .stats)
                summary = nil
            }
            guard !Task.isCancelled, let self, summary != weekSummary else { return }
            weekSummary = summary
            if !isShowingSkeleton && !arrangement.isEmpty {
                rebuildSnapshot(animated: true)
            }
        }
    }

    private func apply(container: PlexMediaContainer, animated: Bool) {
        var continueItems = [PlexMetadata]()
        var onDeckItems = [PlexMetadata]()
        var recentItems = [PlexMetadata]()

        for hub in container.Hub ?? [] {
            guard let id = hub.hubIdentifier, let items = hub.Metadata, !items.isEmpty else { continue }
            let lowered = id.lowercased()
            if lowered.contains("continue") || lowered.contains("inprogress") {
                continueItems.append(contentsOf: items)
            } else if lowered.contains("ondeck") {
                onDeckItems.append(contentsOf: items)
            } else if lowered.contains("recentlyadded") || lowered.contains("recent") {
                recentItems.append(contentsOf: items)
            }
        }

        setContent(continueItems: continueItems, onDeckItems: onDeckItems, recentItems: recentItems)
        AppLogger.info("Home loaded: cw=\(self.continueItems.count) od=\(self.onDeckItems.count) ra=\(self.recentItems.count)", .networking)

        HomeSnapshotStore.save(HomeSnapshot(
            schema: HomeSnapshotStore.schemaVersion,
            machineIdentifier: ServerBootstrap.connection()?.machineIdentifier ?? "",
            savedAt: Int(Date().timeIntervalSince1970),
            cards: Self.homeCards(continueItems: self.continueItems, onDeckItems: self.onDeckItems, recentItems: self.recentItems)
        ))

        rebuildSnapshot(animated: animated)
        endRefreshing()

        if arrangement.isEmpty {
            var emptyConfig = UIContentUnavailableConfiguration.empty()
            emptyConfig.image = UIImage(systemName: "play.rectangle")
            emptyConfig.text = "Nothing Here Yet"
            emptyConfig.secondaryText = "Add media to your Plex libraries to see it here."
            contentUnavailableConfiguration = emptyConfig
        } else {
            contentUnavailableConfiguration = nil
        }
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
            guard let media = mediaById[id] else { return }
            switch bucket {
            case .hero, .recentlyAdded:
                openDetail(id: id)
            case .continueWatching:
                HomeMediaActions.isPlayable(media) ? play(id: id) : openDetail(id: id)
            case .upNext:
                HomeMediaActions.isPlayable(media) && media.positionSecs > 0 ? play(id: id) : openDetail(id: id)
            }
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
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath),
              case .media(let id, _) = item,
              let media = mediaById[id] else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return HomeMediaActions.contextMenu(
                for: media,
                api: api,
                navigation: { [weak self] in self?.navigationController },
                play: { [weak self] item in self?.play(id: item.id) },
                didChange: { [weak self] in self?.loadData() }
            )
        })
    }

    private func showAll(_ bucket: HomeBucket, title: String) {
        let grid = HomeSectionGridViewController(
            api: api,
            title: title,
            bucket: bucket,
            items: items(for: bucket),
            onChange: { [weak self] in self?.loadData() }
        )
        sectionGrid = grid
        navigationController?.pushViewController(grid, animated: true)
    }

    private func openDetail(id: String) {
        guard let media = mediaById[id] else { return }
        HomeMediaActions.openDetail(media, api: api, from: navigationController)
    }

    private func play(id: String) {
        guard let media = mediaById[id] else { return }
        guard HomeMediaActions.isPlayable(media) else {
            openDetail(id: id)
            return
        }
        Haptics.light()
        playerCoordinator = Theme.quickPlay(api: api, item: media, from: self)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
