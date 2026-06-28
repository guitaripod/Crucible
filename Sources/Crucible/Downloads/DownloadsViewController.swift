@preconcurrency import UIKit

final class DownloadsViewController: UICollectionViewController {
    private struct DLSection: Hashable {
        let id: String
        let title: String

        static func == (lhs: DLSection, rhs: DLSection) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<DLSection, String>!
    private var observerToken: UUID?
    private var pendingSnapshot = false
    private lazy var multiSelect = MultiSelectController(collectionView: collectionView, host: self)
    private var storageText: String?
    private var playerCoordinator: PlayerCoordinator?

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
        case .progress(let ratingKey, _, _, _):
            var snapshot = dataSource.snapshot()
            if snapshot.itemIdentifiers.contains(ratingKey) {
                snapshot.reconfigureItems([ratingKey])
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
            self.applySnapshot()
        }
    }

    private func refresh() {
        Task { [weak self] in
            guard let self else { return }
            let used = await DownloadManager.shared.totalBytesOnDisk()
            let free = await DownloadManager.shared.availableCapacity()
            self.storageText = "\(Formatters.fileSize(used)) used · \(Formatters.fileSize(free)) free"
            self.applySnapshot()
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        let layout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            config.headerMode = .supplementary
            config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                self?.swipeActions(at: indexPath)
            }
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
        let layoutConfig = UICollectionViewCompositionalLayoutConfiguration()
        let footerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(40))
        let footer = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: footerSize,
            elementKind: UICollectionView.elementKindSectionFooter,
            alignment: .bottom
        )
        layoutConfig.boundarySupplementaryItems = [footer]
        layout.configuration = layoutConfig
        return layout
    }

    private func configureDataSource() {
        let cellReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, ratingKey in
            guard let item = DownloadManager.shared.item(for: ratingKey) else { return }
            var config = DownloadRowConfiguration(ratingKey: ratingKey, title: item.displayTitle)
            config.subtitle = item.episodeSubtitle
            config.status = item.statusLine
            config.progress = item.progressForDisplay
            config.isError = item.state == .failed
            config.isCompleted = item.state == .completed
            config.placeholderIcon = item.mediaType == "episode" ? "tv" : "film"
            cell.contentConfiguration = config
            cell.accessories = self?.accessories(for: item) ?? []
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, ratingKey in
            cv.dequeueConfiguredReusableCell(using: cellReg, for: indexPath, item: ratingKey)
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            guard let section = self?.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section] else { return }
            var config = UIListContentConfiguration.groupedHeader()
            config.text = section.title
            cell.contentConfiguration = config
        }

        let footerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] cell, _, _ in
            var config = UIListContentConfiguration.groupedFooter()
            config.text = self?.storageText
            cell.contentConfiguration = config
        }

        dataSource.supplementaryViewProvider = { cv, kind, indexPath in
            if kind == UICollectionView.elementKindSectionFooter {
                return cv.dequeueConfiguredReusableSupplementary(using: footerReg, for: indexPath)
            }
            return cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func accessories(for item: DownloadItem) -> [UICellAccessory] {
        switch item.state {
        case .completed:
            return [.disclosureIndicator()]
        case .downloading, .queued, .waitingForWiFi:
            return [controlAccessory(symbol: "pause.circle.fill") { DownloadManager.shared.pause(item.ratingKey) }]
        case .paused:
            return [controlAccessory(symbol: "arrow.down.circle.fill") { DownloadManager.shared.resume(item.ratingKey) }]
        case .failed:
            return [controlAccessory(symbol: "arrow.clockwise.circle.fill") { DownloadManager.shared.retry(item.ratingKey) }]
        }
    }

    private func controlAccessory(symbol: String, action: @escaping () -> Void) -> UICellAccessory {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)), for: .normal)
        button.tintColor = .systemOrange
        button.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return .customView(configuration: .init(customView: button, placement: .trailing(displayed: .whenNotEditing)))
    }

    private func applySnapshot() {
        let items = DownloadManager.shared.items
        var snapshot = NSDiffableDataSourceSnapshot<DLSection, String>()

        let active = items.filter { $0.state != .completed }
        if !active.isEmpty {
            let section = DLSection(id: "active", title: "In Progress")
            snapshot.appendSections([section])
            snapshot.appendItems(active.map(\.ratingKey), toSection: section)
        }

        let movies = items.filter { $0.state == .completed && $0.mediaType == "movie" }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if !movies.isEmpty {
            let section = DLSection(id: "movies", title: "Movies")
            snapshot.appendSections([section])
            snapshot.appendItems(movies.map(\.ratingKey), toSection: section)
        }

        let episodes = items.filter { $0.state == .completed && $0.mediaType == "episode" }
        let groups = Dictionary(grouping: episodes) { $0.grandparentRatingKey ?? $0.showTitle ?? $0.ratingKey }
        let sortedGroups = groups.sorted { lhs, rhs in
            (lhs.value.first?.showTitle ?? "").localizedCaseInsensitiveCompare(rhs.value.first?.showTitle ?? "") == .orderedAscending
        }
        for (key, group) in sortedGroups {
            let title = group.first?.showTitle ?? "Show"
            let section = DLSection(id: "show:\(key)", title: title)
            snapshot.appendSections([section])
            let sorted = group.sorted {
                ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
            }
            snapshot.appendItems(sorted.map(\.ratingKey), toSection: section)
        }

        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
        updateEmptyState(isEmpty: items.isEmpty)
        updateNavItems(hasItems: !items.isEmpty)
    }

    private func updateEmptyState(isEmpty: Bool) {
        if isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "arrow.down.circle")
            config.text = "No Downloads"
            config.secondaryText = "Movies and episodes you download appear here, ready to watch offline."
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func updateNavItems(hasItems: Bool) {
        guard hasItems else {
            navigationItem.leftBarButtonItem = nil
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
        navigationItem.leftBarButtonItem = nil
        let menu = UIMenu(children: [
            UIAction(title: "Delete All Downloads", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmDeleteAll()
            }
        ])
        let menuButton = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: menu)
        navigationItem.rightBarButtonItems = [menuButton, multiSelect.barButton]
    }

    private func selectionToolbarItems(count: Int) -> [UIBarButtonItem] {
        let title = count > 0 ? "Delete \(count)" : "Delete"
        let action = UIAction(title: title, image: UIImage(systemName: "trash")) { [weak self] _ in
            self?.confirmDeleteSelected()
        }
        let delete = UIBarButtonItem(primaryAction: action)
        delete.tintColor = .systemRed
        delete.isEnabled = count > 0
        return [.flexibleSpace(), delete, .flexibleSpace()]
    }

    private func selectAllItems() {
        let all = (dataSource.snapshot().itemIdentifiers).compactMap { dataSource.indexPath(for: $0) }
        multiSelect.selectAll(all)
    }

    private func confirmDeleteSelected() {
        let keys = (collectionView.indexPathsForSelectedItems ?? []).compactMap { dataSource.itemIdentifier(for: $0) }
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

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !collectionView.isEditing, let ratingKey = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, completion in
            DownloadManager.shared.delete(ratingKey)
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView.isEditing { multiSelect.selectionChanged(); return }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let ratingKey = dataSource.itemIdentifier(for: indexPath),
              let item = DownloadManager.shared.item(for: ratingKey) else { return }
        openDetail(item)
    }

    override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if collectionView.isEditing { multiSelect.selectionChanged() }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        true
    }

    override func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        multiSelect.setEditing(true)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !collectionView.isEditing else { return nil }
        guard let indexPath = indexPaths.first,
              let ratingKey = dataSource.itemIdentifier(for: indexPath),
              let item = DownloadManager.shared.item(for: ratingKey) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
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
            return UIMenu(children: actions)
        })
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

    private func playOffline(_ item: DownloadItem) {
        guard let asset = DownloadManager.shared.offlineAsset(for: item.ratingKey) else {
            let alert = UIAlertController(title: "File Missing", message: "This download could not be found on disk. Try downloading it again.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let meta = PlayerCoordinator.Metadata(
            title: item.title,
            showName: item.showTitle,
            seasonNumber: item.seasonNumber,
            episodeNumber: item.episodeNumber,
            posterPath: item.plexThumbPath,
            duration: item.durationSecs
        )
        let coordinator = PlayerCoordinator(
            api: api,
            ratingKey: item.ratingKey,
            mediaType: item.mediaType,
            showRatingKey: item.grandparentRatingKey,
            seasonRatingKey: item.parentRatingKey,
            resumePosition: item.resumeSecs,
            metadata: meta,
            offlineAsset: asset
        )
        playerCoordinator = coordinator
        coordinator.present(from: self)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
