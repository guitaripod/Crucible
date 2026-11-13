import CrucibleCore
import CrucibleMedia
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

final class MediaDetailViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case hero, actions, progress, links, tracks, overview, genres, extras, cast, details, related
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
        case extra(PlexMetadata)
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
    /// What Trakt and the sources it collects score this title, once Trakt is connected and the title matched; the hero's
    /// meta line shows them beside Plex's own rating.
    private lazy var scores: [TraktScore] = TraktScores.shared.cached(ratingKey: ratingKey)
    private var selectedSubtitleId: Int?
    private var selectedAudioTrackId: Int?
    /// Whether the viewer picked audio or subtitles here; until then the screen shows the tracks playback would start with.
    private var tracksPicked = false
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var playerCoordinator: PlayerCoordinator?
    private lazy var mediaDrag = MediaDragSource { [weak self] indexPath in self?.related(at: indexPath) }
    private var downloadObserver: UUID?
    private var isOverviewExpanded = false
    private var lastLayoutWidth: CGFloat = 0
    private var loadedFromServer = false
    private var subtitlesBeforeSearch: Set<Int>?
    private lazy var moreItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: moreMenu())
        item.accessibilityLabel = String(localized: "More")
        return item
    }()
    private lazy var rating = RatingCoordinator(
        api: api,
        ratingKey: ratingKey,
        refresh: { [weak self] in self?.reconfigure([.actions]) },
        reload: { [weak self] in self?.loadData() }
    )
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
        navigationItem.rightBarButtonItems = [hero.chrome.playItem, moreItem]
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
            case .extras: return DetailLayout.landscapeRail(environment)
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
        let extraReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, extra in
            cell.contentConfiguration = LandscapeContentConfiguration(
                imagePath: extra.thumb,
                title: extra.title,
                subtitle: DetailExtras.kindName(extra),
                trailingText: DetailFormat.runtime(extra.durationSecs),
                showsPlayChip: true,
                placeholderIcon: "film"
            )
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
            case .extra(let extra): return cv.dequeueConfiguredReusableCell(using: extraReg, for: indexPath, item: extra)
            case .castMember(let role): return cv.dequeueConfiguredReusableCell(using: castReg, for: indexPath, item: role)
            case .fact(let fact): return cv.dequeueConfiguredReusableCell(using: factReg, for: indexPath, item: fact)
            case .related(let related): return cv.dequeueConfiguredReusableCell(using: relatedReg, for: indexPath, item: related)
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            guard let section = self?.dataSource?.sectionIdentifier(for: indexPath.section) else { return }
            var config = SectionHeaderConfiguration()
            switch section {
            case .extras: config.title = DetailExtras.title
            case .cast: config.title = String(localized: "Cast & Crew")
            case .details: config.title = String(localized: "Details")
            case .related: config.title = String(localized: "More Like This")
            default: break
            }
            cell.contentConfiguration = config
        }
        dataSource.supplementaryViewProvider = { cv, _, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func heroConfiguration(_ model: MovieDetailModel) -> DetailHeroConfiguration {
        let info = model.heroInfo(trakt: scores)
        return DetailHeroConfiguration(
            eyebrow: info.eyebrow,
            title: info.title,
            meta: info.meta.isEmpty ? nil : DetailFormat.metaLine(info.meta, traits: traitCollection),
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
        config.userRating = rating.shown(served: model.userRating)
        config.isRatable = loadedFromServer
        config.onRate = { [weak self] source in self?.rate(from: source) }
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
                title: showTitle ?? String(localized: "Go to Show"),
                symbol: "tv",
                accessibilityLabel: showTitle.map { String(localized: "Go to show, \($0)") } ?? String(localized: "Go to Show"),
                action: { [weak self] in self?.navigateToShow() }
            ))
        }
        for name in model.collectionNames {
            pills.append(.init(
                title: name,
                symbol: "rectangle.stack",
                accessibilityLabel: String(localized: "Part of the \(name) collection"),
                action: { [weak self] in self?.openCollection(named: name) }
            ))
        }
        if model.seasonKey != nil {
            pills.append(.init(title: String(localized: "Next Episode"), symbol: "forward.end.fill", accessibilityLabel: nil, action: { [weak self] in
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
                self?.tracksPicked = true
                self?.reconfigure([.tracks])
            }
            action.subtitle = option.detail
            return action
        }
        return UIMenu(title: String(localized: "Audio"), options: .singleSelection, children: actions)
    }

    private func subtitleMenu(_ options: [TrackOption]) -> UIMenu {
        let off = UIAction(title: String(localized: "Off"), state: selectedSubtitleId == nil ? .on : .off) { [weak self] _ in
            Haptics.selection()
            self?.selectedSubtitleId = nil
            self?.tracksPicked = true
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
                self?.tracksPicked = true
                self?.reconfigure([.tracks])
            }
            action.subtitle = option.detail
            return action
        }
        let search = UIAction(title: SubtitleSearch.title, image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
            self?.searchSubtitles()
        }
        let choices = UIMenu(title: "", options: [.singleSelection, .displayInline], children: [off] + actions)
        guard loadedFromServer else { return UIMenu(title: String(localized: "Subtitles"), children: [choices]) }
        return UIMenu(title: String(localized: "Subtitles"), children: [choices, UIMenu(options: .displayInline, children: [search])])
    }

    private func loadData() {
        loadTask?.cancel()
        if model == nil {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let scoresTask = startScores()
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
                loadedFromServer = true
                rating.loaded()
                let settled = await settleScores(scoresTask)
                await display(loaded)
                if !settled, let scoresTask { finishScores(scoresTask) }
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Detail load failed ratingKey=\(ratingKey): \(error.localizedDescription)", category: .networking)
                if model == nil, let download = DownloadManager.shared.item(for: ratingKey) {
                    loadedFromServer = false
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
        let remembered = model.isEpisode ? ShowTrackMemory.languages(forShow: model.showKey, server: ServerBootstrap.savedMachineIdentifier) : nil
        let tracks = model.reconciledTracks(
            audioId: selectedAudioTrackId,
            subtitleId: selectedSubtitleId,
            viewerPicked: tracksPicked,
            remembered: remembered,
            captionLanguage: SystemCaptions.alwaysOnLanguage
        )
        selectedAudioTrackId = tracks.audioId
        selectedSubtitleId = tracks.subtitleId
        selectDownloadedSubtitle(in: model)
        let artwork = model.heroArtwork
        hero.backdrop.loadImage(
            path: artwork.path,
            isBackdrop: artwork.isBackdrop,
            offlineRatingKey: DownloadManager.shared.item(for: ratingKey) != nil ? ratingKey : nil
        )
        contentUnavailableConfiguration = nil
        await applySnapshot()
    }

    /// Starts fetching Trakt's scores alongside the page, when Trakt is connected and none are cached.
    private func startScores() -> Task<[TraktScore], Never>? {
        guard TraktAccount.shared.isConnected, scores.isEmpty else { return nil }
        let ratingKey = ratingKey, api = api
        return Task { await TraktScores.shared.scores(ratingKey: ratingKey, api: api) }
    }

    /// Waits a moment after the page's own data for the scores, so the page appears in one piece. Returns whether they came.
    private func settleScores(_ task: Task<[TraktScore], Never>?) async -> Bool {
        guard let task else { return true }
        guard let found = await Settle.value(of: task, within: Settle.detailGrace) else { return false }
        scores = found
        return true
    }

    /// Scores that came after the page appeared fade into the hero's meta line instead of jumping into it.
    private func finishScores(_ task: Task<[TraktScore], Never>) {
        Task { [weak self] in
            let found = await task.value
            guard let self, found != scores else { return }
            scores = found
            easeHeroMeta()
        }
    }

    private func easeHeroMeta() {
        guard let path = dataSource.indexPath(for: .hero), let cell = collectionView.cellForItem(at: path) else {
            reconfigure([.hero])
            return
        }
        UIView.transition(with: cell, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.reconfigure([.hero])
        }
    }

    private func showLoadError(message: String) {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "exclamationmark.triangle")
        config.text = String(localized: "Couldn\u{2019}t Load")
        config.secondaryText = message
        var button = UIButton.Configuration.filled()
        button.title = String(localized: "Retry")
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

    private func applySnapshot(animated: Bool = false) async {
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

        let extraItems = model.extras.map { Item.extra($0) }
        if !extraItems.isEmpty {
            snapshot.appendSections([.extras])
            snapshot.appendItems(extraItems, toSection: .extras)
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

        await dataSource.apply(snapshot, animatingDifferences: animated)

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
        switch dataSource.itemIdentifier(for: indexPath) {
        case .related, .extra: return true
        case .castMember(let role): return PersonFilmography.canOpen(role)
        default: return false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        self.collectionView(collectionView, shouldSelectItemAt: indexPath)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .related(let related):
            openRelated(related)
        case .castMember(let role):
            navigationController?.pushViewController(PersonScreens.filmography(api: api, person: role), animated: true)
        case .extra(let extra):
            playExtra(extra)
        default:
            break
        }
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
            let details = UIAction(title: String(localized: "View Details"), image: UIImage(systemName: "info.circle")) { _ in self?.openRelated(related) }
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

    private func searchSubtitles() {
        guard let model, loadedFromServer else { return }
        subtitlesBeforeSearch = Set(model.item.subtitleStreams.compactMap(\.id))
        let search = SubtitleSearchViewController(api: api, ratingKey: ratingKey) { [weak self] in self?.loadData() }
        let navigation = UINavigationController(rootViewController: search)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
    }

    /// Once a downloaded subtitle shows up in the title's tracks it is the one selected, so the viewer's choice takes effect at once.
    private func selectDownloadedSubtitle(in model: MovieDetailModel) {
        guard let before = subtitlesBeforeSearch else { return }
        guard let added = model.item.subtitleStreams.compactMap(\.id).first(where: { !before.contains($0) }) else { return }
        subtitlesBeforeSearch = nil
        selectedSubtitleId = added
        tracksPicked = true
    }

    private func playExtra(_ extra: PlexMetadata) {
        guard let title = model?.item else { return }
        Haptics.light()
        let meta = PlayerCoordinator.Metadata(
            title: extra.title,
            showName: title.title,
            seasonNumber: nil,
            episodeNumber: nil,
            posterPath: title.thumb ?? extra.thumb,
            duration: extra.durationSecs
        )
        let coordinator = PlayerCoordinator(
            api: api,
            ratingKey: extra.id,
            mediaType: PlaybackRequest.extraMediaType,
            showRatingKey: nil,
            seasonRatingKey: nil,
            resumePosition: 0,
            metadata: meta
        )
        playerCoordinator = coordinator
        coordinator.present(from: self)
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

    private func moreMenu() -> UIMenu {
        UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, loadedFromServer, let item = model?.item, item.isPlaylistable else {
                completion([])
                return
            }
            Task { @MainActor in
                var elements: [UIMenuElement] = []
                if let share = WatchCardScreens.action(WatchCardOrigin(item: item), api: api, host: self) {
                    elements.append(UIMenu(options: .displayInline, children: [share]))
                }
                elements.append(PlaylistMenu.addMenu(for: [item], api: api, host: self))
                if let watchlist = await WatchlistScreen.toggleAction(for: item, api: api, host: self) { elements.append(watchlist) }
                if let checkIn = TraktPhoneActions.checkInAction(ratingKey: ratingKey, mediaType: mediaType, durationSecs: item.durationSecs, api: api, host: self) {
                    elements.append(checkIn)
                }
                if let manage = ManageMenus.itemMenu(for: item, api: api, host: self, reload: { [weak self] in self?.loadData() }) {
                    elements.append(manage)
                }
                completion(elements)
            }
        }])
    }

    private func openCollection(named name: String) {
        CollectionScreens.open(named: name, sectionId: model?.item.librarySectionID.map(String.init), api: api, from: self)
    }

    private func rate(from source: UIView? = nil) {
        guard let model, loadedFromServer else { return }
        rating.present(
            from: self,
            source: source ?? view,
            title: model.item.title,
            served: model.userRating
        )
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
        case .rate: return model != nil && loadedFromServer
        case .download: return model.map { HomeMediaRules.isDownloadable($0.item) } ?? false
        case .refresh: return true
        default: return false
        }
    }

    func perform(_ command: AppCommand) {
        switch command {
        case .play: play()
        case .toggleWatched: toggleWatched()
        case .rate: rate()
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
        case .toggleWatched: return model?.item.isWatched == true ? String(localized: "Mark as Unwatched") : String(localized: "Mark as Watched")
        case .download: return DetailDownload.commandTitle(for: ratingKey)
        default: return nil
        }
    }
}
