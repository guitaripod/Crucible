import CrucibleCore
import CrucibleDesign
import UIKit

/// Watch History on Apple TV: the plays newest first, grouped by day, with All/Movies/TV chips, a
/// Refresh button (tvOS has no pull-to-refresh), the weekly summary and a play-again button on every
/// row. Select opens the detail screen, Play/Pause or the row's button plays again. All paging and
/// presentation rules live in `HistoryFeed` and friends in CrucibleCore, shared with the iPhone.
///
/// Coming back from a detail or the player reloads the list in place, so a new play shows up without
/// pressing Refresh.
final class HistoryViewController: TVScreenViewController {
    fileprivate enum Section: Hashable {
        case title
        case filters
        case day(Date)
        case noMatches
    }

    fileprivate enum Entry: Hashable {
        case title(TVScreenTitleContent)
        case filter(HistoryFilter)
        case refresh
        case row(HistoryItem)
        case noMatches(HistoryFilter)
    }

    private static let refreshChipID = "refresh"
    private static let titleIdentifier = "history.title"

    private let env: TVAppEnvironment
    private let feed: HistoryFeed
    private var dataSource: UICollectionViewDiffableDataSource<Section, Entry>!
    private lazy var playSlot = makeTaskSlot()
    private var filter: HistoryFilter = .all
    private var busyIDs: Set<String> = []
    private var hasRequestedFirstPage = false
    private var hasAppeared = false
    private var isRefreshing = false
    private var positions: [String: Int] = [:]

    init(environment: TVAppEnvironment) {
        env = environment
        feed = HistoryFeed(api: environment.api)
        super.init(layout: UICollectionViewLayout())
        title = "Watch History"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDataSource()
        collectionView.collectionViewLayout = makeLayout()
        setContentScrollView(collectionView, for: .top)
        feed.onEvent = { [weak self] event in self?.handle(event) }
        render()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        hasRequestedFirstPage = true
        if hasAppeared, !feed.items.isEmpty, !feed.pager.isLoading {
            feed.refresh()
        } else {
            feed.loadFirstPageIfNeeded()
        }
        hasAppeared = true
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            feed.cancel()
        }
    }

    override func initialFocusIndexPath() -> IndexPath? {
        dataSource.snapshot().itemIdentifiers.first { $0.isRow }.flatMap { dataSource.indexPath(for: $0) }
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        guard case .row(let item)? = dataSource.itemIdentifier(for: indexPath) else { return false }
        playAgain(item)
        return true
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.collectionView(collectionView, didUpdateFocusIn: context, with: coordinator)
        guard let indexPath = context.nextFocusedIndexPath,
              case .row(let item)? = dataSource.itemIdentifier(for: indexPath),
              let position = positions[item.uniqueId],
              HistoryPager.isWithinPrefetchWindow(position: position, count: positions.count)
        else { return }
        feed.prefetchMore()
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            let identifiers = self?.dataSource.snapshot().sectionIdentifiers ?? []
            guard identifiers.indices.contains(index) else { return TVScreenTitleView.section() }
            switch identifiers[index] {
            case .title: return TVScreenTitleView.section()
            case .filters: return TVShelf.chips()
            case .day: return Self.daySection()
            case .noMatches: return Self.noMatchesSection()
            }
        }
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

    private static func noMatchesSection() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(HistoryMetrics.noMatchesHeight))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        return NSCollectionLayoutSection(group: group)
    }

    private func configureDataSource() {
        let titleCell = TVScreenTitleView.registration()
        let chipCell = TVChipCell.registration { [weak self] chip in self?.chipPressed(chip) }
        let rowCell = TVHostCell.registration { [weak self] (item: HistoryItem) -> UIView in
            let view = HistoryRowView()
            view.configure(
                with: item,
                isBusy: self?.busyIDs.contains(item.uniqueId) ?? false,
                onSelect: { [weak self] in self?.open(item) },
                onPlay: { [weak self] in self?.playAgain(item) }
            )
            return view
        }
        let noMatchesCell = TVHostCell.registration { (filter: HistoryFilter) -> UIView in
            let view = TVStateView()
            if let content = HistoryEmptyState.noMatches(filter).content {
                view.show(.empty(title: content.title, message: content.message, symbol: content.symbolName, action: nil))
            }
            return view
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Entry>(collectionView: collectionView) { [weak self] collectionView, indexPath, entry in
            guard let self else { return nil }
            switch entry {
            case .title(let content):
                let cell = collectionView.dequeueConfiguredReusableCell(using: titleCell, for: indexPath, item: content)
                cell.hosted?.accessibilityIdentifier = Self.titleIdentifier
                return cell
            case .filter(let filter):
                return collectionView.dequeueConfiguredReusableCell(using: chipCell, for: indexPath, item: chipItem(for: filter))
            case .refresh:
                return collectionView.dequeueConfiguredReusableCell(using: chipCell, for: indexPath, item: refreshChipItem)
            case .row(let item):
                return collectionView.dequeueConfiguredReusableCell(using: rowCell, for: indexPath, item: item)
            case .noMatches(let filter):
                return collectionView.dequeueConfiguredReusableCell(using: noMatchesCell, for: indexPath, item: filter)
            }
        }
        adopt(dataSource)

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
        guard let identifier = identifiers[safe: section], case .day(let day) = identifier else { return nil }
        return TVSectionHeader(title: HistoryDay.title(for: day, now: Date(), calendar: .current))
    }

    private var currentState: HistoryEmptyState {
        hasRequestedFirstPage ? feed.emptyState(filter: filter) : .loading
    }

    private func render() {
        let state = currentState
        switch state {
        case .loading:
            show(state: .loading(title: "Loading History"))
            return
        case .noActivity:
            showMessage(for: state, actionTitle: "Refresh") { [weak self] in self?.refresh() }
            return
        case .loadFailed:
            showMessage(for: state, actionTitle: "Try Again") { [weak self] in self?.retry() }
            return
        case .populated, .noMatches:
            break
        }

        let visible = feed.items(matching: filter)
        positions = Dictionary(visible.enumerated().map { ($1.uniqueId, $0) }, uniquingKeysWith: { first, _ in first })
        let summary = state == .populated ? HistorySummary.text(for: visible, now: Date()) : nil

        var snapshot = NSDiffableDataSourceSnapshot<Section, Entry>()
        snapshot.appendSections([.title, .filters])
        snapshot.appendItems([.title(TVScreenTitleContent(title: "Watch History", summary: summary))], toSection: .title)
        snapshot.appendItems(HistoryFilter.allCases.map { .filter($0) } + [.refresh], toSection: .filters)
        if state == .populated {
            for group in HistoryDay.groups(of: visible, calendar: .current) {
                snapshot.appendSections([.day(group.day)])
                snapshot.appendItems(group.items.map { .row($0) }, toSection: .day(group.day))
            }
        } else {
            snapshot.appendSections([.noMatches])
            snapshot.appendItems([.noMatches(filter)], toSection: .noMatches)
        }
        dataSource.applyReconfiguringExisting(snapshot)
        showContent()
        feed.loadMoreIfNeeded(visibleCount: visible.count)
    }

    private func showMessage(for state: HistoryEmptyState, actionTitle: String, action: @escaping @MainActor () -> Void) {
        guard let content = state.content else { return }
        show(state: .empty(
            title: content.title,
            message: content.message,
            symbol: content.symbolName,
            action: TVStateView.Action(title: actionTitle, handler: action)
        ))
    }

    private func handle(_ event: HistoryFeed.Event) {
        let wasRefreshing = isRefreshing
        isRefreshing = false
        render()
        if event == .failed, wasRefreshing, !feed.items.isEmpty {
            presentAlert(title: "Couldn't Refresh History", message: "Check your connection and try again.")
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
        isRefreshing = !feed.items.isEmpty
        feed.refresh()
        render()
    }

    private func retry() {
        feed.retry()
        render()
    }

    private func open(_ item: HistoryItem) {
        let controller: UIViewController
        switch item.destination {
        case .episode(let ratingKey, _, _):
            controller = TVScreens.detail(env, ratingKey: ratingKey, mediaType: "episode")
        case .show(let ratingKey):
            controller = TVScreens.detail(env, ratingKey: ratingKey, mediaType: "show")
        case .movie(let ratingKey):
            controller = TVScreens.detail(env, ratingKey: ratingKey, mediaType: "movie")
        }
        TVNavigation.push(controller, from: self)
    }

    private func playAgain(_ item: HistoryItem) {
        guard !busyIDs.contains(item.uniqueId) else { return }
        busyIDs.insert(item.uniqueId)
        reconfigure(item)
        playSlot.run { [weak self] in
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
        presentAlert(title: "Couldn't Start Playback", message: "The server didn't return this title. Try again in a moment.")
    }
}

private extension HistoryViewController.Entry {
    var isRow: Bool {
        if case .row = self { return true }
        return false
    }
}
