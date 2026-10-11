import CrucibleCore
import CrucibleDesign
import UIKit

final class ActivityHistoryViewController: UICollectionViewController {
    private enum Section: Hashable {
        case controls
        case day(Date)
    }

    private enum Entry: Hashable {
        case controls
        case item(HistoryItem)
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Entry>!
    private let feed: HistoryFeed
    private var playTask: Task<Void, Never>?
    private var playerCoordinator: PlayerCoordinator?
    private var filter: HistoryFilter = .all
    private var busyIDs: Set<String> = []

    init(api: APIClient) {
        self.api = api
        self.feed = HistoryFeed(api: api)
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        playTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Watch History"
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.collectionViewLayout = makeLayout()

        configureDataSource()

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.feed.refresh() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        collectionView.prefetchDataSource = self
        feed.onEvent = { [weak self] event in self?.handle(event) }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        feed.loadFirstPageIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            feed.cancel()
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { sectionIndex, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .plain)
            config.backgroundColor = Theme.Color.canvas
            let isControls = sectionIndex == 0
            config.headerMode = isControls ? .none : .supplementary
            config.showsSeparators = !isControls
            config.separatorConfiguration.color = Theme.Color.separator
            config.itemSeparatorHandler = { _, sectionConfiguration in
                var separator = sectionConfiguration
                separator.topSeparatorVisibility = .hidden
                separator.bottomSeparatorInsets = NSDirectionalEdgeInsets(top: 0, leading: 74, bottom: 0, trailing: 0)
                return separator
            }
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let controlsCell = UICollectionView.CellRegistration<UICollectionViewListCell, Entry> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = controlsConfiguration()
            cell.backgroundConfiguration = .clear()
        }

        let itemCell = UICollectionView.CellRegistration<UICollectionViewListCell, HistoryItem> { [weak self] cell, _, entry in
            guard let self else { return }
            cell.contentConfiguration = rowConfiguration(for: entry)
            cell.configurationUpdateHandler = { cell, state in
                var background = UIBackgroundConfiguration.clear()
                if state.isHighlighted || state.isSelected {
                    background.backgroundColor = Theme.Color.surfaceRaised
                }
                cell.backgroundConfiguration = background
            }
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, entry in
            switch entry {
            case .controls:
                return collectionView.dequeueConfiguredReusableCell(using: controlsCell, for: indexPath, item: entry)
            case .item(let item):
                return collectionView.dequeueConfiguredReusableCell(using: itemCell, for: indexPath, item: item)
            }
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.dayTitle(forSection: indexPath.section)
            content.textProperties.font = Theme.Font.footnoteSemibold
            content.textProperties.color = Theme.Color.labelSecondary
            content.textProperties.transform = .uppercase
            header.contentConfiguration = content
            var background = UIBackgroundConfiguration.clear()
            background.backgroundColor = Theme.Color.canvas
            header.backgroundConfiguration = background
            header.accessibilityTraits = .header
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func controlsConfiguration() -> HistoryControlsConfiguration {
        let chips = HistoryFilter.allCases.map { FilterChipsView.Chip(id: $0.rawValue, title: $0.title, isSelected: $0 == filter) }
        return HistoryControlsConfiguration(chips: chips, summary: HistorySummary.text(for: visibleItems, now: Date())) { [weak self] id in
            guard let self, let selected = HistoryFilter(rawValue: id), selected != filter else { return }
            filter = selected
            applySnapshot()
        }
    }

    private func rowConfiguration(for entry: HistoryItem) -> HistoryRowConfiguration {
        let row = entry.row
        return HistoryRowConfiguration(
            posterPath: row.posterPath,
            title: row.title,
            subtitle: row.subtitle,
            meta: row.timeText,
            isPlayEnabled: !busyIDs.contains(entry.uniqueId),
            onPlay: { [weak self] in self?.playAgain(entry) }
        )
    }

    private var visibleItems: [HistoryItem] {
        feed.items(matching: filter)
    }

    private func applySnapshot() {
        let visible = visibleItems
        var snapshot = NSDiffableDataSourceSnapshot<Section, Entry>()
        snapshot.appendSections([.controls])
        snapshot.appendItems([.controls], toSection: .controls)

        let calendar = Calendar.current
        for group in HistoryDay.groups(of: visible, calendar: calendar) {
            snapshot.appendSections([.day(group.day)])
            snapshot.appendItems(group.items.map { .item($0) }, toSection: .day(group.day))
        }
        let existing = dataSource.snapshot()
        if existing.indexOfItem(.controls) != nil {
            snapshot.reconfigureItems([.controls])
        }

        let animated = !UIAccessibility.isReduceMotionEnabled && !feed.items.isEmpty && existing.numberOfItems > 1
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            self?.updateContentUnavailable()
        }
        feed.loadMoreIfNeeded(visibleCount: visible.count)
    }

    private func reconfigure(_ item: HistoryItem) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(.item(item)) != nil else { return }
        snapshot.reconfigureItems([.item(item)])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func handle(_ event: HistoryFeed.Event) {
        finishRefreshing()
        switch event {
        case .pageLoaded: applySnapshot()
        case .failed: updateContentUnavailable()
        }
    }

    private func updateContentUnavailable() {
        let state = feed.emptyState(filter: filter)
        if state == .loading { return }
        guard let content = state.content else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: content.symbolName)
        config.imageProperties.tintColor = Theme.Color.labelTertiary
        config.text = content.title
        config.textProperties.font = Theme.Font.title3
        config.textProperties.color = Theme.Color.label
        if let message = content.message {
            config.secondaryText = message
            config.secondaryTextProperties.font = Theme.Font.subheadline
            config.secondaryTextProperties.color = Theme.Color.labelSecondary
        }
        if state == .loadFailed {
            config.button = ThemeButton.primaryConfiguration(title: "Try Again")
            config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                self?.contentUnavailableConfiguration = nil
                self?.feed.retry()
            }
        }
        contentUnavailableConfiguration = config
    }

    private func finishRefreshing() {
        guard collectionView.refreshControl?.isRefreshing == true else { return }
        collectionView.refreshControl?.endRefreshing()
        Haptics.soft()
    }

    private func playAgain(_ entry: HistoryItem) {
        guard !busyIDs.contains(entry.uniqueId) else { return }
        Haptics.light()
        busyIDs.insert(entry.uniqueId)
        reconfigure(entry)
        playTask = Task { [weak self] in
            guard let self else { return }
            defer {
                busyIDs.remove(entry.uniqueId)
                reconfigure(entry)
            }
            do {
                let found = try await feed.metadata(for: entry)
                guard !Task.isCancelled else { return }
                guard let metadata = found else {
                    presentPlaybackError()
                    return
                }
                playerCoordinator = Theme.quickPlay(api: api, item: metadata, from: self)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("History play again failed for \(entry.ratingKey): \(error.localizedDescription)", .playback)
                presentPlaybackError()
            }
        }
    }

    private func presentPlaybackError() {
        Haptics.error()
        let alert = UIAlertController(title: "Couldn't Start Playback", message: "The server didn't return this title. Try again in a moment.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .item(let entry) = dataSource.itemIdentifier(for: indexPath) else { return }

        switch entry.destination {
        case .episode(let ratingKey, let showRatingKey, let seasonRatingKey):
            let vc = MediaDetailViewController(
                api: api,
                ratingKey: ratingKey,
                mediaType: "episode",
                showRatingKey: showRatingKey,
                seasonRatingKey: seasonRatingKey
            )
            navigationController?.pushViewController(vc, animated: true)
        case .show(let ratingKey):
            let vc = ShowDetailViewController(api: api, showRatingKey: ratingKey)
            navigationController?.pushViewController(vc, animated: true)
        case .movie(let ratingKey):
            let vc = MediaDetailViewController(api: api, ratingKey: ratingKey, mediaType: "movie")
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .item = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }
}

extension ActivityHistoryViewController {
    fileprivate func dayTitle(forSection section: Int) -> String? {
        let identifiers = dataSource.snapshot().sectionIdentifiers
        guard identifiers.indices.contains(section), case .day(let date) = identifiers[section] else { return nil }
        return HistoryDay.title(for: date, now: Date(), calendar: .current)
    }
}

extension ActivityHistoryViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let snapshot = dataSource.snapshot()
        let lastSection = snapshot.numberOfSections - 1
        guard lastSection > 0 else { return }
        let lastCount = snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[lastSection])
        let reachingEnd = indexPaths.contains { $0.section == lastSection && HistoryPager.isWithinPrefetchWindow(position: $0.item, count: lastCount) }
        if reachingEnd {
            feed.prefetchMore()
        }
    }
}
