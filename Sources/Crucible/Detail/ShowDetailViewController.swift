@preconcurrency import UIKit

final class ShowDetailViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case hero, seasonPicker, episodes, actions
    }

    enum Item: Hashable {
        case hero
        case season(PlexMetadata)
        case episode(PlexMetadata)
        case action(String)
    }

    private let api: APIClient
    private let showRatingKey: String
    private let initialSeasonKey: String?
    private var loadTask: Task<Void, Never>?
    private var seasonTask: Task<Void, Never>?
    private var show: PlexMetadata?
    private var seasons: [PlexMetadata] = []
    private var selectedSeasonKey: String?
    private var episodes: [PlexMetadata] = []
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var downloadObserver: UUID?
    private var pendingFullReconfigure = false
    private lazy var multiSelect = MultiSelectController(collectionView: collectionView, host: self)

    init(api: APIClient, showRatingKey: String, initialSeasonKey: String? = nil) {
        self.api = api
        self.showRatingKey = showRatingKey
        self.initialSeasonKey = initialSeasonKey
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        collectionView.collectionViewLayout = createLayout()
        configureDataSource()
        configureMultiSelect()
    }

    private func configureMultiSelect() {
        multiSelect.onEnter = { [weak self] in self?.updateSelectBarButton(); self?.reconfigureEpisodeAccessories() }
        multiSelect.onExit = { [weak self] in self?.updateSelectBarButton(); self?.reconfigureEpisodeAccessories() }
        multiSelect.toolbarItemsProvider = { [weak self] count in self?.selectionToolbarItems(count: count) ?? [] }
    }

    private func updateSelectBarButton() {
        let hasEpisodes = !episodes.isEmpty
        navigationItem.rightBarButtonItems = (multiSelect.isEditing || hasEpisodes) ? [multiSelect.barButton] : nil
    }

    private func reconfigureEpisodeAccessories() {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        let eps = snapshot.itemIdentifiers.filter { if case .episode = $0 { return true }; return false }
        guard !eps.isEmpty else { return }
        snapshot.reconfigureItems(eps)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if downloadObserver == nil {
            downloadObserver = DownloadManager.shared.addObserver { [weak self] event in
                self?.handleDownloadEvent(event)
            }
        }
        loadData()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        multiSelect.setEditing(false)
        loadTask?.cancel()
        seasonTask?.cancel()
        if let downloadObserver {
            DownloadManager.shared.removeObserver(downloadObserver)
            self.downloadObserver = nil
        }
        if isMovingFromParent || isBeingDismissed {
            userActivity?.resignCurrent()
        }
    }

    deinit {
        if let downloadObserver {
            Task { @MainActor in DownloadManager.shared.removeObserver(downloadObserver) }
        }
    }

    /// Progress fires several times per second per active download; reconfiguring every episode cell
    /// on each tick thrashes the whole list when a season is downloading. Scope progress to the single
    /// episode that changed, and only rebuild every cell on the rarer state transitions.
    private func handleDownloadEvent(_ event: DownloadEvent) {
        switch event {
        case .progress(let ratingKey, _, _, _):
            reconfigureEpisode(ratingKey)
        case .changed, .finished, .failed:
            reconfigureDownloadItems()
        }
    }

    private func reconfigureEpisode(_ ratingKey: String) {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        let target = snapshot.itemIdentifiers.filter { item in
            if case .episode(let episode) = item { return episode.ratingKey == ratingKey }
            return false
        }
        guard !target.isEmpty else { return }
        snapshot.reconfigureItems(target)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// A single episode boundary fires `.finished` + `.changed` and the next item's start fires another
    /// `.changed` — coalesce that burst into one full rebuild per runloop tick.
    private func reconfigureDownloadItems() {
        guard !pendingFullReconfigure else { return }
        pendingFullReconfigure = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingFullReconfigure = false
            self.performFullReconfigure()
        }
    }

    private func performFullReconfigure() {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        let items = snapshot.itemIdentifiers.filter { item in
            if case .episode = item { return true }
            if item == .action("downloadSeason") { return true }
            return false
        }
        guard !items.isEmpty else { return }
        snapshot.reconfigureItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func downloadBadge(for ratingKey: String) -> EpisodeContentConfiguration.DownloadBadge {
        guard let item = DownloadManager.shared.item(for: ratingKey) else { return .none }
        switch item.state {
        case .completed: return .completed
        case .downloading, .queued, .waitingForWiFi, .paused:
            return .downloading(Int((item.progress * 100).rounded()))
        case .failed: return .none
        }
    }

    private func episodeAccessories(for episode: PlexMetadata) -> [UICellAccessory] {
        if collectionView.isEditing { return [.multiselect()] }
        guard DownloadManager.shared.state(for: episode.id) == .failed else { return [] }
        return [failedDownloadAccessory(ratingKey: episode.id)]
    }

    /// The failed state has no thumbnail badge, so surface it as a red retry control on the row —
    /// mirroring the Downloads screen's per-row failure affordance.
    private func failedDownloadAccessory(ratingKey: String) -> UICellAccessory {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "exclamationmark.circle.fill")
        config.baseForegroundColor = .systemRed
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in DownloadManager.shared.retry(ratingKey) }, for: .touchUpInside)
        button.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        return .customView(configuration: .init(customView: button, placement: .trailing(displayed: .whenNotEditing)))
    }

    private func donateActivity(_ show: PlexMetadata) {
        let activity = MediaActivity.make(
            ratingKey: showRatingKey,
            mediaType: "show",
            title: show.title,
            subtitle: show.year.map(String.init),
            summary: show.summary,
            thumbPath: show.thumb
        )
        userActivity = activity
        activity.becomeCurrent()
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let section = self?.dataSource?.sectionIdentifier(for: sectionIndex) else { return nil }

            switch section {
            case .hero:
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(300)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(300)), subitems: [item])
                return NSCollectionLayoutSection(group: group)

            case .seasonPicker:
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .estimated(96), heightDimension: .absolute(40)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .estimated(96), heightDimension: .absolute(40)), subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.orthogonalScrollingBehavior = .continuous
                layoutSection.interGroupSpacing = 10
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
                return layoutSection

            case .episodes:
                var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
                listConfig.showsSeparators = true
                return NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: environment)

            case .actions:
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)), subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16)
                return layoutSection
            }
        }
    }

    private func configureDataSource() {
        let heroCellReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [unowned self] cell, _, _ in
            guard let show = self.show else { return }
            cell.contentConfiguration = ShowHeroConfiguration(show: show, seasons: self.seasons)
        }

        let seasonReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { [unowned self] cell, _, season in
            let button = (cell.contentView.subviews.first as? UIButton) ?? {
                let created = UIButton()
                created.isUserInteractionEnabled = false
                created.translatesAutoresizingMaskIntoConstraints = false
                cell.contentView.addSubview(created)
                NSLayoutConstraint.activate([
                    created.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                    created.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                    created.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                    created.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                ])
                return created
            }()
            var config: UIButton.Configuration
            if self.selectedSeasonKey == season.id {
                config = Glass.prominentButton {
                    var c = UIButton.Configuration.gray()
                    c.baseBackgroundColor = .systemOrange
                    c.baseForegroundColor = .white
                    return c
                }
            } else {
                config = Glass.clearGlassButton { UIButton.Configuration.gray() }
            }
            config.title = season.title.isEmpty ? "Season \(season.index ?? 0)" : season.title
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 18, bottom: 7, trailing: 18)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 14, weight: .semibold)
                return outgoing
            }
            button.configuration = config
        }

        let episodeReg = UICollectionView.CellRegistration<UICollectionViewListCell, PlexMetadata> { [weak self] cell, _, item in
            let episode = self?.episodes.first { $0.id == item.id } ?? item
            var config = EpisodeContentConfiguration()
            config.episodeNumber = episode.index
            config.title = episode.title
            config.summary = episode.summary
            config.thumbPath = episode.thumb
            config.duration = Formatters.duration(episode.durationSecs)
            config.isWatched = episode.isWatched
            if !episode.isWatched && episode.positionSecs > 0 && episode.durationSecs > 0 {
                config.progress = episode.positionSecs / episode.durationSecs
            }
            config.downloadBadge = self?.downloadBadge(for: episode.id) ?? .none
            cell.contentConfiguration = config
            cell.accessories = self?.episodeAccessories(for: episode) ?? []
        }

        let actionReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [unowned self] cell, _, action in
            if action == "downloadSeason" {
                self.configureSeasonDownloadCell(cell)
                return
            }
            var buttonConfig = Glass.glassButton {
                var config = UIButton.Configuration.tinted()
                config.baseBackgroundColor = .systemOrange.withAlphaComponent(0.15)
                config.baseForegroundColor = .systemOrange
                return config
            }
            buttonConfig.cornerStyle = .large
            switch action {
            case "watchAll":
                buttonConfig.title = "Mark All Watched"
                buttonConfig.image = UIImage(systemName: "checkmark.circle.fill")
            case "unwatchAll":
                buttonConfig.title = "Mark All Unwatched"
                buttonConfig.image = UIImage(systemName: "circle")
            default: break
            }
            buttonConfig.imagePadding = 10
            let button = UIButton(configuration: buttonConfig)
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                Task {
                    switch action {
                    case "watchAll": try? await self.api.requestVoid(.scrobble(ratingKey: self.showRatingKey))
                    case "unwatchAll": try? await self.api.requestVoid(.unscrobble(ratingKey: self.showRatingKey))
                    default: break
                    }
                    await self.api.invalidateCache()
                    self.loadData()
                }
            }, for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            cell.contentView.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                button.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                button.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                button.heightAnchor.constraint(equalToConstant: 44),
            ])
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            switch item {
            case .hero: return cv.dequeueConfiguredReusableCell(using: heroCellReg, for: indexPath, item: "hero")
            case .season(let s): return cv.dequeueConfiguredReusableCell(using: seasonReg, for: indexPath, item: s)
            case .episode(let e): return cv.dequeueConfiguredReusableCell(using: episodeReg, for: indexPath, item: e)
            case .action(let a): return cv.dequeueConfiguredReusableCell(using: actionReg, for: indexPath, item: a)
            }
        }
    }

    private func loadData() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let showContainer = try await api.requestContainer(.metadata(ratingKey: showRatingKey))
                guard !Task.isCancelled, let showMeta = showContainer.Metadata?.first else { return }
                show = showMeta
                title = showMeta.title
                donateActivity(showMeta)

                let seasonsContainer = try await api.requestContainer(.children(ratingKey: showRatingKey))
                guard !Task.isCancelled else { return }
                seasons = (seasonsContainer.Metadata ?? []).filter { $0.mediaType == "season" }

                if selectedSeasonKey == nil || !seasons.contains(where: { $0.id == selectedSeasonKey }) {
                    let firstUnwatched = seasons.first {
                        let watched = $0.viewedLeafCount ?? 0
                        let total = $0.leafCount ?? 0
                        return watched < total
                    }
                    if let initialSeasonKey, seasons.contains(where: { $0.id == initialSeasonKey }) {
                        selectedSeasonKey = initialSeasonKey
                    } else {
                        selectedSeasonKey = firstUnwatched?.id ?? seasons.first?.id
                    }
                }

                if let selectedSeasonKey {
                    await loadSeason(selectedSeasonKey)
                }
                contentUnavailableConfiguration = nil
                await applySnapshot()
            } catch {
                guard !Task.isCancelled else { return }
                if show == nil {
                    var errConfig = UIContentUnavailableConfiguration.empty()
                    errConfig.image = UIImage(systemName: "exclamationmark.triangle")
                    errConfig.text = "Failed to load"
                    errConfig.secondaryText = error.localizedDescription
                    errConfig.button.title = "Retry"
                    errConfig.buttonProperties.primaryAction = UIAction { [weak self] _ in
                        self?.contentUnavailableConfiguration = nil
                        self?.loadData()
                    }
                    contentUnavailableConfiguration = errConfig
                }
            }
        }
    }

    private func loadSeason(_ seasonKey: String) async {
        do {
            let container = try await api.requestContainer(.children(ratingKey: seasonKey))
            guard !Task.isCancelled else { return }
            episodes = container.Metadata ?? []
        } catch {}
    }

    private func reconfigureSeasonChips() {
        var snapshot = dataSource.snapshot()
        let seasonItems = snapshot.itemIdentifiers.filter { item in
            if case .season = item { return true }
            return false
        }
        guard !seasonItems.isEmpty else { return }
        snapshot.reconfigureItems(seasonItems)
        Task { await dataSource.apply(snapshot, animatingDifferences: false) }
    }

    private func applySnapshot() async {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

        snapshot.appendSections([.hero])
        snapshot.appendItems([.hero], toSection: .hero)

        if !seasons.isEmpty {
            snapshot.appendSections([.seasonPicker])
            snapshot.appendItems(seasons.map { .season($0) }, toSection: .seasonPicker)
        }

        snapshot.appendSections([.episodes])
        snapshot.appendItems(episodes.map { .episode($0) }, toSection: .episodes)

        snapshot.appendSections([.actions])
        var actionItems: [Item] = []
        if !episodes.isEmpty { actionItems.append(.action("downloadSeason")) }
        actionItems.append(contentsOf: [.action("watchAll"), .action("unwatchAll")])
        snapshot.appendItems(actionItems, toSection: .actions)

        await dataSource.apply(snapshot, animatingDifferences: false)

        var refreshed = dataSource.snapshot()
        let dynamic = refreshed.itemIdentifiers.filter { item in
            switch item {
            case .hero, .episode: return true
            default: return item == .action("downloadSeason")
            }
        }
        if !dynamic.isEmpty {
            refreshed.reconfigureItems(dynamic)
            await dataSource.apply(refreshed, animatingDifferences: false)
        }
        updateSelectBarButton()
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView.isEditing { multiSelect.selectionChanged(); return }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .season(let season):
            guard selectedSeasonKey != season.id else { return }
            selectedSeasonKey = season.id
            reconfigureSeasonChips()
            seasonTask?.cancel()
            seasonTask = Task { [weak self] in
                guard let self else { return }
                await loadSeason(season.id)
                guard !Task.isCancelled else { return }
                await applySnapshot()
            }
        case .episode(let episode):
            let detail = MediaDetailViewController(
                api: api,
                ratingKey: episode.id,
                mediaType: "episode",
                showRatingKey: showRatingKey,
                seasonRatingKey: selectedSeasonKey
            )
            navigationController?.pushViewController(detail, animated: true)
        default:
            break
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if collectionView.isEditing { multiSelect.selectionChanged() }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard collectionView.isEditing else { return true }
        if case .episode = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        if case .episode = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        multiSelect.setEditing(true)
    }

    private var playerCoordinator: PlayerCoordinator?

    private func quickPlay(_ item: PlexMetadata) {
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }

    private func configureSeasonDownloadCell(_ cell: UICollectionViewCell) {
        var config = Glass.glassButton {
            var c = UIButton.Configuration.tinted()
            c.baseBackgroundColor = .systemOrange.withAlphaComponent(0.15)
            c.baseForegroundColor = .systemOrange
            return c
        }
        config.cornerStyle = .large
        config.imagePadding = 10

        let states = episodes.map { DownloadManager.shared.state(for: $0.id) }
        let total = episodes.count
        let completed = states.filter { $0 == .completed }.count
        let active = states.filter { $0?.isActive ?? false }.count

        let menu: UIMenu

        if total > 0, completed == total {
            config.baseForegroundColor = .systemGreen
            config.title = "Season Downloaded"
            config.image = UIImage(systemName: "checkmark.circle.fill")
            menu = UIMenu(children: [
                UIAction(title: "Remove Season Downloads", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.removeSeasonDownloads()
                }
            ])
        } else if active > 0 {
            config.title = "Downloading Season · \(completed)/\(total)"
            config.showsActivityIndicator = true
            menu = UIMenu(children: [
                UIAction(title: "Cancel Season Downloads", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.removeSeasonDownloads()
                }
            ])
        } else {
            config.title = completed > 0 ? "Download Remaining (\(total - completed))" : "Download Season"
            config.image = UIImage(systemName: "arrow.down.circle")
            menu = seasonQualityMenu()
        }

        let button = UIButton(configuration: config)
        button.tintColor = config.baseForegroundColor
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        button.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
        cell.contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
            button.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
            button.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func seasonQualityMenu() -> UIMenu {
        let current = Preferences.downloadQuality
        let actions = DownloadQuality.allCases.map { quality in
            UIAction(title: "\(quality.title) · \(quality.detail)", state: quality == current ? .on : .off) { [weak self] _ in
                self?.enqueueSeason(quality: quality)
            }
        }
        return UIMenu(title: "Download Quality", children: actions)
    }

    private func enqueueSeason(quality: DownloadQuality) {
        let added = DownloadManager.shared.enqueueAll(episodes, quality: quality)
        AppLogger.notice("Season download queued \(added) episodes", .persistence)
    }

    private func removeSeasonDownloads() {
        let keys = episodes.map(\.id).filter { DownloadManager.shared.item(for: $0) != nil }
        DownloadManager.shared.deleteItems(keys)
    }

    // MARK: - Batch selection actions

    private func selectionToolbarItems(count: Int) -> [UIBarButtonItem] {
        let selectAll = UIBarButtonItem(primaryAction: UIAction(title: "Select All") { [weak self] _ in
            self?.selectAllEpisodes()
        })

        let downloadItem = UIBarButtonItem(title: count > 0 ? "Download \(count)" : "Download", menu: selectedDownloadMenu())
        downloadItem.isEnabled = count > 0

        let removeAction = UIAction(title: count > 0 ? "Remove \(count)" : "Remove") { [weak self] _ in
            self?.removeSelectedEpisodes()
        }
        let removeItem = UIBarButtonItem(primaryAction: removeAction)
        removeItem.tintColor = .systemRed
        removeItem.isEnabled = count > 0 && selectionHasDownloads()

        return [selectAll, .flexibleSpace(), downloadItem, .flexibleSpace(), removeItem]
    }

    private func selectedDownloadMenu() -> UIMenu {
        let current = Preferences.downloadQuality
        let actions = DownloadQuality.allCases.map { quality in
            UIAction(title: "\(quality.title) · \(quality.detail)", state: quality == current ? .on : .off) { [weak self] _ in
                self?.downloadSelectedEpisodes(quality: quality)
            }
        }
        return UIMenu(title: "Download Quality", children: actions)
    }

    private func selectedEpisodes() -> [PlexMetadata] {
        (collectionView.indexPathsForSelectedItems ?? []).compactMap {
            if case .episode(let episode) = dataSource.itemIdentifier(for: $0) { return episode }
            return nil
        }
    }

    private func selectionHasDownloads() -> Bool {
        selectedEpisodes().contains { DownloadManager.shared.item(for: $0.id) != nil }
    }

    private func selectAllEpisodes() {
        let paths = episodes.compactMap { dataSource.indexPath(for: .episode($0)) }
        multiSelect.selectAll(paths)
    }

    private func downloadSelectedEpisodes(quality: DownloadQuality) {
        let eps = selectedEpisodes()
        guard !eps.isEmpty else { return }
        let added = DownloadManager.shared.enqueueAll(eps, quality: quality)
        AppLogger.notice("Batch download queued \(added) episodes", .persistence)
        multiSelect.setEditing(false)
    }

    private func removeSelectedEpisodes() {
        let keys = selectedEpisodes().map(\.id).filter { DownloadManager.shared.item(for: $0) != nil }
        guard !keys.isEmpty else { return }
        DownloadManager.shared.deleteItems(keys)
        multiSelect.setEditing(false)
    }

    private func downloadMenuAction(for episode: PlexMetadata) -> UIMenuElement {
        DownloadMenu.action(for: episode)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !collectionView.isEditing else { return nil }
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        switch item {
        case .season(let season):
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                guard let self else { return nil }
                return UIMenu(children: [
                    UIAction(title: "Mark Season Watched", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                        guard let self else { return }
                        Task {
                            try? await self.api.requestVoid(.scrobble(ratingKey: season.id))
                            await self.api.invalidateCache()
                            self.loadData()
                        }
                    },
                    UIAction(title: "Mark Season Unwatched", image: UIImage(systemName: "circle")) { [weak self] _ in
                        guard let self else { return }
                        Task {
                            try? await self.api.requestVoid(.unscrobble(ratingKey: season.id))
                            await self.api.invalidateCache()
                            self.loadData()
                        }
                    },
                ])
            })
        case .episode(let episode):
            return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
                guard let self else { return nil }
                return UIMenu(children: [
                    UIAction(title: episode.positionSecs > 0 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                        self?.quickPlay(episode)
                    },
                    self.downloadMenuAction(for: episode),
                    UIAction(title: episode.isWatched ? "Mark Unwatched" : "Mark Watched", image: UIImage(systemName: episode.isWatched ? "eye.slash" : "eye")) { [weak self] _ in
                        guard let self else { return }
                        Task {
                            if episode.isWatched {
                                try? await self.api.requestVoid(.unscrobble(ratingKey: episode.id))
                            } else {
                                try? await self.api.requestVoid(.scrobble(ratingKey: episode.id))
                            }
                            await self.api.invalidateCache()
                            self.loadData()
                        }
                    },
                ])
            })
        default:
            return nil
        }
    }
}

struct ShowHeroConfiguration: UIContentConfiguration, Hashable {
    let show: PlexMetadata
    let seasons: [PlexMetadata]

    static func == (lhs: ShowHeroConfiguration, rhs: ShowHeroConfiguration) -> Bool {
        lhs.show.id == rhs.show.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(show.id)
    }

    func makeContentView() -> UIView & UIContentView {
        ShowHeroContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> ShowHeroConfiguration {
        self
    }
}

final class ShowHeroContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private var currentImagePath: String?

    private let backdropImageView = UIImageView()
    private let gradientLayer = CAGradientLayer()
    private let overlayStack = UIStackView()
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()
    private let overviewLabel = UILabel()
    private let progressLabel = UILabel()
    private let progressBar = ProgressBar()
    private var imageTask: Task<Void, Never>?

    init(configuration: ShowHeroConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        backdropImageView.contentMode = .scaleAspectFill
        backdropImageView.clipsToBounds = true
        backdropImageView.backgroundColor = .secondarySystemBackground
        backdropImageView.translatesAutoresizingMaskIntoConstraints = false

        gradientLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.4).cgColor,
            UIColor.black.withAlphaComponent(0.85).cgColor,
        ]
        gradientLayer.locations = [0.0, 0.5, 1.0]
        backdropImageView.layer.addSublayer(gradientLayer)

        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0

        metadataLabel.font = .systemFont(ofSize: 14, weight: .medium)
        metadataLabel.textColor = UIColor.white.withAlphaComponent(0.8)

        overviewLabel.font = .systemFont(ofSize: 14)
        overviewLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        overviewLabel.numberOfLines = 3

        progressLabel.font = .systemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = UIColor.white.withAlphaComponent(0.7)

        progressBar.translatesAutoresizingMaskIntoConstraints = false

        let progressStack = UIStackView(arrangedSubviews: [progressLabel, progressBar])
        progressStack.axis = .vertical
        progressStack.spacing = 6

        overlayStack.axis = .vertical
        overlayStack.spacing = 8
        overlayStack.setCustomSpacing(12, after: overviewLabel)
        overlayStack.translatesAutoresizingMaskIntoConstraints = false
        overlayStack.addArrangedSubview(titleLabel)
        overlayStack.addArrangedSubview(metadataLabel)
        overlayStack.addArrangedSubview(overviewLabel)
        overlayStack.addArrangedSubview(progressStack)

        addSubview(backdropImageView)
        addSubview(overlayStack)

        NSLayoutConstraint.activate([
            backdropImageView.topAnchor.constraint(equalTo: topAnchor),
            backdropImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdropImageView.heightAnchor.constraint(equalTo: backdropImageView.widthAnchor, multiplier: 10.0 / 16.0),

            overlayStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            overlayStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            overlayStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])

        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = backdropImageView.bounds
    }

    private func apply() {
        guard let config = configuration as? ShowHeroConfiguration else { return }
        let show = config.show

        titleLabel.text = show.title

        var meta = [String]()
        if let rating = Formatters.rating(show.rating ?? show.audienceRating) { meta.append("★ \(rating)") }
        if let year = show.year { meta.append("\(year)") }
        let totalEps = config.seasons.reduce(0) { $0 + ($1.leafCount ?? 0) }
        meta.append("\(totalEps) episodes")
        metadataLabel.text = meta.joined(separator: " · ")

        overviewLabel.text = show.summary
        overviewLabel.isHidden = show.summary == nil

        let totalWatched = config.seasons.reduce(0) { $0 + ($1.viewedLeafCount ?? 0) }
        progressLabel.text = "\(totalWatched)/\(totalEps) watched"
        if totalEps > 0 {
            progressBar.progress = Double(totalWatched) / Double(totalEps)
        }

        let imagePath = show.art ?? show.thumb
        guard let imagePath else { return }
        guard imagePath != currentImagePath else { return }
        currentImagePath = imagePath
        imageTask?.cancel()
        let isBackdrop = show.art != nil
        imageTask = Task { [weak self] in
            let image: UIImage?
            if isBackdrop {
                image = await ImageLoader.shared.loadBackdrop(path: imagePath, width: 780)
            } else {
                image = await ImageLoader.shared.loadImage(path: imagePath, width: 500)
            }
            guard !Task.isCancelled, let self else { return }
            if let image {
                UIView.transition(with: self.backdropImageView, duration: 0.3, options: .transitionCrossDissolve) {
                    self.backdropImageView.image = image
                }
            }
        }
    }
}
