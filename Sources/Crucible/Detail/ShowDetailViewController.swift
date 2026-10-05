@preconcurrency import UIKit

final class ShowDetailViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case hero, actions, overview, seasonBar, episodes, related
    }

    enum Item: Hashable {
        case hero
        case actions
        case overview
        case seasonBar
        case episode(PlexMetadata)
        case related(PlexMetadata)
    }

    private enum UpNextKind {
        case resume, next, start
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
    private var allEpisodes: [PlexMetadata] = []
    private var upNext: (episode: PlexMetadata, kind: UpNextKind)?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var downloadObserver: UUID?
    private var pendingFullReconfigure = false
    private var isOverviewExpanded = false
    private var lastLayoutWidth: CGFloat = 0
    private var playerCoordinator: PlayerCoordinator?
    private lazy var multiSelect = MultiSelectController(collectionView: collectionView, host: self)
    private lazy var hero = DetailHeroCoordinator(navigationItem: navigationItem, heightRatio: 1.13) { [weak self] in
        self?.playUpNext()
    }

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
        collectionView.collectionViewLayout = createLayout()
        collectionView.showsVerticalScrollIndicator = false
        hero.install(on: collectionView)
        configureDataSource()
        configureMultiSelect()
        updateBarButtons()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: ShowDetailViewController, _: UITraitCollection) in
            controller.reconfigure(controller.dataSource.snapshot().itemIdentifiers)
        }
    }

    private func configureMultiSelect() {
        multiSelect.onEnter = { [weak self] in self?.updateBarButtons(); self?.reconfigureEpisodeAccessories() }
        multiSelect.onExit = { [weak self] in self?.updateBarButtons(); self?.reconfigureEpisodeAccessories() }
        multiSelect.toolbarItemsProvider = { [weak self] count in self?.selectionToolbarItems(count: count) ?? [] }
    }

    private func updateBarButtons() {
        var items: [UIBarButtonItem] = []
        if !multiSelect.isEditing { items.append(hero.chrome.playItem) }
        if multiSelect.isEditing || !episodes.isEmpty { items.append(multiSelect.barButton) }
        navigationItem.rightBarButtonItems = items
    }

    private func reconfigureEpisodeAccessories() {
        reconfigure(episodeItems())
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        var stale: [Item] = []
        if hero.refreshMinimumHeight(collectionView) { stale.append(.hero) }
        if abs(collectionView.bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = collectionView.bounds.width
            stale.append(.overview)
        }
        reconfigure(stale)
        hero.scrolled(collectionView)
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        hero.scrolled(collectionView)
    }

    /// Progress fires several times per second per active download; reconfiguring every episode cell
    /// on each tick thrashes the whole list when a season is downloading. Scope progress to the single
    /// episode that changed (plus the season ring), and only rebuild every cell on the rarer state transitions.
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
        let target = dataSource.snapshot().itemIdentifiers.filter { item in
            if case .episode(let episode) = item { return episode.ratingKey == ratingKey }
            return false
        }
        guard !target.isEmpty else { return }
        reconfigure(target + [.actions])
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
        reconfigure(episodeItems() + [.actions])
    }

    private func episodeItems() -> [Item] {
        guard dataSource != nil else { return [] }
        return dataSource.snapshot().itemIdentifiers.filter {
            if case .episode = $0 { return true }
            return false
        }
    }

    private func reconfigure(_ items: [Item], animated: Bool = false) {
        guard dataSource != nil, !items.isEmpty else { return }
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: animated)
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
            guard let self, let section = self.dataSource?.sectionIdentifier(for: sectionIndex) else { return nil }
            switch section {
            case .hero: return DetailLayout.fullWidth(top: 0)
            case .actions: return DetailLayout.fullWidth(top: 4)
            case .overview: return DetailLayout.fullWidth(top: 16)
            case .seasonBar: return DetailLayout.fullWidth(top: 20, bottom: 4)
            case .episodes: return self.episodesSection(environment)
            case .related: return DetailLayout.posterRail()
            }
        }
    }

    private func episodesSection(_ environment: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        config.backgroundColor = .clear
        #if os(iOS)
        config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.leadingSwipeActions(at: indexPath)
        }
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.trailingSwipeActions(at: indexPath)
        }
        #endif
        let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        section.contentInsets = NSDirectionalEdgeInsets(top: Theme.Space.xs, leading: 0, bottom: 0, trailing: 0)
        return section
    }

    private func configureDataSource() {
        let heroReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let show = self.show else { return }
            cell.contentConfiguration = self.heroConfiguration(show)
        }
        let actionsReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let show = self.show else { return }
            cell.contentConfiguration = self.actionsConfiguration(show)
        }
        let overviewReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let summary = self.show?.summary else { return }
            let lines = 3
            let width = self.collectionView.bounds.width - Theme.Space.m * 2
            cell.contentConfiguration = DetailOverviewConfiguration(
                text: summary,
                collapsedLines: lines,
                isExpanded: self.isOverviewExpanded,
                isTruncatable: DetailOverviewConfiguration.needsTruncation(summary, width: width, lines: lines),
                onToggle: { [weak self] in self?.toggleOverview() }
            )
        }
        let seasonBarReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.contentConfiguration = self.seasonBarConfiguration()
        }
        let episodeReg = UICollectionView.CellRegistration<UICollectionViewListCell, PlexMetadata> { [weak self] cell, _, item in
            guard let self else { return }
            let episode = self.episodes.first { $0.id == item.id } ?? item
            cell.contentConfiguration = self.episodeConfiguration(episode)
            cell.accessories = self.collectionView.isEditing ? [.multiselect(displayed: .whenEditing)] : []
            cell.configurationUpdateHandler = { cell, state in
                var background = UIBackgroundConfiguration.listPlainCell()
                background.backgroundColor = state.isHighlighted || state.isSelected ? Theme.Color.surface : Theme.Color.canvas
                cell.backgroundConfiguration = background
            }
        }
        let relatedReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, related in
            cell.contentConfiguration = DetailLayout.posterConfiguration(for: related)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            switch item {
            case .hero: return cv.dequeueConfiguredReusableCell(using: heroReg, for: indexPath, item: item)
            case .actions: return cv.dequeueConfiguredReusableCell(using: actionsReg, for: indexPath, item: item)
            case .overview: return cv.dequeueConfiguredReusableCell(using: overviewReg, for: indexPath, item: item)
            case .seasonBar: return cv.dequeueConfiguredReusableCell(using: seasonBarReg, for: indexPath, item: item)
            case .episode(let e): return cv.dequeueConfiguredReusableCell(using: episodeReg, for: indexPath, item: e)
            case .related(let r): return cv.dequeueConfiguredReusableCell(using: relatedReg, for: indexPath, item: r)
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { cell, _, _ in
            var config = SectionHeaderConfiguration()
            config.title = "More Like This"
            cell.contentConfiguration = config
        }
        dataSource.supplementaryViewProvider = { cv, _, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private var selectedSeason: PlexMetadata? {
        seasons.first { $0.id == selectedSeasonKey }
    }

    private static func seasonTitle(_ season: PlexMetadata) -> String {
        season.title.isEmpty ? "Season \(season.index ?? 0)" : season.title
    }

    private var isShowWatched: Bool {
        guard let show, let total = show.leafCount, total > 0 else { return false }
        return (show.viewedLeafCount ?? 0) >= total
    }

    private func heroConfiguration(_ show: PlexMetadata) -> DetailHeroConfiguration {
        var leading: [String] = []
        if let year = show.year { leading.append(String(year)) }
        let seasonCount = seasons.isEmpty ? (show.childCount ?? 0) : seasons.count
        if seasonCount > 0 { leading.append(seasonCount == 1 ? "1 Season" : "\(seasonCount) Seasons") }
        let rating = DetailFormat.ratingParts(audience: show.audienceRating, critic: show.rating)
        let meta = DetailFormat.metaLine(leading: leading, star: rating.star, trailing: rating.trailing)
        let sample = upNext?.episode ?? episodes.first
        let badges = DetailFormat.technicalBadges(for: sample, contentRating: show.contentRating, audio: nil)

        var spoken = [show.title, "TV show"]
        spoken.append(contentsOf: leading)
        if let ratingText = DetailFormat.spokenRating(audience: show.audienceRating, critic: show.rating) { spoken.append(ratingText) }
        spoken.append(contentsOf: badges)

        return DetailHeroConfiguration(
            eyebrow: "TV SHOW",
            title: show.title,
            meta: meta.length > 0 ? meta : nil,
            badges: badges,
            minimumHeight: hero.minimumHeroCellHeight,
            accessibilityText: spoken.joined(separator: ", ")
        )
    }

    private func primaryTitle() -> String {
        guard let upNext else { return "Play" }
        let code = DetailFormat.episodeCode(season: upNext.episode.parentIndex, episode: upNext.episode.index)
        let verb = upNext.kind == .start ? "Play" : "Continue"
        return [verb, code].compactMap { $0 }.joined(separator: " ")
    }

    private func primaryAccessibilityLabel() -> String {
        guard let upNext, let show else { return "Play" }
        let episode = upNext.episode
        let verb: String
        switch upNext.kind {
        case .start: verb = "Play"
        case .resume: verb = "Resume"
        case .next: verb = "Continue"
        }
        var parts = ["\(verb) \(show.title)"]
        if let season = episode.parentIndex, let number = episode.index { parts.append("season \(season) episode \(number)") }
        if upNext.kind == .resume, episode.durationSecs > episode.positionSecs,
           let left = DetailFormat.spokenDuration(episode.durationSecs - episode.positionSecs) {
            parts.append("\(left) left")
        }
        return parts.joined(separator: ", ")
    }

    private func actionsConfiguration(_ show: PlexMetadata) -> DetailActionsConfiguration {
        var config = DetailActionsConfiguration()
        config.primaryTitle = primaryTitle()
        config.primarySymbol = "play.fill"
        config.primaryAccessibilityLabel = primaryAccessibilityLabel()
        config.isPrimaryEnabled = upNext != nil
        config.onPrimary = { [weak self] in self?.playUpNext() }
        config.downloadState = seasonDownloadState()
        config.downloadMenu = downloadMenu()
        config.downloadMenuIsPrimary = true
        config.downloadAccessibilityLabel = downloadAccessibilityLabel()
        config.isWatched = isShowWatched
        config.watchedMenu = watchedMenu()
        config.watchedAccessibilityLabel = isShowWatched ? "Watched. Mark unwatched" : "Mark watched"
        return config
    }

    private func seasonBarConfiguration() -> DetailSeasonBarConfiguration {
        var config = DetailSeasonBarConfiguration()
        if let season = selectedSeason {
            config.seasonTitle = Self.seasonTitle(season)
            if let total = season.leafCount, total > 0 {
                config.watchedText = "\(season.viewedLeafCount ?? 0) of \(total) watched"
            }
        } else {
            config.seasonTitle = "Season"
        }
        config.menu = seasonMenu()
        return config
    }

    private func seasonMenu() -> UIMenu? {
        guard !seasons.isEmpty else { return nil }
        let actions = seasons.map { season in
            let action = UIAction(title: Self.seasonTitle(season), state: season.id == selectedSeasonKey ? .on : .off) { [weak self] _ in
                self?.selectSeason(season.id)
            }
            if let total = season.leafCount, total > 0 {
                action.subtitle = "\(season.viewedLeafCount ?? 0) of \(total) watched"
            }
            return action
        }
        return UIMenu(title: "Seasons", options: .singleSelection, children: actions)
    }

    private func episodeConfiguration(_ episode: PlexMetadata) -> EpisodeContentConfiguration {
        var config = EpisodeContentConfiguration()
        config.episodeNumber = episode.index
        config.title = episode.title
        config.summary = episode.summary
        config.thumbPath = episode.thumb
        config.durationSecs = episode.durationSecs
        config.positionSecs = episode.positionSecs
        config.isWatched = episode.isWatched
        config.isUpNext = upNext?.episode.id == episode.id
        if !episode.isWatched && episode.positionSecs > 0 && episode.durationSecs > 0 {
            config.progress = episode.positionSecs / episode.durationSecs
        }
        config.downloadState = DetailDownload.ringState(for: episode.id)
        config.showsDownloadControl = !collectionView.isEditing
        config.downloadMenu = DetailDownload.menu(for: episode, onPlayOffline: { [weak self] in self?.quickPlay(episode) })
        config.onDownloadTap = { [weak self] source in
            guard let self else { return }
            DetailDownload.performTap(for: episode, from: self, sourceView: source)
        }
        config.accessibilityActions = episodeAccessibilityActions(episode)
        return config
    }

    private func episodeAccessibilityActions(_ episode: PlexMetadata) -> [UIAccessibilityCustomAction] {
        let play = UIAccessibilityCustomAction(name: episode.positionSecs > 0 ? "Resume" : "Play") { [weak self] _ in
            self?.quickPlay(episode)
            return true
        }
        let watched = UIAccessibilityCustomAction(name: episode.isWatched ? "Mark Unwatched" : "Mark Watched") { [weak self] _ in
            self?.setWatched(!episode.isWatched, ratingKey: episode.id)
            return true
        }
        let downloadName: String
        switch DownloadManager.shared.item(for: episode.id)?.state {
        case nil: downloadName = "Download"
        case .queued?, .waitingForWiFi?: downloadName = "Cancel Download"
        case .downloading?: downloadName = "Pause Download"
        case .paused?: downloadName = "Resume Download"
        case .failed?: downloadName = "Retry Download"
        case .completed?: downloadName = "Remove Download"
        }
        let download = UIAccessibilityCustomAction(name: downloadName) { [weak self] _ in
            guard let self else { return false }
            DetailDownload.performTap(for: episode, from: self, sourceView: nil)
            return true
        }
        return [play, watched, download]
    }

    private func seasonDownloadState() -> DownloadRingButton.State {
        let manager = DownloadManager.shared
        let items = episodes.compactMap { manager.item(for: $0.id) }
        guard !episodes.isEmpty, !items.isEmpty else { return .idle }
        if items.count == episodes.count, items.allSatisfy({ $0.state == .completed }) { return .completed }
        let tracked = items.filter { $0.state != .failed }
        let done = tracked.reduce(0.0) { $0 + ($1.state == .completed ? 1 : $1.progress) }
        let fraction = tracked.isEmpty ? 0 : done / Double(tracked.count)
        if items.contains(where: { $0.state.isActive }) {
            return fraction > 0 ? .progress(fraction) : .queued
        }
        if items.contains(where: { $0.state == .failed }) { return .failed }
        if items.contains(where: { $0.state == .paused }) { return .paused(fraction) }
        return .idle
    }

    private func downloadAccessibilityLabel() -> String {
        let manager = DownloadManager.shared
        let completed = episodes.filter { manager.state(for: $0.id) == .completed }.count
        guard completed > 0 else { return "Download options" }
        return "Download options, \(completed) of \(episodes.count) episodes downloaded"
    }

    private func downloadMenu() -> UIMenu {
        let manager = DownloadManager.shared
        let seasonName = selectedSeason.map(Self.seasonTitle) ?? "Season"
        let pool = allEpisodes.isEmpty ? episodes : allEpisodes
        var downloads: [UIMenuElement] = []

        let seasonRemaining = episodes.filter { manager.item(for: $0.id) == nil }
        if !seasonRemaining.isEmpty {
            let action = UIAction(title: "Download Season", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                self?.enqueue(seasonRemaining, reason: "season")
            }
            action.subtitle = "\(seasonName) · \(Self.episodeCount(seasonRemaining.count))"
            downloads.append(action)
        }

        let unwatched = pool.filter { !$0.isWatched && manager.item(for: $0.id) == nil }
        if !unwatched.isEmpty {
            let action = UIAction(title: "Download Unwatched", image: UIImage(systemName: "eye")) { [weak self] _ in
                self?.enqueue(unwatched, reason: "unwatched")
            }
            action.subtitle = Self.episodeCount(unwatched.count)
            downloads.append(action)
        }

        if let upNext, let start = pool.firstIndex(where: { $0.id == upNext.episode.id }) {
            let next = Array(pool[start...].prefix(5)).filter { manager.item(for: $0.id) == nil }
            if !next.isEmpty {
                let action = UIAction(title: "Download Next 5", image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
                    self?.enqueue(next, reason: "next5")
                }
                action.subtitle = DetailFormat.episodeCode(season: upNext.episode.parentIndex, episode: upNext.episode.index)
                    .map { "From \($0)" }
                downloads.append(action)
            }
        }

        downloads.append(UIAction(title: "Options\u{2026}", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
            self?.presentDownloadOptions()
        })

        var manage: [UIMenuElement] = []
        let seasonItems = episodes.compactMap { manager.item(for: $0.id) }
        let activeKeys = seasonItems.filter { $0.state.isActive }.map(\.ratingKey)
        if !activeKeys.isEmpty {
            manage.append(UIAction(title: "Pause Season Downloads", image: UIImage(systemName: "pause.fill")) { _ in
                activeKeys.forEach { manager.pause($0) }
            })
        }
        let resumable = episodes.filter { manager.state(for: $0.id) == .failed || manager.state(for: $0.id) == .paused }
        if !resumable.isEmpty {
            manage.append(UIAction(title: "Resume Season Downloads", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.enqueue(resumable, reason: "resume")
            })
        }
        if !seasonItems.isEmpty {
            let title = activeKeys.isEmpty ? "Remove Season Downloads" : "Cancel Season Downloads"
            manage.append(UIAction(title: title, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.removeSeasonDownloads()
            })
        }

        var children: [UIMenuElement] = [UIMenu(title: "", options: .displayInline, children: downloads)]
        if !manage.isEmpty { children.append(UIMenu(title: "", options: .displayInline, children: manage)) }
        return UIMenu(title: "", children: children)
    }

    private static func episodeCount(_ count: Int) -> String {
        count == 1 ? "1 episode" : "\(count) episodes"
    }

    private func enqueue(_ items: [PlexMetadata], reason: String) {
        Haptics.medium()
        let added = DownloadManager.shared.enqueueAll(items)
        AppLogger.notice("Show download (\(reason)) queued \(added) episodes", .persistence)
    }

    private func removeSeasonDownloads() {
        let keys = episodes.map(\.id).filter { DownloadManager.shared.item(for: $0) != nil }
        guard !keys.isEmpty else { return }
        Haptics.medium()
        DownloadManager.shared.deleteItems(keys)
    }

    private func presentDownloadOptions() {
        guard let show else { return }
        let context = DownloadOptionsSheetViewController.Context(
            showRatingKey: showRatingKey,
            showTitle: show.title,
            seasonTitle: selectedSeason.map(Self.seasonTitle) ?? "",
            posterPath: show.thumb,
            episodes: episodes
        )
        let sheet = DownloadOptionsSheetViewController(context: context) { [weak self] in
            guard let presented = self?.presentedViewController as? DownloadOptionsSheetViewController else { return }
            presented.dismiss(animated: true)
        }
        sheet.modalPresentationStyle = .pageSheet
        if let controller = sheet.sheetPresentationController {
            controller.detents = [.medium(), .large()]
            controller.prefersGrabberVisible = true
        }
        present(sheet, animated: true)
    }

    private func watchedMenu() -> UIMenu {
        var showActions: [UIMenuElement] = []
        if !isShowWatched {
            showActions.append(UIAction(title: "Mark Show Watched", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                guard let self else { return }
                self.setWatched(true, ratingKey: self.showRatingKey)
            })
        }
        if (show?.viewedLeafCount ?? 0) > 0 {
            showActions.append(UIAction(title: "Mark Show Unwatched", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
                guard let self else { return }
                self.setWatched(false, ratingKey: self.showRatingKey)
            })
        }
        var children: [UIMenuElement] = [UIMenu(title: "", options: .displayInline, children: showActions)]
        if let season = selectedSeason {
            let name = Self.seasonTitle(season)
            let viewed = season.viewedLeafCount ?? 0
            let total = season.leafCount ?? 0
            var seasonActions: [UIMenuElement] = []
            if total == 0 || viewed < total {
                seasonActions.append(UIAction(title: "Mark \(name) Watched", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                    self?.setWatched(true, ratingKey: season.id)
                })
            }
            if viewed > 0 {
                seasonActions.append(UIAction(title: "Mark \(name) Unwatched", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
                    self?.setWatched(false, ratingKey: season.id)
                })
            }
            if !seasonActions.isEmpty {
                children.append(UIMenu(title: "", options: .displayInline, children: seasonActions))
            }
        }
        return UIMenu(title: "", children: children)
    }

    private func setWatched(_ watched: Bool, ratingKey: String) {
        Haptics.light()
        Task { [weak self] in
            guard let self else { return }
            do {
                if watched {
                    try await api.requestVoid(.scrobble(ratingKey: ratingKey))
                } else {
                    try await api.requestVoid(.unscrobble(ratingKey: ratingKey))
                }
                await api.invalidateCache()
                loadData()
            } catch {
                AppLogger.error("Mark watched=\(watched) failed ratingKey=\(ratingKey): \(error.localizedDescription)", .networking)
                Haptics.error()
            }
        }
    }

    private func loadData() {
        loadTask?.cancel()
        if show == nil {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        }
        let api = self.api
        let leavesPath = "/library/metadata/\(showRatingKey)/allLeaves"
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let showContainer = try await api.requestContainer(.metadata(ratingKey: showRatingKey))
                guard !Task.isCancelled else { return }
                guard let showMeta = showContainer.Metadata?.first else {
                    if show == nil { showLoadError(message: "This show is no longer available on the server.") }
                    return
                }
                show = showMeta
                title = showMeta.title
                hero.chrome.setTitle(showMeta.title)
                hero.backdrop.loadImage(path: showMeta.art ?? showMeta.thumb, isBackdrop: showMeta.art != nil, offlineRatingKey: nil)
                donateActivity(showMeta)

                async let leaves = try? api.requestContainer(.folderPath(leavesPath))
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
                let leafEpisodes = (await leaves)?.Metadata?.filter { $0.mediaType == "episode" } ?? []
                guard !Task.isCancelled else { return }
                allEpisodes = leafEpisodes
                contentUnavailableConfiguration = nil
                await applySnapshot()
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("Show load failed ratingKey=\(showRatingKey): \(error.localizedDescription)", .networking)
                if show == nil {
                    showLoadError(message: error.localizedDescription)
                } else {
                    contentUnavailableConfiguration = nil
                    await applySnapshot()
                }
            }
        }
    }

    private func showLoadError(message: String) {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "exclamationmark.triangle")
        config.text = "Failed to load"
        config.secondaryText = message
        var button = UIButton.Configuration.filled()
        button.title = "Retry"
        button.baseBackgroundColor = Theme.Color.accent
        button.baseForegroundColor = Theme.Color.onAccent
        button.cornerStyle = .capsule
        config.button = button
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in
            self?.contentUnavailableConfiguration = nil
            self?.loadData()
        }
        contentUnavailableConfiguration = config
    }

    private func loadSeason(_ seasonKey: String) async {
        do {
            let container = try await api.requestContainer(.children(ratingKey: seasonKey))
            guard !Task.isCancelled else { return }
            episodes = container.Metadata ?? []
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.error("Season load failed ratingKey=\(seasonKey): \(error.localizedDescription)", .networking)
            episodes = []
        }
    }

    /// The episode the primary button plays: an in-progress episode first, then the first unwatched
    /// episode after the last watched one, otherwise the very first episode.
    private static func computeUpNext(in episodes: [PlexMetadata]) -> (episode: PlexMetadata, kind: UpNextKind)? {
        guard let first = episodes.first else { return nil }
        if let inProgress = episodes.first(where: { !$0.isWatched && $0.positionSecs > 0 }) {
            return (inProgress, .resume)
        }
        guard let lastWatched = episodes.lastIndex(where: \.isWatched) else { return (first, .start) }
        if let next = episodes[(lastWatched + 1)...].first(where: { !$0.isWatched }) ?? episodes.first(where: { !$0.isWatched }) {
            return (next, .next)
        }
        return (first, .start)
    }

    private func applySnapshot() async {
        guard let show else { return }
        upNext = Self.computeUpNext(in: allEpisodes.isEmpty ? episodes : allEpisodes)

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.hero, .actions])
        snapshot.appendItems([.hero], toSection: .hero)
        snapshot.appendItems([.actions], toSection: .actions)

        if let summary = show.summary, !summary.isEmpty {
            snapshot.appendSections([.overview])
            snapshot.appendItems([.overview], toSection: .overview)
        }
        if !seasons.isEmpty {
            snapshot.appendSections([.seasonBar])
            snapshot.appendItems([.seasonBar], toSection: .seasonBar)
        }
        snapshot.appendSections([.episodes])
        snapshot.appendItems(episodes.map { .episode($0) }, toSection: .episodes)

        var seenRelated = Set<String>()
        let related = show.relatedHubs
            .flatMap { $0.Metadata ?? [] }
            .filter { $0.id != showRatingKey && seenRelated.insert($0.id).inserted }
            .prefix(18)
        if !related.isEmpty {
            snapshot.appendSections([.related])
            snapshot.appendItems(related.map { .related($0) }, toSection: .related)
        }

        await dataSource.apply(snapshot, animatingDifferences: false)

        var refreshed = dataSource.snapshot()
        let dynamic = refreshed.itemIdentifiers.filter { item in
            switch item {
            case .hero, .actions, .overview, .seasonBar, .episode: return true
            case .related: return false
            }
        }
        if !dynamic.isEmpty {
            refreshed.reconfigureItems(dynamic)
            await dataSource.apply(refreshed, animatingDifferences: false)
        }
        hero.chrome.setPlay(label: primaryAccessibilityLabel(), available: upNext != nil)
        updateBarButtons()
        hero.scrolled(collectionView)
    }

    private func selectSeason(_ key: String) {
        guard selectedSeasonKey != key else { return }
        Haptics.selection()
        multiSelect.setEditing(false)
        selectedSeasonKey = key
        reconfigure([.seasonBar])
        seasonTask?.cancel()
        seasonTask = Task { [weak self] in
            guard let self else { return }
            await loadSeason(key)
            guard !Task.isCancelled else { return }
            await applySnapshot()
        }
    }

    private func episode(at indexPath: IndexPath) -> PlexMetadata? {
        guard case .episode(let item) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return episodes.first { $0.id == item.id } ?? item
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView.isEditing { multiSelect.selectionChanged(); return }
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .episode(let episode):
            let detail = MediaDetailViewController(
                api: api,
                ratingKey: episode.id,
                mediaType: "episode",
                showRatingKey: showRatingKey,
                seasonRatingKey: selectedSeasonKey
            )
            navigationController?.pushViewController(detail, animated: true)
        case .related(let related):
            openRelated(related)
        default:
            break
        }
    }

    private func openRelated(_ related: PlexMetadata) {
        if related.mediaType == "show" {
            navigationController?.pushViewController(ShowDetailViewController(api: api, showRatingKey: related.id), animated: true)
        } else {
            let vc = MediaDetailViewController(
                api: api,
                ratingKey: related.id,
                mediaType: related.mediaType,
                showRatingKey: related.grandparentRatingKey,
                seasonRatingKey: related.parentRatingKey
            )
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        if collectionView.isEditing { multiSelect.selectionChanged() }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .episode: return true
        case .related: return !collectionView.isEditing
        default: return false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        if case .episode = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        multiSelect.setEditing(true)
    }

    private func toggleOverview() {
        isOverviewExpanded.toggle()
        reconfigure([.overview], animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func playUpNext() {
        guard let episode = upNext?.episode else { return }
        quickPlay(episode)
    }

    private func quickPlay(_ item: PlexMetadata) {
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }

    private func playFromBeginning(_ episode: PlexMetadata) {
        let meta = PlayerCoordinator.Metadata(
            title: episode.title,
            showName: episode.grandparentTitle,
            seasonNumber: episode.parentIndex,
            episodeNumber: episode.index,
            posterPath: episode.thumb ?? episode.grandparentThumb,
            duration: episode.durationSecs
        )
        let coordinator = PlayerCoordinator(
            api: api,
            ratingKey: episode.id,
            mediaType: episode.mediaType,
            showRatingKey: episode.grandparentRatingKey ?? showRatingKey,
            seasonRatingKey: episode.parentRatingKey,
            resumePosition: 0,
            metadata: meta,
            offlineAsset: DownloadManager.shared.offlineAsset(for: episode.id)
        )
        playerCoordinator = coordinator
        coordinator.present(from: self)
    }

    #if os(iOS)
    private func leadingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !collectionView.isEditing, let episode = episode(at: indexPath) else { return nil }
        let markWatched = !episode.isWatched
        let action = UIContextualAction(style: .normal, title: nil) { [weak self] _, _, completion in
            self?.setWatched(markWatched, ratingKey: episode.id)
            completion(true)
        }
        action.backgroundColor = Theme.Color.accent
        action.image = SwipeActionArt.image(
            symbol: markWatched ? "eye" : "eye.slash",
            title: markWatched ? "Watched" : "Unwatched",
            spokenTitle: markWatched ? "Mark Watched" : "Mark Unwatched",
            color: Theme.Color.onAccent,
            traits: traitCollection
        )
        return UISwipeActionsConfiguration(actions: [action])
    }

    private func trailingSwipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !collectionView.isEditing, let episode = episode(at: indexPath) else { return nil }
        let key = episode.id
        let manager = DownloadManager.shared
        let traits = traitCollection
        let sourceView = collectionView.cellForItem(at: indexPath)

        func graphite(_ symbol: String, _ title: String, _ spoken: String, handler: @escaping () -> Void) -> UIContextualAction {
            let action = UIContextualAction(style: .normal, title: nil) { _, _, completion in
                Haptics.medium()
                handler()
                completion(true)
            }
            action.backgroundColor = Theme.Color.surfaceHigh
            action.image = SwipeActionArt.image(symbol: symbol, title: title, spokenTitle: spoken, color: Theme.Color.label, traits: traits)
            return action
        }

        func destructive(_ title: String, _ spoken: String, handler: @escaping () -> Void) -> UIContextualAction {
            let action = UIContextualAction(style: .normal, title: nil) { _, _, completion in
                handler()
                completion(true)
            }
            action.backgroundColor = Theme.Color.destructive
            action.image = SwipeActionArt.image(symbol: "trash", title: title, spokenTitle: spoken, color: Theme.Color.onArt, traits: traits)
            return action
        }

        let configuration: UISwipeActionsConfiguration
        switch manager.item(for: key)?.state {
        case nil:
            configuration = UISwipeActionsConfiguration(actions: [
                graphite("arrow.down", "Download", "Download") { manager.enqueue(metadata: episode) },
            ])
        case .completed?:
            configuration = UISwipeActionsConfiguration(actions: [
                destructive("Remove", "Remove Download") { [weak self] in
                    guard let self else { return }
                    DetailDownload.confirmRemoval(title: episode.title, ratingKey: key, from: self, sourceView: sourceView)
                },
            ])
        case .queued?, .waitingForWiFi?, .downloading?:
            configuration = UISwipeActionsConfiguration(actions: [
                destructive("Cancel", "Cancel Download") { Haptics.medium(); manager.delete(key) },
                graphite("pause.fill", "Pause", "Pause Download") { manager.pause(key) },
            ])
            configuration.performsFirstActionWithFullSwipe = false
        case .paused?:
            configuration = UISwipeActionsConfiguration(actions: [
                destructive("Delete", "Delete Download") { Haptics.medium(); manager.delete(key) },
                graphite("arrow.down", "Resume", "Resume Download") { manager.resume(key) },
            ])
            configuration.performsFirstActionWithFullSwipe = false
        case .failed?:
            configuration = UISwipeActionsConfiguration(actions: [
                destructive("Delete", "Delete Download") { Haptics.medium(); manager.delete(key) },
                graphite("arrow.clockwise", "Retry", "Retry Download") { manager.retry(key) },
            ])
            configuration.performsFirstActionWithFullSwipe = false
        }
        return configuration
    }
    #endif

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
        removeItem.tintColor = Theme.Color.destructive
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
        Haptics.medium()
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

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !collectionView.isEditing, let indexPath = indexPaths.first, let episode = episode(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            var children: [UIMenuElement] = [
                UIAction(title: episode.positionSecs > 0 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                    Haptics.light()
                    self?.quickPlay(episode)
                },
                DownloadMenu.action(for: episode),
                UIAction(
                    title: episode.isWatched ? "Mark Unwatched" : "Mark Watched",
                    image: UIImage(systemName: episode.isWatched ? "eye.slash" : "eye")
                ) { [weak self] _ in
                    self?.setWatched(!episode.isWatched, ratingKey: episode.id)
                },
            ]
            if episode.positionSecs > 0 {
                children.insert(UIAction(title: "Play from Beginning", image: UIImage(systemName: "gobackward")) { [weak self] _ in
                    Haptics.light()
                    self?.playFromBeginning(episode)
                }, at: 1)
            }
            return UIMenu(children: children)
        })
    }
}

/// Renders a swipe action's glyph and caption into one image so the caption can use the
/// on-accent or label colour (UIKit always draws contextual action titles in white).
@MainActor
enum SwipeActionArt {
    static func image(symbol: String, title: String, spokenTitle: String, color: UIColor, traits: UITraitCollection) -> UIImage? {
        let resolved = color.resolvedColor(with: traits)
        let font = UIFont.systemFont(ofSize: 12, weight: .bold)
        let glyph = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))?
            .withTintColor(resolved, renderingMode: .alwaysOriginal)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: resolved]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let glyphSize = glyph?.size ?? .zero
        let width = ceil(max(textSize.width, glyphSize.width, 24))
        let spacing: CGFloat = 4
        let height = ceil(glyphSize.height + spacing + textSize.height)
        let format = UIGraphicsImageRendererFormat(for: traits)
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { _ in
            glyph?.draw(in: CGRect(x: (width - glyphSize.width) / 2, y: 0, width: glyphSize.width, height: glyphSize.height))
            (title as NSString).draw(at: CGPoint(x: (width - textSize.width) / 2, y: glyphSize.height + spacing), withAttributes: attributes)
        }
        let result = image.withRenderingMode(.alwaysOriginal)
        result.accessibilityLabel = spokenTitle
        return result
    }
}
