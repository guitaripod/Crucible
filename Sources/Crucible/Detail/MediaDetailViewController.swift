import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

final class MediaDetailViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case hero, actions, progress, links, tracks, overview, genres, cast, details, related
    }

    typealias Fact = DetailFact

    enum Item: Hashable {
        case hero
        case actions
        case progress
        case links
        case tracks
        case overview
        case genres
        case castMember(PlexRole)
        case fact(Fact)
        case related(PlexMetadata)
    }

    private let api: APIClient
    private let ratingKey: String
    private let mediaType: String
    private let showRatingKey: String?
    private let seasonRatingKey: String?
    private var loadTask: Task<Void, Never>?
    private var model: MovieDetailModel?
    private var selectedSubtitleId: Int?
    private var selectedAudioTrackId: Int?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var playerCoordinator: PlayerCoordinator?
    private lazy var mediaDrag = MediaDragSource { [weak self] indexPath in self?.related(at: indexPath) }
    private var downloadObserver: UUID?
    private var isOverviewExpanded = false
    private var lastLayoutWidth: CGFloat = 0
    private lazy var hero = DetailHeroCoordinator(
        navigationItem: navigationItem,
        heightRatio: mediaType == "episode" ? 0.95 : 1.28
    ) { [weak self] in self?.play() }

    init(api: APIClient, ratingKey: String, mediaType: String, showRatingKey: String? = nil, seasonRatingKey: String? = nil) {
        self.api = api
        self.ratingKey = ratingKey
        self.mediaType = mediaType
        self.showRatingKey = showRatingKey
        self.seasonRatingKey = seasonRatingKey
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.collectionViewLayout = createLayout()
        collectionView.showsVerticalScrollIndicator = false
        collectionView.allowsKeyboardFocus()
        collectionView.dragDelegate = mediaDrag
        hero.install(on: collectionView)
        navigationItem.rightBarButtonItems = [hero.chrome.playItem]
        configureDataSource()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: MediaDetailViewController, _: UITraitCollection) in
            controller.reconfigure(controller.dataSource.snapshot().itemIdentifiers)
        }
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
        loadTask?.cancel()
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
        reconfigureAfterLayout(stale)
        hero.scrolled(collectionView)
    }

    /// A layout pass can run inside a snapshot apply (the collection view lays out while it reloads, as in a window that opens on
    /// this screen), and applying again there is reentrant, so what the pass found stale is reconfigured once it is over.
    private func reconfigureAfterLayout(_ items: [Item]) {
        guard !items.isEmpty else { return }
        Task { @MainActor [weak self] in self?.reconfigure(items) }
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        hero.scrolled(collectionView)
    }

    private func handleDownloadEvent(_ event: DownloadEvent) {
        switch event {
        case .progress(let key, _, _, _) where key != ratingKey:
            return
        default:
            reconfigure([.actions])
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

    private func donateActivity(_ meta: PlexMetadata) {
        guard !DemoMode.shared.isActive else { return }
        let activity = MediaActivity.make(
            ratingKey: ratingKey,
            mediaType: mediaType,
            title: meta.title,
            subtitle: meta.grandparentTitle,
            summary: meta.summary,
            thumbPath: meta.thumb ?? meta.grandparentThumb
        )
        userActivity = activity
        activity.becomeCurrent()
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let section = self?.dataSource?.sectionIdentifier(for: sectionIndex) else { return nil }
            switch section {
            case .hero: return DetailLayout.fullWidth(top: 0, bottom: 0, environment: environment)
            case .actions: return DetailLayout.fullWidth(top: 4, environment: environment)
            case .progress: return DetailLayout.fullWidth(top: 12, environment: environment)
            case .links: return DetailLayout.fullWidth(top: 12, environment: environment)
            case .tracks: return DetailLayout.fullWidth(top: 16, environment: environment)
            case .overview: return DetailLayout.fullWidth(top: 20, environment: environment)
            case .genres: return DetailLayout.fullWidth(top: 16, environment: environment)
            case .cast: return DetailLayout.castRail(environment)
            case .details: return DetailLayout.factsGrid(environment)
            case .related: return DetailLayout.posterRail(environment)
            }
        }
    }

    private func configureDataSource() {
        let heroReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let model = self.model else { return }
            cell.contentConfiguration = self.heroConfiguration(model)
        }
        let actionsReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let model = self.model else { return }
            cell.contentConfiguration = self.actionsConfiguration(model)
        }
        let progressReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let model = self.model else { return }
            cell.contentConfiguration = Self.progressConfiguration(model)
        }
        let linksReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let model = self.model else { return }
            cell.contentConfiguration = self.linksConfiguration(model)
        }
        let tracksReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let model = self.model else { return }
            cell.contentConfiguration = self.tracksConfiguration(model)
        }
        let overviewReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let summary = self.model?.item.summary else { return }
            let lines = 4
            let width = DetailLayout.textWidth(in: self.collectionView.bounds.size)
            cell.contentConfiguration = DetailOverviewConfiguration(
                text: summary,
                collapsedLines: lines,
                isExpanded: self.isOverviewExpanded,
                isTruncatable: DetailOverviewConfiguration.needsTruncation(summary, width: width, lines: lines),
                onToggle: { [weak self] in self?.toggleOverview() }
            )
        }
        let genresReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            cell.contentConfiguration = DetailChipsConfiguration(chips: self?.model?.item.genres ?? [])
        }
        let castReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexRole> { cell, _, role in
            cell.contentConfiguration = CastContentConfiguration(thumbPath: role.thumb, name: role.tag ?? "", role: role.role)
        }
        let factReg = UICollectionView.CellRegistration<UICollectionViewCell, Fact> { cell, _, fact in
            cell.contentConfiguration = DetailFactConfiguration(key: fact.key, value: fact.value)
        }
        let relatedReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, related in
            cell.contentConfiguration = DetailLayout.posterConfiguration(for: related)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            switch item {
            case .hero: return cv.dequeueConfiguredReusableCell(using: heroReg, for: indexPath, item: item)
            case .actions: return cv.dequeueConfiguredReusableCell(using: actionsReg, for: indexPath, item: item)
            case .progress: return cv.dequeueConfiguredReusableCell(using: progressReg, for: indexPath, item: item)
            case .links: return cv.dequeueConfiguredReusableCell(using: linksReg, for: indexPath, item: item)
            case .tracks: return cv.dequeueConfiguredReusableCell(using: tracksReg, for: indexPath, item: item)
            case .overview: return cv.dequeueConfiguredReusableCell(using: overviewReg, for: indexPath, item: item)
            case .genres: return cv.dequeueConfiguredReusableCell(using: genresReg, for: indexPath, item: item)
            case .castMember(let role): return cv.dequeueConfiguredReusableCell(using: castReg, for: indexPath, item: role)
            case .fact(let fact): return cv.dequeueConfiguredReusableCell(using: factReg, for: indexPath, item: fact)
            case .related(let related): return cv.dequeueConfiguredReusableCell(using: relatedReg, for: indexPath, item: related)
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            guard let section = self?.dataSource?.sectionIdentifier(for: indexPath.section) else { return }
            var config = SectionHeaderConfiguration()
            switch section {
            case .cast: config.title = "Cast & Crew"
            case .details: config.title = "Details"
            case .related: config.title = "More Like This"
            default: break
            }
            cell.contentConfiguration = config
        }
        dataSource.supplementaryViewProvider = { cv, _, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func heroConfiguration(_ model: MovieDetailModel) -> DetailHeroConfiguration {
        let info = model.heroInfo
        return DetailHeroConfiguration(
            eyebrow: info.eyebrow,
            title: info.title,
            meta: info.meta.isEmpty ? nil : DetailFormat.metaLine(info.meta),
            badges: info.badges,
            minimumHeight: hero.minimumHeroCellHeight,
            accessibilityText: info.accessibilityText
        )
    }

    private func actionsConfiguration(_ model: MovieDetailModel) -> DetailActionsConfiguration {
        let item = model.item
        var config = DetailActionsConfiguration()
        config.primaryTitle = model.playTitle
        config.primarySymbol = "play.fill"
        config.primaryAccessibilityLabel = model.playAccessibilityLabel
        config.onPrimary = { [weak self] in self?.play() }
        config.downloadState = DetailDownload.ringState(for: ratingKey)
        config.downloadMenu = DetailDownload.menu(for: item, onPlayOffline: { [weak self] in self?.play() })
        config.onDownload = { [weak self] source in
            guard let self, let model = self.model else { return }
            DetailDownload.performTap(for: model.item, from: self, sourceView: source)
        }
        config.isWatched = item.isWatched
        config.onToggleWatched = { [weak self] in self?.toggleWatched() }
        return config
    }

    private static func progressConfiguration(_ model: MovieDetailModel) -> DetailProgressConfiguration {
        let progress = model.progress
        return DetailProgressConfiguration(
            progress: progress.fraction,
            text: progress.text,
            accessibilityText: progress.accessibilityText
        )
    }

    private func linksConfiguration(_ model: MovieDetailModel) -> DetailPillsConfiguration {
        var pills: [DetailPillsConfiguration.Pill] = []
        if model.showKey != nil {
            let showTitle = model.item.grandparentTitle
            pills.append(.init(
                title: showTitle ?? "Go to Show",
                symbol: "tv",
                accessibilityLabel: showTitle.map { "Go to show, \($0)" } ?? "Go to Show",
                action: { [weak self] in self?.navigateToShow() }
            ))
        }
        if model.seasonKey != nil {
            pills.append(.init(title: "Next Episode", symbol: "forward.end.fill", accessibilityLabel: nil, action: { [weak self] in
                self?.goToNextEpisode()
            }))
        }
        return DetailPillsConfiguration(pills: pills)
    }

    private func tracksConfiguration(_ model: MovieDetailModel) -> DetailTracksConfiguration {
        var config = DetailTracksConfiguration()
        if let value = model.audioButtonValue(selectedId: selectedAudioTrackId) {
            config.audioValue = value
            config.audioMenu = audioMenu(model.audioOptions(selectedId: selectedAudioTrackId))
        }
        if let value = model.subtitleButtonValue(selectedId: selectedSubtitleId) {
            config.subtitleValue = value
            config.subtitleMenu = subtitleMenu(model.subtitleOptions(selectedId: selectedSubtitleId))
        }
        return config
    }

    private func audioMenu(_ options: [TrackOption]) -> UIMenu {
        let actions = options.map { option in
            let action = UIAction(title: option.title, state: option.isSelected ? .on : .off) { [weak self] _ in
                Haptics.selection()
                self?.selectedAudioTrackId = option.id
                self?.reconfigure([.tracks])
            }
            action.subtitle = option.detail
            return action
        }
        return UIMenu(title: "Audio", options: .singleSelection, children: actions)
    }

    private func subtitleMenu(_ options: [TrackOption]) -> UIMenu {
        let off = UIAction(title: "Off", state: selectedSubtitleId == nil ? .on : .off) { [weak self] _ in
            Haptics.selection()
            self?.selectedSubtitleId = nil
            self?.reconfigure([.tracks])
        }
        let actions = options.map { option in
            let action = UIAction(
                title: option.title,
                attributes: option.isEnabled ? [] : .disabled,
                state: option.isSelected ? .on : .off
            ) { [weak self] _ in
                guard option.isEnabled else { return }
                Haptics.selection()
                self?.selectedSubtitleId = option.id
                self?.reconfigure([.tracks])
            }
            action.subtitle = option.detail
            return action
        }
        return UIMenu(title: "Subtitles", options: .singleSelection, children: [off] + actions)
    }

    private func loadData() {
        loadTask?.cancel()
        if model == nil {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await MovieDetailLoader.load(
                    api: api,
                    ratingKey: ratingKey,
                    showRatingKey: showRatingKey,
                    seasonRatingKey: seasonRatingKey
                )
                guard let loaded else {
                    if model == nil { showLoadError(message: DetailMessage.itemUnavailable) }
                    return
                }
                donateActivity(loaded.item)
                await display(loaded)
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Detail load failed ratingKey=\(ratingKey): \(error.localizedDescription)", category: .networking)
                if model == nil, let download = DownloadManager.shared.item(for: ratingKey) {
                    await display(MovieDetailModel(item: download.asPlexMetadata, showRatingKey: showRatingKey, seasonRatingKey: seasonRatingKey))
                } else if model == nil {
                    showLoadError(message: error.localizedDescription)
                }
            }
        }
    }

    private func display(_ model: MovieDetailModel) async {
        self.model = model
        title = model.item.title
        hero.chrome.setTitle(model.item.title)
        (tabBarController as? TabBarController)?.updateWindowTitle()
        hero.chrome.setPlay(label: model.playAccessibilityLabel, available: true)
        let tracks = model.reconciledTracks(audioId: selectedAudioTrackId, subtitleId: selectedSubtitleId)
        selectedAudioTrackId = tracks.audioId
        selectedSubtitleId = tracks.subtitleId
        let artwork = model.heroArtwork
        hero.backdrop.loadImage(
            path: artwork.path,
            isBackdrop: artwork.isBackdrop,
            offlineRatingKey: DownloadManager.shared.item(for: ratingKey) != nil ? ratingKey : nil
        )
        contentUnavailableConfiguration = nil
        await applySnapshot()
    }

    private func showLoadError(message: String) {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "exclamationmark.triangle")
        config.text = "Couldn\u{2019}t Load"
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

    private func applySnapshot() async {
        guard let model else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

        snapshot.appendSections([.hero, .actions])
        snapshot.appendItems([.hero], toSection: .hero)
        snapshot.appendItems([.actions], toSection: .actions)

        if model.hasProgress {
            snapshot.appendSections([.progress])
            snapshot.appendItems([.progress], toSection: .progress)
        }
        if model.hasLinks {
            snapshot.appendSections([.links])
            snapshot.appendItems([.links], toSection: .links)
        }
        if model.hasTracks {
            snapshot.appendSections([.tracks])
            snapshot.appendItems([.tracks], toSection: .tracks)
        }
        if model.hasSummary {
            snapshot.appendSections([.overview])
            snapshot.appendItems([.overview], toSection: .overview)
        }
        if !model.item.genres.isEmpty {
            snapshot.appendSections([.genres])
            snapshot.appendItems([.genres], toSection: .genres)
        }

        let crewAndCast = model.castAndCrew.map { Item.castMember($0) }
        if !crewAndCast.isEmpty {
            snapshot.appendSections([.cast])
            snapshot.appendItems(crewAndCast, toSection: .cast)
        }

        let factItems = model.facts.map { Item.fact($0) }
        if !factItems.isEmpty {
            snapshot.appendSections([.details])
            snapshot.appendItems(factItems, toSection: .details)
        }

        let relatedItems = model.related
        if !relatedItems.isEmpty {
            snapshot.appendSections([.related])
            snapshot.appendItems(relatedItems.map { .related($0) }, toSection: .related)
        }

        await dataSource.apply(snapshot, animatingDifferences: false)

        var refreshed = dataSource.snapshot()
        let dynamic: [Item] = [.hero, .actions, .progress, .links, .tracks, .overview, .genres]
            .filter { refreshed.indexOfItem($0) != nil }
        if !dynamic.isEmpty {
            refreshed.reconfigureItems(dynamic)
            await dataSource.apply(refreshed, animatingDifferences: false)
        }
        hero.scrolled(collectionView)
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .related = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        self.collectionView(collectionView, shouldSelectItemAt: indexPath)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .related(let related) = dataSource.itemIdentifier(for: indexPath) else { return }
        openRelated(related)
    }

    private func related(at indexPath: IndexPath) -> PlexMetadata? {
        guard case .related(let related) = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return related
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let related = related(at: indexPath),
              let open = WindowActivity.openInNewWindowAction(for: related) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let details = UIAction(title: "View Details", image: UIImage(systemName: "info.circle")) { _ in self?.openRelated(related) }
            return UIMenu(children: [details, UIMenu(options: .displayInline, children: [open])])
        })
    }

    private func openRelated(_ related: PlexMetadata) {
        navigationController?.pushViewController(DetailRouter.viewController(for: .related(related), api: api), animated: true)
    }

    private func toggleOverview() {
        isOverviewExpanded.toggle()
        reconfigure([.overview], animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func play() {
        guard let model else { return }
        let metadata = model.item
        let meta = PlayerCoordinator.Metadata(
            title: metadata.title,
            showName: metadata.grandparentTitle,
            seasonNumber: metadata.parentIndex,
            episodeNumber: metadata.index,
            posterPath: metadata.thumb ?? metadata.grandparentThumb,
            duration: metadata.durationSecs
        )
        let offlineAsset = DownloadManager.shared.offlineAsset(for: ratingKey)
        let offlineResume = offlineAsset != nil ? DownloadManager.shared.item(for: ratingKey)?.resumeSecs : nil
        let resumePosition = model.resumePosition(offlineResumeSecs: offlineResume)
        let coordinator = PlayerCoordinator(
            api: api,
            ratingKey: ratingKey,
            mediaType: mediaType,
            showRatingKey: model.showKey,
            seasonRatingKey: model.seasonKey,
            resumePosition: resumePosition,
            metadata: meta,
            selectedSubtitleId: selectedSubtitleId,
            selectedAudioStreamId: selectedAudioTrackId,
            offlineAsset: offlineAsset
        )
        self.playerCoordinator = coordinator
        coordinator.present(from: self)
    }

    private func toggleWatched() {
        guard let model else { return }
        let wasWatched = model.item.isWatched
        Task { [weak self] in
            guard let self else { return }
            do {
                try await WatchedService.setWatched(!wasWatched, ratingKey: ratingKey, api: api)
                loadData()
            } catch {
                Haptics.error()
            }
        }
    }

    private func goToNextEpisode() {
        guard let parentKey = model?.seasonKey else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let next = try await MovieDetailLoader.nextEpisode(after: ratingKey, inSeason: parentKey, api: api),
                      let route = model?.nextEpisodeRoute(next) else { return }
                navigationController?.pushViewController(DetailRouter.viewController(for: route, api: api), animated: true)
            } catch {
                MidgarLog.error("Next episode lookup failed ratingKey=\(ratingKey): \(error.localizedDescription)", category: .networking)
            }
        }
    }

    private func navigateToShow() {
        guard let route = model?.showRoute else { return }
        navigationController?.pushViewController(DetailRouter.viewController(for: route, api: api), animated: true)
    }
}

extension MediaDetailViewController: CommandHandling, MediaScreen {
    var mediaRoute: (ratingKey: String, mediaType: String) { (ratingKey, mediaType) }

    func canPerform(_ command: AppCommand) -> Bool {
        switch command {
        case .play, .toggleWatched: return model != nil
        case .download: return model.map { HomeMediaRules.isDownloadable($0.item) } ?? false
        case .refresh: return true
        default: return false
        }
    }

    func perform(_ command: AppCommand) {
        switch command {
        case .play: play()
        case .toggleWatched: toggleWatched()
        case .download:
            guard let model else { return }
            DetailDownload.performTap(for: model.item, from: self, sourceView: nil)
        case .refresh: loadData()
        default: break
        }
    }

    func title(for command: AppCommand) -> String? {
        switch command {
        case .play: return model?.playTitle
        case .toggleWatched: return model?.item.isWatched == true ? "Mark as Unwatched" : "Mark as Watched"
        case .download: return DetailDownload.commandTitle(for: ratingKey)
        default: return nil
        }
    }
}
