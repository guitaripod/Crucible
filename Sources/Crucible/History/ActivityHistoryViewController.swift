import UIKit

struct HistoryItem: Hashable, Sendable {
    let ratingKey: String
    let title: String
    let type: String?
    let viewedAt: Int?
    let thumb: String?
    let grandparentThumb: String?
    let grandparentTitle: String?
    let grandparentRatingKey: String?
    let parentRatingKey: String?
    let parentIndex: Int?
    let index: Int?
    let duration: Int?
    let uniqueId: String
}

final class ActivityHistoryViewController: UICollectionViewController {
    private enum Filter: String, CaseIterable {
        case all, movies, tv

        var title: String {
            switch self {
            case .all: return "All"
            case .movies: return "Movies"
            case .tv: return "TV"
            }
        }

        func includes(_ item: HistoryItem) -> Bool {
            switch self {
            case .all: return true
            case .movies: return item.type == "movie"
            case .tv: return item.type == "episode" || item.type == "show" || item.type == "season"
            }
        }
    }

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
    private var loadTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var playerCoordinator: PlayerCoordinator?
    private var allItems: [HistoryItem] = []
    private var filter: Filter = .all
    private var busyIDs: Set<String> = []
    private var currentOffset = 0
    private var totalSize = 0
    private var isLoadingMore = false
    private var loadFailed = false
    private let pageSize = 50

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
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
        refresh.addAction(UIAction { [weak self] _ in self?.resetAndLoad() }, for: .valueChanged)
        collectionView.refreshControl = refresh
        collectionView.prefetchDataSource = self
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if allItems.isEmpty && loadTask == nil {
            loadPage(offset: 0)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            loadTask?.cancel()
            loadTask = nil
            isLoadingMore = false
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
        let chips = Filter.allCases.map { FilterChipsView.Chip(id: $0.rawValue, title: $0.title, isSelected: $0 == filter) }
        return HistoryControlsConfiguration(chips: chips, summary: summaryText(for: visibleItems)) { [weak self] id in
            guard let self, let selected = Filter(rawValue: id), selected != filter else { return }
            filter = selected
            applySnapshot()
        }
    }

    private func rowConfiguration(for entry: HistoryItem) -> HistoryRowConfiguration {
        let isEpisode = entry.type == "episode"
        var subtitleParts = [String]()
        if isEpisode {
            if let season = entry.parentIndex { subtitleParts.append("S\(season)") }
            if let index = entry.index { subtitleParts.append("E\(index)") }
            subtitleParts.append(entry.title)
        } else {
            subtitleParts.append(entry.type == "show" ? "Show" : "Movie")
        }
        return HistoryRowConfiguration(
            posterPath: isEpisode ? (entry.grandparentThumb ?? entry.thumb) : entry.thumb,
            title: isEpisode ? (entry.grandparentTitle ?? entry.title) : entry.title,
            subtitle: subtitleParts.joined(separator: " · "),
            meta: Self.timeText(entry.viewedAt),
            isPlayEnabled: !busyIDs.contains(entry.uniqueId),
            onPlay: { [weak self] in self?.playAgain(entry) }
        )
    }

    private var visibleItems: [HistoryItem] {
        allItems.filter { filter.includes($0) }
    }

    private func applySnapshot() {
        let visible = visibleItems
        var snapshot = NSDiffableDataSourceSnapshot<Section, Entry>()
        snapshot.appendSections([.controls])
        snapshot.appendItems([.controls], toSection: .controls)

        let calendar = Calendar.current
        var order = [Date]()
        var groups = [Date: [HistoryItem]]()
        for item in visible {
            let day = Self.day(for: item.viewedAt, calendar: calendar)
            if groups[day] == nil { order.append(day) }
            groups[day, default: []].append(item)
        }
        for day in order {
            snapshot.appendSections([.day(day)])
            snapshot.appendItems((groups[day] ?? []).map { .item($0) }, toSection: .day(day))
        }
        let existing = dataSource.snapshot()
        if existing.indexOfItem(.controls) != nil {
            snapshot.reconfigureItems([.controls])
        }

        let animated = !UIAccessibility.isReduceMotionEnabled && !allItems.isEmpty && existing.numberOfItems > 1
        dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
            self?.updateContentUnavailable()
        }
        loadMoreIfNeeded(visibleCount: visible.count)
    }

    private func reconfigure(_ item: HistoryItem) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(.item(item)) != nil else { return }
        snapshot.reconfigureItems([.item(item)])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Keeps fetching while the visible list is too short to scroll or the weekly summary could still
    /// be missing plays from older pages.
    private func loadMoreIfNeeded(visibleCount: Int) {
        guard currentOffset < totalSize, !isLoadingMore, loadTask == nil, !loadFailed else { return }
        let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970
        let oldest = allItems.last?.viewedAt.map(Double.init) ?? 0
        if visibleCount < 12 || oldest >= weekAgo {
            isLoadingMore = true
            loadPage(offset: currentOffset)
        }
    }

    private func updateContentUnavailable() {
        if allItems.isEmpty {
            guard loadTask == nil else { return }
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: loadFailed ? "wifi.exclamationmark" : "clock")
            config.imageProperties.tintColor = Theme.Color.labelTertiary
            config.text = loadFailed ? "Couldn't load history" : "No activity yet"
            config.textProperties.font = Theme.Font.title3
            config.textProperties.color = Theme.Color.label
            config.secondaryText = loadFailed ? "Check your connection and try again." : "Movies and episodes you watch will show up here."
            config.secondaryTextProperties.font = Theme.Font.subheadline
            config.secondaryTextProperties.color = Theme.Color.labelSecondary
            if loadFailed {
                config.button = ThemeButton.primaryConfiguration(title: "Try Again")
                config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    self?.loadFailed = false
                    self?.contentUnavailableConfiguration = nil
                    self?.loadPage(offset: 0)
                }
            }
            contentUnavailableConfiguration = config
        } else if visibleItems.isEmpty && currentOffset >= totalSize {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: filter == .movies ? "film" : "tv")
            config.imageProperties.tintColor = Theme.Color.labelTertiary
            config.text = filter == .movies ? "No movies watched yet" : "No TV watched yet"
            config.textProperties.font = Theme.Font.title3
            config.textProperties.color = Theme.Color.label
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func resetAndLoad() {
        currentOffset = 0
        totalSize = 0
        isLoadingMore = false
        loadFailed = false
        loadPage(offset: 0)
    }

    private func loadPage(offset: Int) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.history(start: offset, size: pageSize))
                guard !Task.isCancelled else { return }

                totalSize = container.totalSize ?? 0
                let items = (container.Metadata ?? []).enumerated().map { idx, m in
                    HistoryItem(
                        ratingKey: m.id,
                        title: m.title,
                        type: m.type,
                        viewedAt: m.viewedAt ?? m.lastViewedAt ?? m.addedAt,
                        thumb: m.thumb,
                        grandparentThumb: m.grandparentThumb,
                        grandparentTitle: m.grandparentTitle,
                        grandparentRatingKey: m.grandparentRatingKey,
                        parentRatingKey: m.parentRatingKey,
                        parentIndex: m.parentIndex,
                        index: m.index,
                        duration: m.duration,
                        uniqueId: "\(m.id)-\(offset + idx)"
                    )
                }
                currentOffset = offset + items.count
                allItems = offset == 0 ? items : allItems + items
                loadFailed = false
                loadTask = nil
                isLoadingMore = false
                finishRefreshing()
                applySnapshot()
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("History page \(offset) failed: \(error.localizedDescription)", .networking)
                loadTask = nil
                isLoadingMore = false
                loadFailed = true
                finishRefreshing()
                updateContentUnavailable()
            }
        }
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
                let container = try await api.requestContainer(.metadata(ratingKey: entry.ratingKey))
                guard !Task.isCancelled else { return }
                guard let metadata = container.Metadata?.first else {
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

        switch entry.type {
        case "episode":
            let vc = MediaDetailViewController(
                api: api,
                ratingKey: entry.ratingKey,
                mediaType: "episode",
                showRatingKey: entry.grandparentRatingKey,
                seasonRatingKey: entry.parentRatingKey
            )
            navigationController?.pushViewController(vc, animated: true)
        case "show":
            let vc = ShowDetailViewController(api: api, showRatingKey: entry.ratingKey)
            navigationController?.pushViewController(vc, animated: true)
        default:
            let vc = MediaDetailViewController(api: api, ratingKey: entry.ratingKey, mediaType: "movie")
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .item = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }
}

extension ActivityHistoryViewController {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter
    }()

    private static let dayWithYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMdy")
        return formatter
    }()

    fileprivate static func timeText(_ timestamp: Int?) -> String? {
        guard let timestamp else { return nil }
        return timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    fileprivate static func day(for timestamp: Int?, calendar: Calendar) -> Date {
        guard let timestamp else { return .distantPast }
        return calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    fileprivate func dayTitle(forSection section: Int) -> String? {
        let identifiers = dataSource.snapshot().sectionIdentifiers
        guard identifiers.indices.contains(section), case .day(let date) = identifiers[section] else { return nil }
        if date == .distantPast { return "Earlier" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return (sameYear ? Self.dayFormatter : Self.dayWithYearFormatter).string(from: date)
    }

    /// "14 plays this week · 7 h 20 m". The time is left out unless every play in the week has a
    /// known duration, so a partial total never reads as a real one.
    fileprivate func summaryText(for items: [HistoryItem]) -> String? {
        let weekAgo = Int(Date().addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970)
        let week = items.filter { ($0.viewedAt ?? 0) >= weekAgo }
        guard !week.isEmpty else { return nil }
        var text = "\(week.count) \(week.count == 1 ? "play" : "plays") this week"
        let durations = week.compactMap(\.duration)
        if durations.count == week.count {
            let minutes = durations.reduce(0, +) / 60_000
            if minutes > 0 {
                text += " · " + (minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m")
            }
        }
        return text
    }
}

extension ActivityHistoryViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let snapshot = dataSource.snapshot()
        let lastSection = snapshot.numberOfSections - 1
        guard lastSection > 0 else { return }
        let lastCount = snapshot.numberOfItems(inSection: snapshot.sectionIdentifiers[lastSection])
        let reachingEnd = indexPaths.contains { $0.section == lastSection && $0.item >= lastCount - 10 }
        if reachingEnd, currentOffset < totalSize, !isLoadingMore {
            isLoadingMore = true
            loadPage(offset: currentOffset)
        }
    }
}
