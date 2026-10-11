import CrucibleCore
import CrucibleDesign
import UIKit

/// Watch History on Apple TV: the plays newest first, grouped by day, with All/Movies/TV chips, a
/// Refresh button (tvOS has no pull-to-refresh), the weekly summary and a play-again button on every
/// row. Select opens the detail screen, Play/Pause or the row's button plays again. All paging and
/// presentation rules live in `HistoryFeed` and friends in CrucibleCore, shared with the iPhone.
final class HistoryViewController: UIViewController {
    fileprivate enum Section: Hashable {
        case title
        case filters
        case day(Date)
    }

    fileprivate enum Entry: Hashable {
        case title(HistoryTitle)
        case filter(HistoryFilter)
        case refresh
        case row(HistoryItem)
    }

    private static let refreshChipID = "refresh"
    private static let retryingAlpha: CGFloat = 0.5

    private let env: TVAppEnvironment
    private let feed: HistoryFeed
    private let stateView = TVStateView()
    private lazy var collectionView = TVCollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Section, Entry>!
    private var filter: HistoryFilter = .all
    private var busyIDs: Set<String> = []
    private var playTask: Task<Void, Never>?
    private var hasRequestedFirstPage = false
    private var isRefreshing = false
    private var wantsInitialFocus = true
    private var isRetryingFromState = false
    private var stateOffersAction = false
    private var lastFocusedRow: HistoryItem?
    private var positions: [String: Int] = [:]

    init(environment: TVAppEnvironment) {
        env = environment
        feed = HistoryFeed(api: environment.api)
        super.init(nibName: nil, bundle: nil)
        title = "Watch History"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        playTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas

        collectionView.delegate = self
        collectionView.onPlayPause = { [weak self] indexPath in
            guard let self, case .row(let item)? = dataSource.itemIdentifier(for: indexPath) else { return }
            playAgain(item)
        }
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        setContentScrollView(collectionView, for: .top)

        stateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stateView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        configureDataSource()
        feed.onEvent = { [weak self] event in self?.handle(event) }
        render()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        hasRequestedFirstPage = true
        feed.loadFirstPageIfNeeded()
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            feed.cancel()
            playTask?.cancel()
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        stateView.isHidden ? [collectionView] : [stateView]
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            let identifiers = self?.dataSource.snapshot().sectionIdentifiers ?? []
            guard identifiers.indices.contains(index) else { return Self.titleSection() }
            switch identifiers[index] {
            case .title: return Self.titleSection()
            case .filters: return TVShelf.chips()
            case .day: return Self.daySection()
            }
        }
    }

    private static func titleSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(TVMetrics.shelfHeaderHeight))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: HistoryMetrics.titleTopInset, leading: 0, bottom: 0, trailing: 0)
        return section
    }

    private static func daySection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(HistoryMetrics.rowHeight)
        ))
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(HistoryMetrics.rowHeight)),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = TVMetrics.Row.spacing
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: HistoryMetrics.daySectionBottomInset, trailing: 0)
        section.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(HistoryMetrics.dayHeaderHeight)),
                elementKind: TVShelf.headerKind,
                alignment: .top
            )
        ]
        return section
    }

    private func configureDataSource() {
        let titleCell = HistoryTitleCell.registration()
        let chipCell = TVChipCell.registration { [weak self] chip in self?.chipPressed(chip) }
        let rowCell = HistoryRowCell.registration(
            isBusy: { [weak self] item in self?.busyIDs.contains(item.uniqueId) ?? false },
            onSelect: { [weak self] item in self?.open(item) },
            onPlay: { [weak self] item in self?.playAgain(item) }
        )

        dataSource = UICollectionViewDiffableDataSource<Section, Entry>(collectionView: collectionView) { [weak self] collectionView, indexPath, entry in
            guard let self else { return nil }
            switch entry {
            case .title(let title):
                return collectionView.dequeueConfiguredReusableCell(using: titleCell, for: indexPath, item: title)
            case .filter(let filter):
                return collectionView.dequeueConfiguredReusableCell(using: chipCell, for: indexPath, item: chipItem(for: filter))
            case .refresh:
                return collectionView.dequeueConfiguredReusableCell(using: chipCell, for: indexPath, item: refreshChipItem)
            case .row(let item):
                return collectionView.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: item)
            }
        }

        let header = TVSectionHeaderView.registration { [weak self] indexPath in
            self?.dayHeader(forSection: indexPath.section)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func chipItem(for filter: HistoryFilter) -> TVChipItem {
        TVChipItem(id: filter.rawValue, title: filter.title, isSelected: filter == self.filter)
    }

    private var refreshChipItem: TVChipItem {
        TVChipItem(id: Self.refreshChipID, title: isRefreshing ? "Refreshing" : "Refresh", symbol: "arrow.clockwise")
    }

    private func dayHeader(forSection section: Int) -> TVSectionHeader? {
        let identifiers = dataSource.snapshot().sectionIdentifiers
        guard identifiers.indices.contains(section), case .day(let day) = identifiers[section] else { return nil }
        return TVSectionHeader(title: HistoryDay.title(for: day, now: Date(), calendar: .current))
    }

    private var currentState: HistoryEmptyState {
        hasRequestedFirstPage ? feed.emptyState(filter: filter) : .loading
    }

    private func render() {
        let visible = feed.items(matching: filter)
        let state = currentState
        positions = Dictionary(visible.enumerated().map { ($1.uniqueId, $0) }, uniquingKeysWith: { first, _ in first })

        var snapshot = NSDiffableDataSourceSnapshot<Section, Entry>()
        snapshot.appendSections([.title])
        let summary = state == .populated ? HistorySummary.text(for: visible, now: Date()) : nil
        snapshot.appendItems([.title(HistoryTitle(summary: summary))], toSection: .title)
        if !feed.items.isEmpty {
            snapshot.appendSections([.filters])
            snapshot.appendItems(HistoryFilter.allCases.map { .filter($0) } + [.refresh], toSection: .filters)
            for group in HistoryDay.groups(of: visible, calendar: .current) {
                snapshot.appendSections([.day(group.day)])
                snapshot.appendItems(group.items.map { .row($0) }, toSection: .day(group.day))
            }
        }
        let existing = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { existing.indexOfItem($0) != nil && $0.isControl })

        let animated = !UIAccessibility.isReduceMotionEnabled && existing.numberOfItems > 1 && snapshot.numberOfItems > 1
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            self?.claimFocusIfNeeded()
        }
        showState(state)
        DispatchQueue.main.async { [weak self] in self?.claimFocusIfNeeded() }
        feed.loadMoreIfNeeded(visibleCount: visible.count)
    }

    /// While a retry runs the state that holds the pressed button stays on screen, dimmed: replacing it
    /// with the spinner would drop the focus onto the tab bar, which tvOS does not hand back.
    private func showState(_ state: HistoryEmptyState) {
        if state == .loading, stateOffersAction, isRetryingFromState {
            stateView.alpha = Self.retryingAlpha
            return
        }
        stateView.alpha = 1
        stateOffersAction = action(for: state) != nil
        switch state {
        case .populated:
            stateView.isHidden = true
        case .loading:
            stateView.isHidden = false
            stateView.show(.loading(title: "Loading History"))
        case .noActivity, .loadFailed, .noMatches:
            guard let content = state.content else { return }
            stateView.isHidden = false
            stateView.show(.empty(title: content.title, message: content.message, symbol: content.symbolName, action: action(for: state)))
        }
    }

    private func action(for state: HistoryEmptyState) -> TVStateView.Action? {
        switch state {
        case .noActivity:
            return TVStateView.Action(title: "Refresh") { [weak self] in self?.refresh() }
        case .loadFailed:
            return TVStateView.Action(title: "Try Again") { [weak self] in self?.retry() }
        case .populated, .loading, .noMatches:
            return nil
        }
    }

    private func handle(_ event: HistoryFeed.Event) {
        let wasRefreshing = isRefreshing
        isRefreshing = false
        isRetryingFromState = false
        render()
        if event == .failed, wasRefreshing, !feed.items.isEmpty {
            presentRefreshError()
        }
    }

    private func chipPressed(_ chip: TVChipItem) {
        if chip.id == Self.refreshChipID {
            refresh()
        } else if let selected = HistoryFilter(rawValue: chip.id), selected != filter {
            filter = selected
            render()
        }
    }

    private func refresh() {
        guard !feed.pager.isLoading else { return }
        isRetryingFromState = feed.items.isEmpty
        isRefreshing = !feed.items.isEmpty
        feed.refresh()
        render()
    }

    private func retry() {
        isRetryingFromState = true
        feed.retry()
        render()
    }

    /// Moves focus into the screen once there is something to focus: the first row after the first
    /// page, or the state view's button. Focus that sits elsewhere (the tab bar) is left alone.
    private func claimFocusIfNeeded() {
        guard view.window != nil else { return }
        view.layoutIfNeeded()
        let focused = UIFocusSystem.focusSystem(for: self)?.focusedItem as? UIView
        if let focused, !focused.isDescendant(of: view) { return }
        let hasRows = !feed.items(matching: filter).isEmpty
        let focusIsInStateView = focused?.isDescendant(of: stateView) ?? false
        guard focused == nil || focusIsInStateView || (wantsInitialFocus && hasRows) else { return }
        guard hasRows || stateOffersAction else { return }
        if hasRows { wantsInitialFocus = false }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func open(_ item: HistoryItem) {
        guard navigationController?.topViewController === self else { return }
        let controller: UIViewController
        switch item.destination {
        case .episode(let ratingKey, _, _):
            controller = TVScreens.detail(env, ratingKey: ratingKey, mediaType: "episode")
        case .show(let ratingKey):
            controller = TVScreens.detail(env, ratingKey: ratingKey, mediaType: "show")
        case .movie(let ratingKey):
            controller = TVScreens.detail(env, ratingKey: ratingKey, mediaType: "movie")
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func playAgain(_ item: HistoryItem) {
        guard !busyIDs.contains(item.uniqueId) else { return }
        busyIDs.insert(item.uniqueId)
        reconfigure(item)
        playTask = Task { [weak self] in
            guard let self else { return }
            defer {
                busyIDs.remove(item.uniqueId)
                reconfigure(item)
            }
            do {
                let found = try await feed.metadata(for: item)
                guard !Task.isCancelled else { return }
                guard let metadata = found else {
                    presentPlaybackError()
                    return
                }
                TVScreens.play(env, request: TVPlaybackRequest(item: metadata), from: self)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("History play again failed for \(item.ratingKey): \(error.localizedDescription)", .playback)
                presentPlaybackError()
            }
        }
    }

    private func reconfigure(_ item: HistoryItem) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(.row(item)) != nil else { return }
        snapshot.reconfigureItems([.row(item)])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func presentPlaybackError() {
        let alert = UIAlertController(
            title: "Couldn't Start Playback",
            message: "The server didn't return this title. Try again in a moment.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    private func presentRefreshError() {
        let alert = UIAlertController(
            title: "Couldn't Refresh History",
            message: "Check your connection and try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Try Again", style: .default) { [weak self] _ in self?.refresh() })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}

extension HistoryViewController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        guard let view = context.nextFocusedView,
              let indexPath = Self.indexPath(containing: view, in: collectionView),
              case .row(let item)? = dataSource.itemIdentifier(for: indexPath)
        else { return }
        lastFocusedRow = item
        if let position = positions[item.uniqueId], HistoryPager.isWithinPrefetchWindow(position: position, count: positions.count) {
            feed.prefetchMore()
        }
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        if let lastFocusedRow, let indexPath = dataSource.indexPath(for: .row(lastFocusedRow)) {
            return indexPath
        }
        return dataSource.snapshot().itemIdentifiers.first { $0.isRow }.flatMap { dataSource.indexPath(for: $0) }
    }

    private static func indexPath(containing view: UIView, in collectionView: UICollectionView) -> IndexPath? {
        var candidate: UIView? = view
        while let current = candidate {
            if let cell = current as? UICollectionViewCell { return collectionView.indexPath(for: cell) }
            candidate = current.superview
        }
        return nil
    }
}

private extension HistoryViewController.Entry {
    var isControl: Bool {
        switch self {
        case .filter, .refresh: return true
        case .title, .row: return false
        }
    }

    var isRow: Bool {
        if case .row = self { return true }
        return false
    }
}
