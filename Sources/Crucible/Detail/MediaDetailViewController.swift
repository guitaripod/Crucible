@preconcurrency import UIKit

final class MediaDetailViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case hero, actions, progress, links, tracks, overview, genres, cast, details, related
    }

    struct Fact: Hashable {
        let key: String
        let value: String
    }

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
    private var metadata: PlexMetadata?
    private var selectedSubtitleId: Int?
    private var selectedAudioTrackId: Int?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var playerCoordinator: PlayerCoordinator?
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
        reconfigure(stale)
        hero.scrolled(collectionView)
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
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
            guard let section = self?.dataSource?.sectionIdentifier(for: sectionIndex) else { return nil }
            switch section {
            case .hero: return DetailLayout.fullWidth(top: 0, bottom: 0)
            case .actions: return DetailLayout.fullWidth(top: 4)
            case .progress: return DetailLayout.fullWidth(top: 12)
            case .links: return DetailLayout.fullWidth(top: 12)
            case .tracks: return DetailLayout.fullWidth(top: 16)
            case .overview: return DetailLayout.fullWidth(top: 20)
            case .genres: return DetailLayout.fullWidth(top: 16)
            case .cast: return DetailLayout.castRail()
            case .details: return DetailLayout.factsGrid()
            case .related: return DetailLayout.posterRail()
            }
        }
    }

    private func configureDataSource() {
        let heroReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let metadata = self.metadata else { return }
            cell.contentConfiguration = self.heroConfiguration(metadata)
        }
        let actionsReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let metadata = self.metadata else { return }
            cell.contentConfiguration = self.actionsConfiguration(metadata)
        }
        let progressReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let metadata = self.metadata else { return }
            cell.contentConfiguration = Self.progressConfiguration(metadata)
        }
        let linksReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let metadata = self.metadata else { return }
            cell.contentConfiguration = self.linksConfiguration(metadata)
        }
        let tracksReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let metadata = self.metadata else { return }
            cell.contentConfiguration = self.tracksConfiguration(metadata)
        }
        let overviewReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let summary = self.metadata?.summary else { return }
            let lines = 4
            let width = self.collectionView.bounds.width - Theme.Space.m * 2
            cell.contentConfiguration = DetailOverviewConfiguration(
                text: summary,
                collapsedLines: lines,
                isExpanded: self.isOverviewExpanded,
                isTruncatable: DetailOverviewConfiguration.needsTruncation(summary, width: width, lines: lines),
                onToggle: { [weak self] in self?.toggleOverview() }
            )
        }
        let genresReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            cell.contentConfiguration = DetailChipsConfiguration(chips: self?.metadata?.genres ?? [])
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

    private func heroConfiguration(_ item: PlexMetadata) -> DetailHeroConfiguration {
        let eyebrow: String
        switch item.mediaType {
        case "episode":
            eyebrow = ["EPISODE", DetailFormat.episodeCode(season: item.parentIndex, episode: item.index)]
                .compactMap { $0 }
                .joined(separator: " · ")
        case "movie": eyebrow = "MOVIE"
        default: eyebrow = item.mediaType == "unknown" ? "" : item.mediaType.uppercased()
        }

        let dateText: String? = item.mediaType == "episode"
            ? (Formatters.plexDate(item.originallyAvailableAt) ?? item.year.map(String.init))
            : item.year.map(String.init)
        var leading: [String] = dateText.map { [$0] } ?? []
        if let runtime = DetailFormat.runtime(item.durationSecs) { leading.append(runtime) }
        let rating = DetailFormat.ratingParts(audience: item.audienceRating, critic: item.rating)
        let meta = DetailFormat.metaLine(leading: leading, star: rating.star, trailing: rating.trailing)

        let audio = DetailFormat.primaryAudioStream(item)
        let badges = DetailFormat.technicalBadges(for: item, contentRating: item.contentRating, audio: audio)

        var spoken = [item.title]
        if item.mediaType == "episode" {
            if let show = item.grandparentTitle { spoken.append(show) }
            if let season = item.parentIndex, let episode = item.index { spoken.append("season \(season) episode \(episode)") }
        } else if !eyebrow.isEmpty {
            spoken.append(eyebrow.lowercased())
        }
        if let dateText { spoken.append(dateText) }
        if let duration = DetailFormat.spokenDuration(item.durationSecs) { spoken.append(duration) }
        if let ratingText = DetailFormat.spokenRating(audience: item.audienceRating, critic: item.rating) { spoken.append(ratingText) }
        spoken.append(contentsOf: badges)

        return DetailHeroConfiguration(
            eyebrow: eyebrow,
            title: item.title,
            meta: meta.length > 0 ? meta : nil,
            badges: badges,
            minimumHeight: hero.minimumHeroCellHeight,
            accessibilityText: spoken.joined(separator: ", ")
        )
    }

    private func actionsConfiguration(_ item: PlexMetadata) -> DetailActionsConfiguration {
        let resumes = item.positionSecs > 0
        var config = DetailActionsConfiguration()
        config.primaryTitle = resumes ? "Resume" : "Play"
        config.primarySymbol = "play.fill"
        config.primaryAccessibilityLabel = playAccessibilityLabel(item)
        config.onPrimary = { [weak self] in self?.play() }
        config.downloadState = DetailDownload.ringState(for: ratingKey)
        config.downloadMenu = DetailDownload.menu(for: item, onPlayOffline: { [weak self] in self?.play() })
        config.onDownload = { [weak self] source in
            guard let self, let metadata = self.metadata else { return }
            DetailDownload.performTap(for: metadata, from: self, sourceView: source)
        }
        config.isWatched = item.isWatched
        config.onToggleWatched = { [weak self] in self?.toggleWatched() }
        return config
    }

    private func playAccessibilityLabel(_ item: PlexMetadata) -> String {
        guard item.positionSecs > 0 else { return "Play \(item.title)" }
        if let left = DetailFormat.spokenDuration(item.durationSecs - item.positionSecs), item.durationSecs > item.positionSecs {
            return "Resume \(item.title), \(left) left"
        }
        return "Resume \(item.title)"
    }

    private static func hasProgress(_ item: PlexMetadata) -> Bool {
        item.positionSecs > 0 && item.durationSecs > item.positionSecs
    }

    private static func progressConfiguration(_ item: PlexMetadata) -> DetailProgressConfiguration {
        let fraction = item.durationSecs > 0 ? item.positionSecs / item.durationSecs : 0
        let text = DetailFormat.remaining(position: item.positionSecs, duration: item.durationSecs) ?? ""
        let spokenLeft = DetailFormat.spokenDuration(item.durationSecs - item.positionSecs).map { "\($0) left" } ?? ""
        return DetailProgressConfiguration(
            progress: fraction,
            text: text,
            accessibilityText: "\(Int((fraction * 100).rounded())) percent watched, \(spokenLeft)"
        )
    }

    private var showKey: String? { showRatingKey ?? metadata?.grandparentRatingKey }
    private var seasonKey: String? { seasonRatingKey ?? metadata?.parentRatingKey }

    private func linksConfiguration(_ item: PlexMetadata) -> DetailPillsConfiguration {
        var pills: [DetailPillsConfiguration.Pill] = []
        if showKey != nil {
            let showTitle = item.grandparentTitle
            pills.append(.init(
                title: showTitle ?? "Go to Show",
                symbol: "tv",
                accessibilityLabel: showTitle.map { "Go to show, \($0)" } ?? "Go to Show",
                action: { [weak self] in self?.navigateToShow() }
            ))
        }
        if seasonKey != nil {
            pills.append(.init(title: "Next Episode", symbol: "forward.end.fill", accessibilityLabel: nil, action: { [weak self] in
                self?.goToNextEpisode()
            }))
        }
        return DetailPillsConfiguration(pills: pills)
    }

    private func tracksConfiguration(_ item: PlexMetadata) -> DetailTracksConfiguration {
        var config = DetailTracksConfiguration()
        let audio = item.audioStreams
        if !audio.isEmpty {
            let selected = DetailFormat.primaryAudioStream(item, selectedId: selectedAudioTrackId)
            config.audioValue = selected.map(DetailFormat.audioValue) ?? "Default"
            config.audioMenu = audioMenu(audio)
        }
        let subtitles = item.subtitleStreams
        if !subtitles.isEmpty {
            let selected = subtitles.first { $0.id != nil && $0.id == selectedSubtitleId }
            config.subtitleValue = selected.map(DetailFormat.subtitleValue) ?? "Off"
            config.subtitleMenu = subtitleMenu(subtitles)
        }
        return config
    }

    private func audioMenu(_ streams: [PlexStream]) -> UIMenu {
        let actions = streams.map { stream in
            let action = UIAction(title: stream.displayTitle ?? DetailFormat.languageName(stream), state: stream.id == selectedAudioTrackId ? .on : .off) { [weak self] _ in
                Haptics.selection()
                self?.selectedAudioTrackId = stream.id
                self?.reconfigure([.tracks])
            }
            let detail = DetailFormat.audioDetail(stream)
            action.subtitle = detail.isEmpty ? nil : detail
            return action
        }
        return UIMenu(title: "Audio", options: .singleSelection, children: actions)
    }

    private func subtitleMenu(_ streams: [PlexStream]) -> UIMenu {
        let off = UIAction(title: "Off", state: selectedSubtitleId == nil ? .on : .off) { [weak self] _ in
            Haptics.selection()
            self?.selectedSubtitleId = nil
            self?.reconfigure([.tracks])
        }
        let actions = streams.map { stream in
            let action = UIAction(
                title: stream.displayTitle ?? DetailFormat.languageName(stream),
                attributes: stream.isBitmap ? .disabled : [],
                state: !stream.isBitmap && stream.id != nil && stream.id == selectedSubtitleId ? .on : .off
            ) { [weak self] _ in
                guard !stream.isBitmap else { return }
                Haptics.selection()
                self?.selectedSubtitleId = stream.id
                self?.reconfigure([.tracks])
            }
            let detail = DetailFormat.subtitleDetail(stream)
            action.subtitle = detail.isEmpty ? nil : detail
            return action
        }
        return UIMenu(title: "Subtitles", options: .singleSelection, children: [off] + actions)
    }

    private func facts(_ item: PlexMetadata) -> [Fact] {
        var facts: [Fact] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            facts.append(Fact(key: key, value: value))
        }
        let directors = item.directors.prefix(2)
        add(directors.count > 1 ? "Directors" : "Director", directors.isEmpty ? nil : directors.joined(separator: ", "))
        let writers = item.writers.prefix(2)
        add(writers.count > 1 ? "Writers" : "Writer", writers.isEmpty ? nil : writers.joined(separator: ", "))
        add("Studio", item.studio)
        if item.mediaType == "episode" {
            add("Aired", Formatters.plexDate(item.originallyAvailableAt))
        }
        add("Added", DetailFormat.addedDate(item.addedAt))
        add("File", DetailFormat.fileFact(item))
        add("Audio", DetailFormat.audioFact(DetailFormat.primaryAudioStream(item)))
        return facts
    }

    private func loadData() {
        loadTask?.cancel()
        if metadata == nil {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.metadata(ratingKey: ratingKey))
                guard !Task.isCancelled else { return }
                guard let meta = container.Metadata?.first else {
                    if metadata == nil { showLoadError(message: "This item is no longer available on the server.") }
                    return
                }
                donateActivity(meta)
                await display(meta)
            } catch {
                guard !Task.isCancelled else { return }
                AppLogger.error("Detail load failed ratingKey=\(ratingKey): \(error.localizedDescription)", .networking)
                if metadata == nil, let download = DownloadManager.shared.item(for: ratingKey) {
                    await display(download.asPlexMetadata)
                } else if metadata == nil {
                    showLoadError(message: error.localizedDescription)
                }
            }
        }
    }

    private func display(_ meta: PlexMetadata) async {
        metadata = meta
        title = meta.title
        hero.chrome.setTitle(meta.title)
        hero.chrome.setPlay(label: playAccessibilityLabel(meta), available: true)
        let audioStreams = meta.audioStreams
        if selectedAudioTrackId == nil || !audioStreams.contains(where: { $0.id == selectedAudioTrackId }) {
            selectedAudioTrackId = (audioStreams.first(where: { $0.isDefault == true }) ?? audioStreams.first)?.id
        }
        if let selectedSubtitleId, !meta.subtitleStreams.contains(where: { $0.id == selectedSubtitleId }) {
            self.selectedSubtitleId = nil
        }
        let isBackdrop = meta.mediaType == "episode" ? meta.thumb != nil || meta.art != nil : meta.art != nil
        let path = meta.mediaType == "episode" ? (meta.thumb ?? meta.art ?? meta.grandparentArt) : (meta.art ?? meta.thumb)
        hero.backdrop.loadImage(
            path: path,
            isBackdrop: isBackdrop,
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

    /// Directors and writers as cast-rail entries; a person who does both appears once with both roles.
    private static func crew(for metadata: PlexMetadata) -> [PlexRole] {
        var order = [String]()
        var roles = [String: [String]]()
        for (name, role) in metadata.directors.prefix(2).map({ ($0, "Director") }) + metadata.writers.prefix(2).map({ ($0, "Writer") }) {
            if roles[name] == nil { order.append(name) }
            roles[name, default: []].append(role)
        }
        return order.map { PlexRole(id: nil, tag: $0, role: roles[$0]?.joined(separator: ", "), thumb: nil) }
    }

    private func applySnapshot() async {
        guard let metadata else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

        snapshot.appendSections([.hero, .actions])
        snapshot.appendItems([.hero], toSection: .hero)
        snapshot.appendItems([.actions], toSection: .actions)

        if Self.hasProgress(metadata) {
            snapshot.appendSections([.progress])
            snapshot.appendItems([.progress], toSection: .progress)
        }
        if metadata.mediaType == "episode", showKey != nil || seasonKey != nil {
            snapshot.appendSections([.links])
            snapshot.appendItems([.links], toSection: .links)
        }
        if !metadata.audioStreams.isEmpty || !metadata.subtitleStreams.isEmpty {
            snapshot.appendSections([.tracks])
            snapshot.appendItems([.tracks], toSection: .tracks)
        }
        if let summary = metadata.summary, !summary.isEmpty {
            snapshot.appendSections([.overview])
            snapshot.appendItems([.overview], toSection: .overview)
        }
        if !metadata.genres.isEmpty {
            snapshot.appendSections([.genres])
            snapshot.appendItems([.genres], toSection: .genres)
        }

        var seenCast = Set<PlexRole>()
        let crewAndCast = (Self.crew(for: metadata) + metadata.cast.prefix(20))
            .filter { seenCast.insert($0).inserted }
            .map { Item.castMember($0) }
        if !crewAndCast.isEmpty {
            snapshot.appendSections([.cast])
            snapshot.appendItems(crewAndCast, toSection: .cast)
        }

        var seenFacts = Set<Fact>()
        let factItems = facts(metadata).filter { seenFacts.insert($0).inserted }.map { Item.fact($0) }
        if !factItems.isEmpty {
            snapshot.appendSections([.details])
            snapshot.appendItems(factItems, toSection: .details)
        }

        var seenRelated = Set<String>()
        let relatedItems = metadata.relatedHubs
            .flatMap { $0.Metadata ?? [] }
            .filter { $0.id != ratingKey && seenRelated.insert($0.id).inserted }
            .prefix(18)
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

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .related(let related) = dataSource.itemIdentifier(for: indexPath) else { return }
        openRelated(related)
    }

    private func openRelated(_ related: PlexMetadata) {
        let type = related.mediaType
        if type == "show" {
            navigationController?.pushViewController(ShowDetailViewController(api: api, showRatingKey: related.id), animated: true)
        } else {
            let vc = MediaDetailViewController(
                api: api,
                ratingKey: related.id,
                mediaType: type,
                showRatingKey: related.grandparentRatingKey,
                seasonRatingKey: related.parentRatingKey
            )
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    private func toggleOverview() {
        isOverviewExpanded.toggle()
        reconfigure([.overview], animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func play() {
        guard let metadata else { return }
        let meta = PlayerCoordinator.Metadata(
            title: metadata.title,
            showName: metadata.grandparentTitle,
            seasonNumber: metadata.parentIndex,
            episodeNumber: metadata.index,
            posterPath: metadata.thumb ?? metadata.grandparentThumb,
            duration: metadata.durationSecs
        )
        let offlineAsset = DownloadManager.shared.offlineAsset(for: ratingKey)
        let resumePosition = offlineAsset != nil
            ? (DownloadManager.shared.item(for: ratingKey)?.resumeSecs ?? metadata.positionSecs)
            : metadata.positionSecs
        let coordinator = PlayerCoordinator(
            api: api,
            ratingKey: ratingKey,
            mediaType: mediaType,
            showRatingKey: showRatingKey ?? metadata.grandparentRatingKey,
            seasonRatingKey: seasonRatingKey ?? metadata.parentRatingKey,
            resumePosition: resumePosition,
            metadata: meta,
            selectedSubtitleId: selectedSubtitleId,
            selectedAudioStreamId: selectedAudioTrackId,
            offlineAsset: offlineAsset
        )
        coordinator.onAdvanceToNext = { [weak self] next in self?.playerCoordinator = next }
        self.playerCoordinator = coordinator
        coordinator.present(from: self)
    }

    private func toggleWatched() {
        guard let metadata else { return }
        let wasWatched = metadata.isWatched
        Task { [weak self] in
            guard let self else { return }
            do {
                if wasWatched {
                    try await api.requestVoid(.unscrobble(ratingKey: ratingKey))
                } else {
                    try await api.requestVoid(.scrobble(ratingKey: ratingKey))
                }
                await api.invalidateCache()
                loadData()
            } catch {
                AppLogger.error("Toggle watched failed ratingKey=\(ratingKey): \(error.localizedDescription)", .networking)
                Haptics.error()
            }
        }
    }

    private func goToNextEpisode() {
        guard let parentKey = seasonKey else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.children(ratingKey: parentKey))
                let episodes = container.Metadata ?? []
                guard let currentIndex = episodes.firstIndex(where: { $0.id == ratingKey }),
                      currentIndex + 1 < episodes.count else { return }
                let next = episodes[currentIndex + 1]
                let vc = MediaDetailViewController(
                    api: api,
                    ratingKey: next.id,
                    mediaType: "episode",
                    showRatingKey: showKey,
                    seasonRatingKey: parentKey
                )
                navigationController?.pushViewController(vc, animated: true)
            } catch {
                AppLogger.error("Next episode lookup failed ratingKey=\(ratingKey): \(error.localizedDescription)", .networking)
            }
        }
    }

    private func navigateToShow() {
        guard let key = showKey else { return }
        let vc = ShowDetailViewController(api: api, showRatingKey: key, initialSeasonKey: seasonKey)
        navigationController?.pushViewController(vc, animated: true)
    }
}
