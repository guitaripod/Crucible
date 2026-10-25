import CrucibleCore
import CrucibleDesign
import CrucibleStats
import os
@preconcurrency import UIKit

final class HomeViewController: UICollectionViewController {
    enum Section: Hashable {
        case skeleton, hero, continueWatching, upNext, week, recentlyAdded
    }

    enum Item: Hashable {
        case media(String, HomeBucket)
        case week
        case skeleton
    }

    private let api: APIClient
    private let feed: HomeFeed
    private var loadTask: Task<Void, Never>?
    private var weekTask: Task<Void, Never>?
    private var surpriseTask: Task<Void, Never>?
    private let surpriseMenuItem = UIBarButtonItem()
    private let serverMenuItem = UIBarButtonItem()
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
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
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
            self?.loadData()
            self?.loadWeek()
        }, for: .valueChanged)
        collectionView.refreshControl = refresh
        visibilityObserver = LibraryVisibility.addObserver { [weak self] in
            self?.libraryVisibilityChanged()
        }

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
        guard !isShowingSkeleton else { return }
        feed.reapplyLibraryVisibility()
        rebuildSnapshot(animated: true)
        contentUnavailableConfiguration = feed.isEmpty ? Self.emptyHomeConfiguration() : nil
        sectionGrid.map { $0.update(items: feed.arrangement.items(for: $0.bucket)) }
        loadWeek()
    }

    private static func emptyHomeConfiguration() -> UIContentUnavailableConfiguration {
        let copy = HomeStateCopy.empty(librariesAreFiltered: LibraryVisibility.isCustomized)
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
        if !layout.continueRail.isEmpty {
            snapshot.appendSections([.continueWatching])
            snapshot.appendItems(layout.continueRail.map { .media($0.id, .continueWatching) }, toSection: .continueWatching)
        }
        if !layout.upNext.isEmpty {
            snapshot.appendSections([.upNext])
            snapshot.appendItems(layout.upNext.map { .media($0.id, .upNext) }, toSection: .upNext)
        }
        if layout.showsWeekCard(hasWeekActivity: weekSummary?.isEmpty == false) {
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
            case .upNext, .recentlyAdded:
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
                config.actionTitle = "See All"
                config.onAction = { [weak self] in self?.showAll(.upNext) }
            case .recentlyAdded:
                config.title = feed.arrangement.title(for: .recentlyAdded)
                config.actionTitle = "See All"
                config.onAction = { [weak self] in self?.showAll(.recentlyAdded) }
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
        surpriseMenuItem.accessibilityLabel = "Surprise Me"
        let kinds: [(SurpriseMe.Kind, String)] = [
            (.any, "sparkles"),
            (.movie, "film"),
            (.show, "tv"),
        ]
        surpriseMenuItem.menu = UIMenu(title: "Surprise Me", children: kinds.map { kind, symbol in
            UIAction(title: kind.menuTitle, image: UIImage(systemName: symbol)) { [weak self] _ in self?.surprise(kind) }
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
        serverMenuItem.menu = UIMenu(children: DemoMode.shared.isActive ? [status] : [status, switchServer])
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
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func presentNothingToPick(_ kind: SurpriseMe.Kind) {
        let alert = UIAlertController(title: SurpriseMe.nothingToPickTitle, message: SurpriseMe.nothingToPickMessage(for: kind), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Loading

    private func loadData() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await feed.refresh()
                presentLoadedContent(animated: !isShowingSkeleton && dataSource.snapshot().numberOfItems > 0)
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
              let media = feed.item(id: id) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return HomeMediaActions.contextMenu(
                for: media,
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

    private func showAll(_ bucket: HomeBucket) {
        let grid = HomeSectionGridViewController(
            api: api,
            title: feed.arrangement.title(for: bucket),
            bucket: bucket,
            items: feed.arrangement.items(for: bucket),
            onChange: { [weak self] in self?.loadData() }
        )
        sectionGrid = grid
        navigationController?.pushViewController(grid, animated: true)
    }

    private func openDetail(id: String) {
        guard let media = feed.item(id: id) else { return }
        HomeMediaActions.openDetail(media, api: api, from: navigationController)
    }

    /// The title the Home hero offers to resume or start, for the demo tour's "Show me".
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
        return "\(feed.heroModel(for: item).actionTitle) \u{201C}\(item.grandparentTitle ?? item.title)\u{201D}"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
