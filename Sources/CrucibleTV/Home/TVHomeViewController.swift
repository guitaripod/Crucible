import CrucibleCore
import CrucibleDesign
import CrucibleStats
import UIKit

/// The cinematic Home: a full-screen backdrop and a hero block that follow the focused card, then
/// Continue Watching, Up Next, the This Week tile and Recently Added. The hero is information only
/// (it never takes focus), so every card, including the one the hero starts on, lives in its rail.
/// Content comes from the shared `HomeFeed`; the launch payload paints the first frame and every
/// later appearance refreshes it, keeping what is on screen when a refresh fails.
final class TVHomeViewController: TVScreenViewController {
    private final class LayoutSource {
        weak var screen: TVHomeViewController?
    }

    private let env: TVAppEnvironment
    private let feed: HomeFeed
    private lazy var actions = TVHomeActions(env: env) { [weak self] in
        self?.reload()
    }

    private let backdrop = TVBackdropView()
    private let homeCollectionView: TVHomeCollectionView
    private let skeleton = UIStackView()
    private var dataSource: UICollectionViewDiffableDataSource<TVHomeSection, TVHomeItem>!

    private lazy var loadSlot = makeTaskSlot()
    private lazy var weekSlot = makeTaskSlot()
    private lazy var surpriseSlot = makeTaskSlot()
    private var currentHero: TVHeroInfo?
    private var weekSummary: HomeWeekSummary?
    private var visibilityObserver: UUID?
    private var skipNextAppearanceLoad = true
    private var hasAwaitedFirstSync = false
    private weak var seeAll: TVHomeSeeAllViewController?

    init(env: TVAppEnvironment) {
        self.env = env
        feed = HomeFeed(api: env.api)
        let source = LayoutSource()
        let layout = Self.makeLayout(source)
        homeCollectionView = TVHomeCollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(layout: layout, collectionView: homeCollectionView)
        source.screen = self
        title = "Home"
        feed.apply(container: env.hubs)
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
        configureDataSource()
        softenTopEdge()
        visibilityObserver = LibraryVisibility.addObserver { [weak self] in
            self?.libraryVisibilityChanged()
        }
        render(animated: false)
    }

    override func installViews() {
        super.installViews()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(backdrop, at: 0)
        skeleton.axis = .vertical
        skeleton.alignment = .fill
        skeleton.spacing = TVMetrics.sectionSpacing
        skeleton.isHidden = true
        skeleton.addArrangedSubview(TVSkeletonShelfView(style: .landscape, count: 4))
        skeleton.addArrangedSubview(TVSkeletonShelfView(style: .landscape, count: 4))
        skeleton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(skeleton)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeleton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: TVMetrics.topInset + 20),
            skeleton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadWeek()
        if skipNextAppearanceLoad {
            skipNextAppearanceLoad = false
        } else {
            reload()
        }
    }

    override func initialFocusIndexPath() -> IndexPath? {
        let snapshot = dataSource.snapshot()
        for section in [TVHomeSection.continueWatching, .upNext, .recentlyAdded] {
            guard let sectionIndex = snapshot.indexOfSection(section),
                  !snapshot.itemIdentifiers(inSection: section).isEmpty else { continue }
            return IndexPath(item: 0, section: sectionIndex)
        }
        return nil
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        guard let target = cardTarget(at: indexPath) else { return false }
        actions.playPause(target.media, from: self)
        return true
    }

    /// Content that scrolls up under the tab bar fades out instead of being cut off by it.
    private func softenTopEdge() {
        guard #available(tvOS 26.0, *) else { return }
        collectionView.topEdgeEffect.isHidden = false
        collectionView.topEdgeEffect.style = .soft
    }

    private static func makeLayout(_ source: LayoutSource) -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [source] index, _ in
            guard let section = source.screen?.dataSource.snapshot().sectionIdentifiers[safe: index] else { return nil }
            switch section {
            case .hero:
                let hero = TVShelf.hero()
                hero.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.Hero.topClearance, leading: 0, bottom: 0, trailing: 0)
                return hero
            case .continueWatching, .upNext:
                return TVShelf.landscape()
            case .week:
                return Self.weekSection()
            case .recentlyAdded:
                return TVShelf.poster()
            }
        }
    }

    private static func weekSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(
            widthDimension: .absolute(TVHomeMetrics.weekTileSize.width),
            heightDimension: .absolute(TVHomeMetrics.weekTileSize.height)
        )
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
        let hero = TVHeroCell.registration { [weak self] info in
            info.configure(self?.currentHero)
        }
        let landscape = TVLandscapeCell.registration()
        let poster = TVPosterCell.registration()
        let weekTile = TVHostCell.registration { [weak self] (_: TVHomeItem) -> UIView in
            self?.makeWeekTile() ?? UIView()
        }
        let surpriseTile = TVHostCell.registration { [weak self] (_: TVHomeItem) -> UIView in
            self?.makeSurpriseTile() ?? UIView()
        }
        let header = TVSectionHeaderView.registration { [weak self] indexPath in
            self?.sectionHeader(at: indexPath)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            let cell: UICollectionViewCell
            switch item {
            case .hero:
                cell = collectionView.dequeueConfiguredReusableCell(using: hero, for: indexPath, item: 0)
            case .card(let id, let bucket):
                let data = self?.feed.item(id: id).map { TVHomeContent.card(for: $0, bucket: bucket) }
                    ?? TVCardItem(id: id, title: "")
                if bucket == .recentlyAdded {
                    cell = collectionView.dequeueConfiguredReusableCell(using: poster, for: indexPath, item: data)
                } else {
                    cell = collectionView.dequeueConfiguredReusableCell(using: landscape, for: indexPath, item: data)
                }
                cell.accessibilityIdentifier = "home.card.\(bucket.rawValue).\(id)"
            case .week:
                cell = collectionView.dequeueConfiguredReusableCell(using: weekTile, for: indexPath, item: item)
            case .surprise:
                cell = collectionView.dequeueConfiguredReusableCell(using: surpriseTile, for: indexPath, item: item)
            }
            return cell
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        adopt(dataSource)
    }

    private func makeWeekTile() -> UIView {
        let tile = TVHomeWeekSurface()
        tile.accessibilityIdentifier = "home.week"
        if let model = weekSummary?.cardModel { tile.configure(with: model) }
        tile.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            actions.openStatistics(from: self)
        }, for: .primaryActionTriggered)
        return tile
    }

    /// The Surprise Me tile at poster height, so it lines up with the posters beside it.
    private func makeSurpriseTile() -> UIView {
        let tile = TVHomeSurpriseSurface()
        tile.accessibilityIdentifier = "home.surprise"
        tile.addAction(UIAction { [weak self] _ in self?.presentSurpriseMenu() }, for: .primaryActionTriggered)
        let captionHeight = TVCardStyle.poster.itemSize.height - TVMetrics.Card.posterSize.height
        let host = UIView()
        host.addSubview(tile)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: host.topAnchor),
            tile.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            tile.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -captionHeight),
        ])
        return host
    }

    private func sectionHeader(at indexPath: IndexPath) -> TVSectionHeader? {
        guard let section = dataSource.snapshot().sectionIdentifiers[safe: indexPath.section],
              let bucket = section.bucket else { return nil }
        let title = feed.arrangement.title(for: bucket)
        guard bucket != .continueWatching else { return TVSectionHeader(title: title) }
        return TVSectionHeader(title: title, seeAllAction: { [weak self] in self?.showAll(bucket) })
    }

    private func applySnapshot(animated: Bool) {
        let arrangement = feed.arrangement
        var snapshot = NSDiffableDataSourceSnapshot<TVHomeSection, TVHomeItem>()
        if arrangement.hero != nil {
            snapshot.appendSections([.hero])
            snapshot.appendItems([.hero], toSection: .hero)
        }
        for section in [TVHomeSection.continueWatching, .upNext] {
            guard let bucket = section.bucket else { continue }
            let items = arrangement.shelf(for: bucket)
            guard !items.isEmpty else { continue }
            snapshot.appendSections([section])
            snapshot.appendItems(items.map { .card($0.id, bucket) }, toSection: section)
        }
        if arrangement.showsWeekCard(hasWeekActivity: weekSummary?.isEmpty == false) {
            snapshot.appendSections([.week])
            snapshot.appendItems([.week], toSection: .week)
        }
        if !arrangement.recent.isEmpty {
            snapshot.appendSections([.recentlyAdded])
            snapshot.appendItems(arrangement.recent.map { .card($0.id, .recentlyAdded) } + [.surprise], toSection: .recentlyAdded)
        }
        dataSource.applyReconfiguringExisting(snapshot, animated: animated)
    }

    private var firstRailSectionIndex: Int? {
        dataSource.snapshot().sectionIdentifiers.firstIndex { $0 != .hero }
    }

    private func cardTarget(at indexPath: IndexPath) -> (media: PlexMetadata, bucket: HomeBucket)? {
        guard case .card(let id, let bucket)? = dataSource.itemIdentifier(for: indexPath),
              let media = feed.item(id: id) else { return nil }
        return (media, bucket)
    }

    /// Paints the feed: the grid and hero when there is content, the empty state otherwise.
    private func render(animated: Bool) {
        guard !feed.isEmpty else {
            showEmpty()
            return
        }
        skeleton.isHidden = true
        let wasHidden = isShowingState || collectionView.isHidden
        applySnapshot(animated: animated && !wasHidden)
        if wasHidden { showContent() }
        syncHero(animated: false)
        seeAll?.update(items: feed.arrangement.shelf(for: seeAll?.bucket ?? .upNext))
    }

    private func showEmpty() {
        let copy = HomeStateCopy.empty(librariesAreFiltered: LibraryVisibility.isCustomized)
        skeleton.isHidden = true
        applySnapshot(animated: false)
        backdrop.show(path: nil)
        show(state: .empty(
            title: copy.title,
            message: copy.message,
            symbol: "play.rectangle",
            action: TVStateView.Action(title: "Refresh") { [weak self] in self?.retry() }
        ))
    }

    private func showLoadError(_ error: Error) {
        let copy = HomeStateCopy.loadFailed(error)
        skeleton.isHidden = true
        backdrop.show(path: nil)
        show(state: .error(title: copy.title, message: copy.message, retryTitle: "Retry") { [weak self] in self?.retry() })
    }

    /// The skeleton stands in for the content while a refresh from the empty or error state runs;
    /// focus waits on the host's anchor, so Menu still pops and the content takes focus back.
    private func showLoading() {
        let hadFocus = holdsFocus
        collectionView.isHidden = true
        stateView.isHidden = true
        skeleton.isHidden = false
        if hadFocus {
            view.layoutIfNeeded()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    private var holdsFocus: Bool {
        guard let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: view)
    }

    private func retry() {
        showLoading()
        reload()
    }

    /// The hero follows the focused card, or the arrangement's hero when focus is elsewhere.
    private func syncHero(animated: Bool) {
        let remembered = focusMemory.preferredIndexPath { [dataSource] identifier in
            (identifier.base as? TVHomeItem).flatMap { dataSource?.indexPath(for: $0) }
        }
        if let remembered, let target = cardTarget(at: remembered) {
            showHero(for: target.media, bucket: target.bucket, animated: animated)
        } else if let hero = feed.arrangement.hero {
            showHero(for: hero, bucket: .hero, animated: animated)
        }
    }

    private func showHero(for media: PlexMetadata, bucket: HomeBucket, animated: Bool) {
        let continuing = bucket == .continueWatching || (bucket == .hero && feed.arrangement.heroIsContinue)
        let model = feed.heroModel(for: media, bucket: bucket, continuing: continuing)
        let info = TVHomeContent.heroInfo(for: media, model: model)
        currentHero = info
        backdrop.show(path: model.backdropPath)
        guard let sectionIndex = dataSource.snapshot().indexOfSection(.hero),
              let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: sectionIndex)) as? TVHeroCell else { return }
        cell.infoView.configure(info, animated: animated)
    }

    private func reload() {
        loadSlot.run { [weak self] in
            guard let self else { return }
            do {
                try await feed.refresh()
                render(animated: true)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("Home load failed: \(error.localizedDescription)", .networking)
                if feed.isEmpty {
                    showLoadError(error)
                } else if collectionView.isHidden {
                    render(animated: false)
                }
            }
        }
    }

    private func loadWeek() {
        guard let store = StatsManager.shared.store else {
            if weekSummary != nil {
                weekSummary = nil
                if !collectionView.isHidden { applySnapshot(animated: true) }
            }
            return
        }
        weekSlot.run { [weak self] in
            var summary = await store.homeWeekSummaryOrNil()
            if let self, !hasAwaitedFirstSync {
                hasAwaitedFirstSync = true
                if summary?.isEmpty != false {
                    await StatsManager.shared.refreshNow()
                    summary = await store.homeWeekSummaryOrNil()
                }
            }
            guard !Task.isCancelled, let self, summary != weekSummary else { return }
            weekSummary = summary
            if !collectionView.isHidden { applySnapshot(animated: true) }
        }
    }

    private func libraryVisibilityChanged() {
        feed.reapplyLibraryVisibility()
        render(animated: true)
        loadWeek()
    }

    private func presentSurpriseMenu() {
        guard presentedViewController == nil else { return }
        let menu = UIAlertController(title: "Surprise Me", message: nil, preferredStyle: .alert)
        for kind in [SurpriseMe.Kind.any, .movie, .show] {
            menu.addAction(UIAlertAction(title: kind.menuTitle, style: .default) { [weak self] _ in self?.surprise(kind) })
        }
        menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(menu, animated: TVMotion.animationsEnabled)
    }

    private func surprise(_ kind: SurpriseMe.Kind) {
        surpriseSlot.run { [weak self] in
            guard let self else { return }
            let pick: SurpriseMe.Target?
            do {
                pick = try await feed.surprise(kind)
            } catch let failure as SurpriseMe.LookupFailure {
                presentAlert(title: SurpriseMe.lookupFailedTitle, message: failure.message)
                return
            } catch {
                return
            }
            guard let pick else {
                presentAlert(title: SurpriseMe.nothingToPickTitle, message: SurpriseMe.nothingToPickMessage(for: kind))
                return
            }
            actions.open(pick, from: self)
        }
    }

    private func showAll(_ bucket: HomeBucket) {
        let grid = TVHomeSeeAllViewController(
            env: env,
            bucket: bucket,
            title: feed.arrangement.title(for: bucket),
            items: feed.arrangement.shelf(for: bucket)
        ) { [weak self] in self?.reload() }
        if TVNavigation.push(grid, from: self) { seeAll = grid }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let target = cardTarget(at: indexPath) else { return }
        actions.select(target.media, in: target.bucket, from: self)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.collectionView(collectionView, didUpdateFocusIn: context, with: coordinator)
        guard let next = context.nextFocusedIndexPath else { return }
        if next.section == firstRailSectionIndex {
            homeCollectionView.bringHeroBack()
        }
        guard let target = cardTarget(at: next) else { return }
        showHero(for: target.media, bucket: target.bucket, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        if let next = context.nextFocusedIndexPath {
            homeCollectionView.holdsHeroInPlace = next.section == firstRailSectionIndex
        }
        return true
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let target = cardTarget(at: indexPath) else { return nil }
        return TVContextMenu.configuration(menu: actions.menu(for: target.media, from: self))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        backdrop.dimming = scrollView.contentOffset.y / TVHomeMetrics.backdropDimmingDistance
    }
}

/// The Home collection view. The first rail always fits below the hero at the top, but tvOS still
/// scrolls a focused row into view: a nudge that slides the hero text up under the tab bar, or,
/// when focus climbs back from a lower rail, a scroll that stops with that rail at the top of the
/// screen and the hero out of sight. While the first rail holds focus the system's scrolling is
/// therefore ignored and `bringHeroBack()` is the only thing that moves the view; focus on a
/// lower rail scrolls normally.
final class TVHomeCollectionView: TVCollectionView {
    var holdsHeroInPlace = true
    private var isPlacingHero = false

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            guard !holdsHeroInPlace || isPlacingHero else { return }
            super.contentOffset = newValue
        }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        guard !holdsHeroInPlace || isPlacingHero else { return }
        super.setContentOffset(contentOffset, animated: animated)
    }

    /// Scrolls to the top, where the hero is fully in view.
    func bringHeroBack() {
        guard contentOffset.y != 0 else { return }
        isPlacingHero = true
        defer { isPlacingHero = false }
        TVMotion.animate(TVMetrics.Duration.heroReturn, options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]) { [self] in
            contentOffset = CGPoint(x: contentOffset.x, y: 0)
        }
    }
}
