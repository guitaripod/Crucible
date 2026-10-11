import CrucibleCore
import CrucibleDesign
import CrucibleStats
import UIKit

/// The cinematic Home: a full-screen backdrop and a hero block that follow the focused card, then
/// Continue Watching, Up Next, the This Week tile and Recently Added. The hero is information only
/// (it never takes focus), so every card, including the one the hero starts on, lives in its rail.
/// Content comes from the shared `HomeFeed`; the launch payload paints the first frame and every
/// later appearance refreshes it, keeping what is on screen when a refresh fails.
final class TVHomeViewController: UIViewController, UICollectionViewDelegate {
    private enum Presentation {
        case content
        case loading
        case empty
        case error
    }

    private static let backdropDimmingDistance: CGFloat = 520
    private static let weekTileSize = CGSize(width: 960, height: 260)

    private let env: TVAppEnvironment
    private let feed: HomeFeed
    private lazy var actions = TVHomeActions(env: env) { [weak self] in
        self?.reload()
    }

    private let backdrop = TVBackdropView()
    private lazy var collectionView = TVHomeCollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private let stateView = TVStateView()
    private let skeleton = UIStackView()
    private var dataSource: UICollectionViewDiffableDataSource<TVHomeSection, TVHomeItem>!

    private let focusMemory = TVFocusMemory()
    private var presentation = Presentation.content
    private var currentHero: TVHeroInfo?
    private var weekSummary: HomeWeekSummary?
    private var loadTask: Task<Void, Never>?
    private var weekTask: Task<Void, Never>?
    private var surpriseTask: Task<Void, Never>?
    private var visibilityObserver: UUID?
    private var skipNextAppearanceLoad = true
    private var hasAwaitedFirstSync = false
    private weak var seeAll: TVHomeSeeAllViewController?

    init(env: TVAppEnvironment) {
        self.env = env
        feed = HomeFeed(api: env.api)
        super.init(nibName: nil, bundle: nil)
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
        view.backgroundColor = Theme.Color.canvas
        installViews()
        configureDataSource()
        softenTopEdge()
        collectionView.delegate = self
        collectionView.onPlayPause = { [weak self] indexPath in self?.playPause(at: indexPath) }
        visibilityObserver = LibraryVisibility.addObserver { [weak self] in
            self?.libraryVisibilityChanged()
        }
        showContent(animated: false)
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        switch presentation {
        case .content: [collectionView]
        case .empty, .error: [stateView]
        case .loading: []
        }
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        focusMemory.preferredIndexPath(in: collectionView) ?? firstCardIndexPath()
    }

    private func installViews() {
        [backdrop, collectionView, stateView, skeleton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let backdropScope = [backdrop, collectionView, stateView]
        var constraints = [NSLayoutConstraint]()
        for subview in backdropScope {
            constraints += [
                subview.topAnchor.constraint(equalTo: view.topAnchor),
                subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ]
        }
        skeleton.axis = .vertical
        skeleton.alignment = .fill
        skeleton.spacing = TVMetrics.sectionSpacing
        skeleton.isHidden = true
        skeleton.addArrangedSubview(TVSkeletonShelfView(style: .landscape, count: 4))
        skeleton.addArrangedSubview(TVSkeletonShelfView(style: .landscape, count: 4))
        constraints += [
            skeleton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: TVMetrics.topInset + 20),
            skeleton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        stateView.isHidden = true
    }

    /// Content that scrolls up under the tab bar fades out instead of being cut off by it.
    private func softenTopEdge() {
        guard #available(tvOS 26.0, *) else { return }
        collectionView.topEdgeEffect.isHidden = false
        collectionView.topEdgeEffect.style = .soft
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let section = self?.dataSource.snapshot().sectionIdentifiers[safe: index] else { return nil }
            switch section {
            case .hero:
                let hero = TVShelf.hero()
                hero.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.topInset + 40, leading: 0, bottom: 0, trailing: 0)
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
            widthDimension: .absolute(weekTileSize.width),
            heightDimension: .absolute(weekTileSize.height)
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
        let week = UICollectionView.CellRegistration<TVHomeWeekCell, TVHomeItem> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.configure(model: weekSummary?.cardModel) { [weak self] in
                guard let self else { return }
                actions.openStatistics(from: self)
            }
        }
        let surprise = UICollectionView.CellRegistration<TVHomeSurpriseCell, TVHomeItem> { [weak self] cell, _, _ in
            cell.configure { self?.presentSurpriseMenu() }
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
                cell = collectionView.dequeueConfiguredReusableCell(using: week, for: indexPath, item: item)
            case .surprise:
                cell = collectionView.dequeueConfiguredReusableCell(using: surprise, for: indexPath, item: item)
            }
            return cell
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
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
        let current = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { current.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: animated && !UIAccessibility.isReduceMotionEnabled)
    }

    private func firstCardIndexPath() -> IndexPath? {
        let snapshot = dataSource.snapshot()
        for section in [TVHomeSection.continueWatching, .upNext, .recentlyAdded] {
            guard let sectionIndex = snapshot.indexOfSection(section),
                  !snapshot.itemIdentifiers(inSection: section).isEmpty else { continue }
            return IndexPath(item: 0, section: sectionIndex)
        }
        return nil
    }

    private var firstRailSectionIndex: Int? {
        let snapshot = dataSource.snapshot()
        return snapshot.sectionIdentifiers.firstIndex { $0 != .hero }
    }

    private func cardTarget(at indexPath: IndexPath) -> (media: PlexMetadata, bucket: HomeBucket)? {
        guard case .card(let id, let bucket)? = dataSource.itemIdentifier(for: indexPath),
              let media = feed.item(id: id) else { return nil }
        return (media, bucket)
    }

    private func present(_ state: Presentation) {
        guard state != presentation else { return }
        let hadFocus = holdsFocus
        presentation = state
        collectionView.isHidden = state != .content
        stateView.isHidden = state != .empty && state != .error
        skeleton.isHidden = state != .loading
        if state != .content {
            backdrop.show(path: nil)
        }
        if hadFocus {
            setNeedsFocusUpdate()
        }
    }

    private var holdsFocus: Bool {
        guard let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView else { return false }
        return focused.isDescendant(of: view)
    }

    /// Paints the feed: the grid and hero when there is content, the empty state otherwise.
    private func showContent(animated: Bool) {
        guard !feed.isEmpty else {
            showEmpty()
            return
        }
        present(.content)
        applySnapshot(animated: animated)
        syncHero(animated: false)
        seeAll?.update(items: feed.arrangement.shelf(for: seeAll?.bucket ?? .upNext))
    }

    private func showEmpty() {
        let copy = HomeStateCopy.empty(librariesAreFiltered: LibraryVisibility.isCustomized)
        stateView.show(.empty(
            title: copy.title,
            message: copy.message,
            symbol: "play.rectangle",
            action: TVStateView.Action(title: "Refresh") { [weak self] in self?.retry() }
        ))
        applySnapshot(animated: false)
        present(.empty)
    }

    private func showLoadError(_ error: Error) {
        let copy = HomeStateCopy.loadFailed(error)
        stateView.show(.error(title: copy.title, message: copy.message, retryTitle: "Retry") { [weak self] in self?.retry() })
        present(.error)
    }

    private func retry() {
        present(.loading)
        reload()
    }

    /// The hero follows the focused card, or the arrangement's hero when focus is elsewhere.
    private func syncHero(animated: Bool) {
        if let indexPath = focusMemory.indexPath, let target = cardTarget(at: indexPath) {
            showHero(for: target.media, bucket: target.bucket, animated: animated)
        } else if let hero = feed.arrangement.hero {
            showHero(for: hero, bucket: .hero, animated: animated)
        }
    }

    private func showHero(for media: PlexMetadata, bucket: HomeBucket, animated: Bool) {
        let model = feed.heroModel(for: media, bucket: bucket)
        let info = TVHomeContent.heroInfo(for: media, model: model)
        currentHero = info
        backdrop.show(path: model.backdropPath)
        guard let sectionIndex = dataSource.snapshot().indexOfSection(.hero),
              let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: sectionIndex)) as? TVHeroCell else { return }
        cell.infoView.configure(info, animated: animated)
    }

    private func reload() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await feed.refresh()
                showContent(animated: true)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("Home load failed: \(error.localizedDescription)", .networking)
                if feed.isEmpty {
                    showLoadError(error)
                } else if presentation != .content {
                    showContent(animated: false)
                }
            }
        }
    }

    private func loadWeek() {
        guard let store = StatsManager.shared.store else {
            if weekSummary != nil {
                weekSummary = nil
                if presentation == .content { applySnapshot(animated: true) }
            }
            return
        }
        weekTask?.cancel()
        weekTask = Task { [weak self] in
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
            if presentation == .content { applySnapshot(animated: true) }
        }
    }

    private func libraryVisibilityChanged() {
        feed.reapplyLibraryVisibility()
        showContent(animated: true)
        loadWeek()
    }

    private func presentSurpriseMenu() {
        let menu = UIAlertController(title: "Surprise Me", message: nil, preferredStyle: .alert)
        for kind in [SurpriseMe.Kind.any, .movie, .show] {
            menu.addAction(UIAlertAction(title: kind.menuTitle, style: .default) { [weak self] _ in self?.surprise(kind) })
        }
        menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(menu, animated: true)
    }

    private func surprise(_ kind: SurpriseMe.Kind) {
        guard surpriseTask == nil else { return }
        surpriseTask = Task { [weak self] in
            guard let self else { return }
            defer { surpriseTask = nil }
            let pick: SurpriseMe.Target?
            do {
                pick = try await feed.surprise(kind)
            } catch {
                return
            }
            guard let pick else {
                presentNothingToPick(kind)
                return
            }
            actions.open(pick, from: self)
        }
    }

    private func presentNothingToPick(_ kind: SurpriseMe.Kind) {
        let alert = UIAlertController(
            title: SurpriseMe.nothingToPickTitle,
            message: SurpriseMe.nothingToPickMessage(for: kind),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    private func showAll(_ bucket: HomeBucket) {
        let grid = TVHomeSeeAllViewController(
            env: env,
            bucket: bucket,
            title: feed.arrangement.title(for: bucket),
            items: feed.arrangement.shelf(for: bucket)
        ) { [weak self] in self?.reload() }
        seeAll = grid
        navigationController?.pushViewController(grid, animated: true)
    }

    private func playPause(at indexPath: IndexPath) {
        guard let target = cardTarget(at: indexPath) else { return }
        actions.playPause(target.media, from: self)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let target = cardTarget(at: indexPath) else { return }
        actions.select(target.media, in: target.bucket, from: self)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        focusMemory.record(context)
        guard let next = context.nextFocusedIndexPath, let target = cardTarget(at: next) else { return }
        showHero(for: target.media, bucket: target.bucket, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView, shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
        if let next = context.nextFocusedIndexPath {
            self.collectionView.holdsHeroInPlace = next.section == firstRailSectionIndex
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
        backdrop.dimming = scrollView.contentOffset.y / Self.backdropDimmingDistance
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The Home collection view. tvOS nudges a focused row into view even when it already fits, which
/// would slide the hero text up under the tab bar; while the first rail holds focus the view
/// therefore stays at its resting offset, and scrolls normally once focus moves to a lower rail.
final class TVHomeCollectionView: TVCollectionView {
    private static let restingBand: CGFloat = 120

    var holdsHeroInPlace = true

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            var offset = newValue
            if holdsHeroInPlace, super.contentOffset.y < Self.restingBand, offset.y > 0, offset.y < Self.restingBand {
                offset.y = 0
            }
            super.contentOffset = offset
        }
    }
}
