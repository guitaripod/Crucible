@preconcurrency import UIKit

final class DownloadsViewController: UICollectionViewController {
    private enum SectionID: String, Hashable {
        case summary
        case active
        case ready

        var title: String? {
            switch self {
            case .summary: return nil
            case .active: return "Downloading"
            case .ready: return "Ready to Watch"
            }
        }
    }

    private enum Row: Hashable {
        case summary
        case download(String)
        case show(String)
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<SectionID, Row>!
    private var observerToken: UUID?
    private var pendingSnapshot = false
    private lazy var multiSelect = MultiSelectController(collectionView: collectionView, host: self)
    private var playerCoordinator: PlayerCoordinator?
    private var storage = StorageSnapshot()
    private var rates = DownloadRateTracker()
    private var showGroups: [String: DownloadedShowGroup] = [:]
    private var watchedKeys: [String] = []
    private var reclaimableBytes: Int64 = 0

    /// Set when presented modally (offline launch fallback); survives the edit-mode item swaps.
    var closeItem: UIBarButtonItem?

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observerToken {
            Task { @MainActor in DownloadManager.shared.removeObserver(observerToken) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        collectionView.backgroundColor = Theme.Color.canvas
        view.backgroundColor = Theme.Color.canvas
        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
        configureMultiSelect()
        DownloadManager.shared.bootstrap()
    }

    private func configureMultiSelect() {
        multiSelect.onEnter = { [weak self] in self?.updateNavItems(hasItems: true) }
        multiSelect.onExit = { [weak self] in self?.updateNavItems(hasItems: !DownloadManager.shared.items.isEmpty) }
        multiSelect.toolbarItemsProvider = { [weak self] count in self?.selectionToolbarItems(count: count) ?? [] }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if observerToken == nil {
            observerToken = DownloadManager.shared.addObserver { [weak self] event in
                self?.handle(event)
            }
        }
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        multiSelect.setEditing(false)
        if let observerToken {
            DownloadManager.shared.removeObserver(observerToken)
            self.observerToken = nil
        }
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let ratingKey, _, let downloadedBytes, _):
            rates.record(ratingKey: ratingKey, bytes: downloadedBytes)
            var snapshot = dataSource.snapshot()
            let row = Row.download(ratingKey)
            if snapshot.itemIdentifiers.contains(row) {
                snapshot.reconfigureItems([row])
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        case .changed, .failed:
            scheduleSnapshot()
        case .finished:
            refresh()
        }
    }

    /// Collapses the burst of state events at each episode boundary into one full snapshot rebuild.
    private func scheduleSnapshot() {
        guard !pendingSnapshot else { return }
        pendingSnapshot = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingSnapshot = false
            self.refresh()
        }
    }

    private func refresh() {
        Task { [weak self] in
            guard let self else { return }
            self.storage = await StorageSnapshot.capture()
            self.applySnapshot()
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            let sectionID = self?.dataSource.snapshot().sectionIdentifiers[safe: sectionIndex]
            var config = Theme.groupedListConfiguration()
            config.headerMode = sectionID == .summary ? .none : .supplementary
            config.headerTopPadding = 0
            config.separatorConfiguration.color = Theme.Color.separator
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.swipeActions(at: indexPath)
            }
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { [weak self] cell, _, row in
            cell.configurationUpdateHandler = { cell, state in
                var background = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
                background.cornerRadius = 20
                background.backgroundColor = state.isHighlighted || state.isSelected ? Theme.Color.surfaceRaised : Theme.Color.surface
                cell.backgroundConfiguration = background
            }
            self?.configure(cell, for: row)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, row in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: row)
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            guard let section = self?.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section],
                  let title = section.title else { return }
            cell.contentConfiguration = SectionHeaderConfiguration(title: title)
            cell.backgroundConfiguration = .clear()
        }

        dataSource.supplementaryViewProvider = { cv, _, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func configure(_ cell: UICollectionViewListCell, for row: Row) {
        switch row {
        case .summary:
            cell.contentConfiguration = summaryConfiguration()
            cell.accessories = []
        case .download(let ratingKey):
            guard let item = DownloadManager.shared.item(for: ratingKey) else { return }
            if item.state == .completed {
                cell.contentConfiguration = item.mediaType == "movie" ? DownloadRowFactory.movie(item) : DownloadRowFactory.episode(item)
                cell.accessories = [.multiselect(), .disclosureIndicator()]
            } else {
                cell.contentConfiguration = DownloadRowFactory.active(item, rate: rates.rate(for: ratingKey))
                cell.accessories = [.multiselect()]
            }
        case .show(let key):
            guard let group = showGroups[key] else { return }
            cell.contentConfiguration = DownloadRowFactory.show(group)
            cell.accessories = [.multiselect(), .disclosureIndicator()]
        }
    }

    private func summaryConfiguration() -> StorageSummaryConfiguration {
        StorageSummaryConfiguration(
            storage: storage,
            isWiFiOnly: !Preferences.downloadOverCellular,
            reclaimableBytes: reclaimableBytes,
            onToggleWiFiOnly: { [weak self] in self?.toggleWiFiOnly() },
            onFreeUp: { [weak self] source in self?.confirmFreeUp(from: source) }
        )
    }

    private func toggleWiFiOnly() {
        Preferences.downloadOverCellular.toggle()
        DownloadManager.shared.cellularPreferenceChanged()
        Haptics.selection()
        reconfigureSummary()
    }

    private func reconfigureSummary() {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.summary) else { return }
        snapshot.reconfigureItems([.summary])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func confirmFreeUp(from source: UIView) {
        let keys = watchedKeys
        guard !keys.isEmpty else { return }
        let noun = keys.count == 1 ? "download" : "downloads"
        let sheet = UIAlertController(
            title: "Delete \(keys.count) watched \(noun)?",
            message: "Frees up \(Formatters.fileSize(reclaimableBytes)) on this device.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            Haptics.medium()
            DownloadManager.shared.deleteItems(keys)
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = source
        sheet.popoverPresentationController?.sourceRect = source.bounds
        present(sheet, animated: true)
    }

    private func applySnapshot() {
        let items = DownloadManager.shared.items
        var snapshot = NSDiffableDataSourceSnapshot<SectionID, Row>()

        let active = items.enumerated()
            .filter { $0.element.state != .completed }
            .sorted { lhs, rhs in
                let left = lhs.element.state == .downloading ? 0 : 1
                let right = rhs.element.state == .downloading ? 0 : 1
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        rates.keepOnly(Set(active.filter { $0.state == .downloading }.map(\.ratingKey)))

        let movies = items.filter { $0.state == .completed && $0.mediaType == "movie" }
        let groups = DownloadedShowGroup.groups(from: items)
        showGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0) })
        let watched = items.filter { $0.state == .completed && $0.isWatched }
        watchedKeys = watched.map(\.ratingKey)
        reclaimableBytes = watched.reduce(0) { $0 + $1.totalBytes }

        if !items.isEmpty {
            snapshot.appendSections([.summary])
            snapshot.appendItems([.summary], toSection: .summary)
        }
        if !active.isEmpty {
            snapshot.appendSections([.active])
            snapshot.appendItems(active.map { .download($0.ratingKey) }, toSection: .active)
        }

        let ready = readyRows(groups: groups, movies: movies)
        if !ready.isEmpty {
            snapshot.appendSections([.ready])
            snapshot.appendItems(ready, toSection: .ready)
        }

        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        updateEmptyState(isEmpty: items.isEmpty)
        updateNavItems(hasItems: !items.isEmpty)
    }

    /// Shows and movies interleaved alphabetically, the way the library lists them.
    private func readyRows(groups: [DownloadedShowGroup], movies: [DownloadItem]) -> [Row] {
        let entries: [(title: String, row: Row)] =
            groups.map { ($0.title, Row.show($0.key)) } + movies.map { ($0.title, Row.download($0.ratingKey)) }
        return entries
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map(\.row)
    }

    private func updateEmptyState(isEmpty: Bool) {
        if isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "arrow.down.circle")
            config.imageProperties.tintColor = Theme.Color.accentText
            config.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .light)
            config.text = "No Downloads"
            config.textProperties.font = Theme.Font.title3
            config.textProperties.color = Theme.Color.label
            config.secondaryText = "Movies and episodes you download appear here, ready to watch offline."
            config.secondaryTextProperties.font = Theme.Font.subheadline
            config.secondaryTextProperties.color = Theme.Color.labelSecondary
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func updateNavItems(hasItems: Bool) {
        guard hasItems else {
            navigationItem.leftBarButtonItem = closeItem
            navigationItem.rightBarButtonItems = nil
            return
        }
        if multiSelect.isEditing {
            navigationItem.leftBarButtonItem = UIBarButtonItem(primaryAction: UIAction(title: "Select All") { [weak self] _ in
                self?.selectAllItems()
            })
            navigationItem.rightBarButtonItems = [multiSelect.barButton]
            return
        }
        navigationItem.leftBarButtonItem = closeItem
        let menu = UIMenu(children: [
            UIAction(title: "Delete All Downloads", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmDeleteAll()
            }
        ])
        let menuButton = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: menu)
        menuButton.accessibilityLabel = "More"
        navigationItem.rightBarButtonItems = [multiSelect.barButton, menuButton]
    }

    private func selectionToolbarItems(count: Int) -> [UIBarButtonItem] {
        let title = count > 0 ? "Delete \(count)" : "Delete"
        let action = UIAction(title: title, image: UIImage(systemName: "trash")) { [weak self] _ in
            self?.confirmDeleteSelected()
        }
        let delete = UIBarButtonItem(primaryAction: action)
        delete.tintColor = Theme.Color.destructive
        delete.isEnabled = count > 0
        return [.flexibleSpace(), delete, .flexibleSpace()]
    }

    private func selectAllItems() {
        let selectable = dataSource.snapshot().itemIdentifiers.filter { $0 != .summary }
        multiSelect.selectAll(selectable.compactMap { dataSource.indexPath(for: $0) })
    }

    /// Every ratingKey a row stands for: one for a movie or episode, all episodes for a show.
    private func ratingKeys(for row: Row) -> [String] {
        switch row {
        case .summary: return []
        case .download(let ratingKey): return [ratingKey]
        case .show(let key): return showGroups[key]?.ratingKeys ?? []
        }
    }

    private func confirmDeleteSelected() {
        let rows = (collectionView.indexPathsForSelectedItems ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
        let keys = rows.flatMap { ratingKeys(for: $0) }
        guard !keys.isEmpty else { return }
        let noun = keys.count == 1 ? "Download" : "Downloads"
        let alert = UIAlertController(title: "Delete \(keys.count) \(noun)?", message: "This removes the selected items from this device.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            DownloadManager.shared.deleteItems(keys)
            self?.multiSelect.setEditing(false)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func confirmDeleteAll() {
        let alert = UIAlertController(title: "Delete All Downloads?", message: "This removes every downloaded movie and episode from this device.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Delete All", style: .destructive) { _ in
            DownloadManager.shared.deleteAll()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func confirmDeleteShow(_ group: DownloadedShowGroup) {
        let count = group.items.count
        let alert = UIAlertController(
            title: "Delete \(group.title)?",
            message: "This removes \(count) downloaded \(count == 1 ? "episode" : "episodes") from this device.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
            DownloadManager.shared.deleteItems(group.ratingKeys)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !collectionView.isEditing, let row = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let delete: UIContextualAction
        switch row {
        case .summary:
            return nil
        case .download(let ratingKey):
            delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, completion in
                DownloadManager.shared.delete(ratingKey)
                completion(true)
            }
        case .show(let key):
            delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
                if let group = self?.showGroups[key] { self?.confirmDeleteShow(group) }
                completion(true)
            }
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != .summary
    }

    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != .summary
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView.isEditing { multiSelect.selectionChanged(); return }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        switch row {
        case .summary:
            break
        case .download(let ratingKey):
            if let item = DownloadManager.shared.item(for: ratingKey) { openDetail(item) }
        case .show(let key):
            if let group = showGroups[key] { openShow(group) }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if collectionView.isEditing { multiSelect.selectionChanged() }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) != .summary
    }

    override func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        multiSelect.setEditing(true)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !collectionView.isEditing,
              let indexPath = indexPaths.first,
              let row = dataSource.itemIdentifier(for: indexPath) else { return nil }
        switch row {
        case .summary:
            return nil
        case .download(let ratingKey):
            guard let item = DownloadManager.shared.item(for: ratingKey) else { return nil }
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                UIMenu(children: self?.menuActions(for: item) ?? [])
            })
        case .show(let key):
            guard let group = showGroups[key] else { return nil }
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: "View Episodes", image: UIImage(systemName: "list.bullet")) { _ in
                        self?.openShow(group)
                    },
                    UIAction(title: "Delete All Episodes", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                        self?.confirmDeleteShow(group)
                    },
                ])
            })
        }
    }

    private func menuActions(for item: DownloadItem) -> [UIMenuElement] {
        let ratingKey = item.ratingKey
        var actions = [UIMenuElement]()
        switch item.state {
        case .completed:
            actions.append(UIAction(title: item.resumeSecs > 1 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                self?.playOffline(item)
            })
        case .downloading, .queued, .waitingForWiFi:
            actions.append(UIAction(title: "Pause", image: UIImage(systemName: "pause.fill")) { _ in
                DownloadManager.shared.pause(ratingKey)
            })
        case .paused:
            actions.append(UIAction(title: "Resume", image: UIImage(systemName: "arrow.down.to.line")) { _ in
                DownloadManager.shared.resume(ratingKey)
            })
        case .failed:
            actions.append(UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise")) { _ in
                DownloadManager.shared.retry(ratingKey)
            })
        }
        actions.append(UIAction(title: "View Details", image: UIImage(systemName: "info.circle")) { [weak self] _ in
            self?.openDetail(item)
        })
        actions.append(UIAction(title: "Delete Download", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
            DownloadManager.shared.delete(ratingKey)
        })
        return actions
    }

    private func openDetail(_ item: DownloadItem) {
        let detail = MediaDetailViewController(
            api: api,
            ratingKey: item.ratingKey,
            mediaType: item.mediaType,
            showRatingKey: item.grandparentRatingKey,
            seasonRatingKey: item.parentRatingKey
        )
        navigationController?.pushViewController(detail, animated: true)
    }

    private func openShow(_ group: DownloadedShowGroup) {
        navigationController?.pushViewController(DownloadedShowViewController(api: api, groupKey: group.key, title: group.title), animated: true)
    }

    private func playOffline(_ item: DownloadItem) {
        playerCoordinator = OfflinePlayback.start(item, api: api, from: self)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
