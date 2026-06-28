@preconcurrency import UIKit

final class MediaDetailViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case hero, info, cast, subtitles, audioTracks, actions, related
    }

    enum Item: Hashable {
        case hero
        case overview(String)
        case genres([String])
        case techInfo(String)
        case castMember(PlexRole)
        case subtitle(PlexStream)
        case subtitleNone
        case audioTrack(PlexStream)
        case action(String)
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
        navigationItem.largeTitleDisplayMode = .never
        collectionView.collectionViewLayout = createLayout()
        configureDataSource()
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

    private func handleDownloadEvent(_ event: DownloadEvent) {
        switch event {
        case .progress(let key, _, _, _) where key != ratingKey:
            return
        default:
            reconfigureDownloadAction()
        }
    }

    private func reconfigureDownloadAction() {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.action("download")) else { return }
        snapshot.reconfigureItems([.action("download")])
        dataSource.apply(snapshot, animatingDifferences: false)
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
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let section = self?.dataSource?.sectionIdentifier(for: sectionIndex) else { return nil }

            switch section {
            case .hero:
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(400)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(400)), subitems: [item])
                return NSCollectionLayoutSection(group: group)

            case .info, .actions:
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)), subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
                layoutSection.interGroupSpacing = 8
                return layoutSection

            case .subtitles, .audioTracks:
                var listConfig = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                listConfig.headerMode = .supplementary
                return NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: environment)

            case .cast:
                let size = NSCollectionLayoutSize(widthDimension: .absolute(84), heightDimension: .absolute(132))
                let item = NSCollectionLayoutItem(layoutSize: size)
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.orthogonalScrollingBehavior = .continuous
                layoutSection.interGroupSpacing = 14
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16)
                layoutSection.boundarySupplementaryItems = [Self.sectionHeader()]
                return layoutSection

            case .related:
                let size = NSCollectionLayoutSize(widthDimension: .absolute(120), heightDimension: .absolute(210))
                let item = NSCollectionLayoutItem(layoutSize: size)
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.orthogonalScrollingBehavior = .continuous
                layoutSection.interGroupSpacing = 12
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 24, trailing: 16)
                layoutSection.boundarySupplementaryItems = [Self.sectionHeader()]
                return layoutSection
            }
        }
    }

    private static func sectionHeader() -> NSCollectionLayoutBoundarySupplementaryItem {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(40))
        return NSCollectionLayoutBoundarySupplementaryItem(layoutSize: size, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    private func configureDataSource() {
        let heroCellReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [unowned self] cell, _, _ in
            guard let metadata = self.metadata else { return }
            cell.contentConfiguration = HeroContentConfiguration(
                metadata: metadata,
                onPlay: { [weak self] in self?.play() },
                onShowTap: metadata.mediaType == "episode" && (self.showRatingKey ?? metadata.grandparentRatingKey) != nil ? { [weak self] in self?.navigateToShow() } : nil
            )
        }

        let textCellReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, text in
            var config = UIListContentConfiguration.cell()
            config.text = text
            config.textProperties.numberOfLines = 0
            config.textProperties.font = .systemFont(ofSize: 15)
            config.textProperties.color = .secondaryLabel
            cell.contentConfiguration = config
        }

        let genreCellReg = UICollectionView.CellRegistration<UICollectionViewCell, [String]> { cell, _, genres in
            var config = UIListContentConfiguration.cell()
            config.text = genres.joined(separator: " · ")
            config.textProperties.font = .systemFont(ofSize: 13)
            config.textProperties.color = .tertiaryLabel
            cell.contentConfiguration = config
        }

        let subtitleCellReg = UICollectionView.CellRegistration<UICollectionViewListCell, PlexStream> { [unowned self] cell, _, stream in
            var config = UIListContentConfiguration.subtitleCell()
            config.text = stream.displayTitle ?? stream.language ?? "Unknown"
            var details = [String]()
            if let codec = stream.codec { details.append(codec) }
            if stream.forced == true { details.append("Forced") }
            if stream.isDefault == true { details.append("Default") }
            if stream.isBitmap { details.append("Image-based") }
            config.secondaryText = details.joined(separator: " · ")
            if stream.isBitmap {
                config.textProperties.color = .tertiaryLabel
                config.secondaryTextProperties.color = .tertiaryLabel
            }
            cell.contentConfiguration = config
            if !stream.isBitmap {
                cell.accessories = self.selectedSubtitleId == stream.id ? [.checkmark(options: .init(tintColor: .systemOrange))] : []
            } else {
                cell.accessories = []
            }
        }

        let subtitleNoneReg = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [unowned self] cell, _, _ in
            var config = UIListContentConfiguration.cell()
            config.text = "None"
            cell.contentConfiguration = config
            cell.accessories = self.selectedSubtitleId == nil ? [.checkmark(options: .init(tintColor: .systemOrange))] : []
        }

        let audioCellReg = UICollectionView.CellRegistration<UICollectionViewListCell, PlexStream> { [unowned self] cell, _, stream in
            var config = UIListContentConfiguration.subtitleCell()
            config.text = stream.displayTitle ?? stream.language ?? "Track \(stream.id)"
            var details = [String]()
            if let codec = stream.codec { details.append(codec.uppercased()) }
            details.append(stream.channelDescription)
            if let bitrate = stream.bitrate {
                details.append("\(bitrate) kbps")
            }
            config.secondaryText = details.joined(separator: " · ")
            cell.contentConfiguration = config
            cell.accessories = self.selectedAudioTrackId == stream.id ? [.checkmark(options: .init(tintColor: .systemOrange))] : []
        }

        let actionCellReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [unowned self] cell, _, action in
            if action == "download" {
                self.configureDownloadCell(cell)
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
            case "watched":
                let watched = self.metadata?.isWatched == true
                buttonConfig.title = watched ? "Mark Unwatched" : "Mark Watched"
                buttonConfig.image = UIImage(systemName: watched ? "eye.slash" : "eye")
            case "next":
                buttonConfig.title = "Next Episode"
                buttonConfig.image = UIImage(systemName: "forward.fill")
            default: break
            }
            buttonConfig.imagePadding = 10
            let button = UIButton(configuration: buttonConfig)
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                switch action {
                case "watched": self.toggleWatched()
                case "next": self.goToNextEpisode()
                default: break
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

        let castCellReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexRole> { cell, _, role in
            cell.contentConfiguration = CastContentConfiguration(
                thumbPath: role.thumb,
                name: role.tag ?? "",
                role: role.role
            )
        }

        let relatedCellReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, related in
            cell.contentConfiguration = PosterContentConfiguration(
                posterPath: related.posterPath ?? related.grandparentThumb,
                title: related.title,
                subtitle: related.year.map(String.init),
                progress: related.progressPercent > 0 ? related.progressPercent : nil,
                placeholderIcon: related.mediaType == "show" ? "tv" : "film"
            )
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            switch item {
            case .hero:
                return cv.dequeueConfiguredReusableCell(using: heroCellReg, for: indexPath, item: "hero")
            case .overview(let text):
                return cv.dequeueConfiguredReusableCell(using: textCellReg, for: indexPath, item: text)
            case .genres(let genres):
                return cv.dequeueConfiguredReusableCell(using: genreCellReg, for: indexPath, item: genres)
            case .techInfo(let info):
                return cv.dequeueConfiguredReusableCell(using: textCellReg, for: indexPath, item: info)
            case .castMember(let role):
                return cv.dequeueConfiguredReusableCell(using: castCellReg, for: indexPath, item: role)
            case .subtitle(let sub):
                return cv.dequeueConfiguredReusableCell(using: subtitleCellReg, for: indexPath, item: sub)
            case .subtitleNone:
                return cv.dequeueConfiguredReusableCell(using: subtitleNoneReg, for: indexPath, item: "none")
            case .audioTrack(let track):
                return cv.dequeueConfiguredReusableCell(using: audioCellReg, for: indexPath, item: track)
            case .action(let action):
                return cv.dequeueConfiguredReusableCell(using: actionCellReg, for: indexPath, item: action)
            case .related(let related):
                return cv.dequeueConfiguredReusableCell(using: relatedCellReg, for: indexPath, item: related)
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            guard let section = self?.dataSource?.sectionIdentifier(for: indexPath.section) else { return }
            var config = SectionHeaderConfiguration()
            switch section {
            case .subtitles: config.title = "Subtitles"
            case .audioTracks: config.title = "Audio"
            case .cast: config.title = "Cast & Crew"
            case .related: config.title = "More Like This"
            default: break
            }
            cell.contentConfiguration = config
        }
        dataSource.supplementaryViewProvider = { cv, kind, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func loadData() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.metadata(ratingKey: ratingKey))
                guard !Task.isCancelled, let meta = container.Metadata?.first else { return }
                self.metadata = meta
                self.title = meta.title
                donateActivity(meta)

                let audioStreams = meta.audioStreams
                if let defaultAudio = audioStreams.first(where: { $0.isDefault == true }) {
                    selectedAudioTrackId = defaultAudio.id
                } else if let first = audioStreams.first {
                    selectedAudioTrackId = first.id
                }

                await applySnapshot()
            } catch {
                guard !Task.isCancelled else { return }
                if metadata == nil, let download = DownloadManager.shared.item(for: ratingKey) {
                    let meta = download.asPlexMetadata
                    self.metadata = meta
                    self.title = meta.title
                    await applySnapshot()
                }
            }
        }
    }

    private func applySnapshot() async {
        guard let metadata else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

        snapshot.appendSections([.hero])
        snapshot.appendItems([.hero], toSection: .hero)

        snapshot.appendSections([.info])
        if let overview = metadata.summary, !overview.isEmpty {
            snapshot.appendItems([.overview(overview)], toSection: .info)
        }
        let genres = metadata.genres
        if !genres.isEmpty {
            snapshot.appendItems([.genres(genres)], toSection: .info)
        }
        var techParts = [String]()
        if let vc = metadata.videoCodec { techParts.append(vc.uppercased()) }
        if let ac = metadata.audioCodec { techParts.append(ac.uppercased()) }
        if let size = metadata.fileSize { techParts.append(Formatters.fileSize(size)) }
        if let channels = metadata.audioChannels {
            techParts.append(Formatters.channelDescription(channels))
        }
        if !techParts.isEmpty {
            snapshot.appendItems([.techInfo(techParts.joined(separator: " · "))], toSection: .info)
        }

        let crew = metadata.directors.prefix(2).map { PlexRole(id: nil, tag: $0, role: "Director", thumb: nil) }
            + metadata.writers.prefix(2).map { PlexRole(id: nil, tag: $0, role: "Writer", thumb: nil) }
        var seenCast = Set<PlexRole>()
        let crewAndCast = (crew + metadata.cast.prefix(20))
            .filter { seenCast.insert($0).inserted }
            .map { Item.castMember($0) }
        if !crewAndCast.isEmpty {
            snapshot.appendSections([.cast])
            snapshot.appendItems(crewAndCast, toSection: .cast)
        }

        let subtitles = metadata.subtitleStreams
        if !subtitles.isEmpty {
            snapshot.appendSections([.subtitles])
            snapshot.appendItems([.subtitleNone], toSection: .subtitles)
            snapshot.appendItems(subtitles.map { .subtitle($0) }, toSection: .subtitles)
        }

        let audioTracks = metadata.audioStreams
        if !audioTracks.isEmpty {
            snapshot.appendSections([.audioTracks])
            snapshot.appendItems(audioTracks.map { .audioTrack($0) }, toSection: .audioTracks)
        }

        snapshot.appendSections([.actions])
        snapshot.appendItems([.action("download"), .action("watched")], toSection: .actions)
        if metadata.mediaType == "episode" {
            snapshot.appendItems([.action("next")], toSection: .actions)
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
        let dynamic = refreshed.itemIdentifiers.filter { item in
            switch item {
            case .hero, .action: return true
            default: return false
            }
        }
        if !dynamic.isEmpty {
            refreshed.reconfigureItems(dynamic)
            await dataSource.apply(refreshed, animatingDifferences: false)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .subtitle(let sub):
            guard !sub.isBitmap else { return }
            selectedSubtitleId = sub.id
            reconfigureTrackSections()
        case .subtitleNone:
            selectedSubtitleId = nil
            reconfigureTrackSections()
        case .audioTrack(let track):
            selectedAudioTrackId = track.id
            reconfigureTrackSections()
        case .related(let related):
            openRelated(related)
        default:
            break
        }
    }

    private func openRelated(_ related: PlexMetadata) {
        let type = related.mediaType
        if type == "show" {
            let vc = ShowDetailViewController(api: api, showRatingKey: related.id)
            navigationController?.pushViewController(vc, animated: true)
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

    private func reconfigureTrackSections() {
        var snapshot = dataSource.snapshot()
        let items = snapshot.itemIdentifiers.filter { item in
            switch item {
            case .subtitle, .subtitleNone, .audioTrack: return true
            default: return false
            }
        }
        snapshot.reconfigureItems(items)
        Task { await dataSource.apply(snapshot, animatingDifferences: false) }
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

    private func configureDownloadCell(_ cell: UICollectionViewCell) {
        let item = DownloadManager.shared.item(for: ratingKey)
        var config = Glass.glassButton {
            var c = UIButton.Configuration.tinted()
            c.baseBackgroundColor = .systemOrange.withAlphaComponent(0.15)
            c.baseForegroundColor = .systemOrange
            return c
        }
        config.cornerStyle = .large
        config.imagePadding = 10
        config.titlePadding = 2

        let menu: UIMenu

        switch item?.state {
        case .none:
            config.title = "Download"
            config.image = UIImage(systemName: "arrow.down.circle")
            menu = qualityMenu()
        case .queued:
            config.title = "Queued"
            config.subtitle = item?.quality.shortLabel
            config.showsActivityIndicator = true
            menu = activeMenu()
        case .waitingForWiFi:
            config.title = "Waiting for Wi-Fi"
            config.image = UIImage(systemName: "wifi.slash")
            menu = activeMenu()
        case .downloading:
            config.title = "Downloading"
            config.subtitle = item.map { "\($0.percentText) · \($0.quality.shortLabel)" }
            config.image = UIImage(systemName: "stop.circle")
            menu = activeMenu()
        case .paused:
            let pct = Int(((item?.progress ?? 0) * 100).rounded())
            config.title = "Paused · \(pct)%"
            config.subtitle = "Tap for options"
            config.image = UIImage(systemName: "play.circle")
            menu = pausedMenu()
        case .failed:
            config.baseForegroundColor = .systemRed
            config.title = "Download Failed"
            config.subtitle = item?.errorMessage ?? "Tap to retry"
            config.image = UIImage(systemName: "exclamationmark.triangle")
            menu = failedMenu()
        case .completed:
            config.baseForegroundColor = .systemGreen
            config.title = "Downloaded"
            config.subtitle = item?.statusLine
            config.image = UIImage(systemName: "checkmark.circle.fill")
            menu = completedMenu()
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
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    private func qualityMenu() -> UIMenu {
        let current = Preferences.downloadQuality
        let actions = DownloadQuality.allCases.map { quality in
            UIAction(title: "\(quality.title) · \(quality.detail)", state: quality == current ? .on : .off) { [weak self] _ in
                self?.startDownload(quality: quality)
            }
        }
        return UIMenu(title: "Download Quality", children: actions)
    }

    private func activeMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Pause", image: UIImage(systemName: "pause.fill")) { [weak self] _ in
                guard let self else { return }
                DownloadManager.shared.pause(self.ratingKey)
            },
            UIAction(title: "Cancel Download", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                DownloadManager.shared.delete(self.ratingKey)
            },
        ])
    }

    private func pausedMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Resume", image: UIImage(systemName: "arrow.down.to.line")) { [weak self] _ in
                guard let self else { return }
                DownloadManager.shared.resume(self.ratingKey)
            },
            UIAction(title: "Remove Download", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                DownloadManager.shared.delete(self.ratingKey)
            },
        ])
    }

    private func failedMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Retry", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                guard let self else { return }
                DownloadManager.shared.retry(self.ratingKey)
            },
            UIAction(title: "Remove Download", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                DownloadManager.shared.delete(self.ratingKey)
            },
        ])
    }

    private func completedMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Play Offline", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                self?.play()
            },
            UIAction(title: "Delete Download", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                guard let self else { return }
                DownloadManager.shared.delete(self.ratingKey)
            },
        ])
    }

    private func startDownload(quality: DownloadQuality) {
        guard let metadata else { return }
        DownloadManager.shared.enqueue(metadata: metadata, quality: quality)
    }

    private func toggleWatched() {
        guard let metadata else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                if metadata.isWatched {
                    try await api.requestVoid(.unscrobble(ratingKey: ratingKey))
                } else {
                    try await api.requestVoid(.scrobble(ratingKey: ratingKey))
                }
                await api.invalidateCache()
                loadData()
            } catch {}
        }
    }

    private func goToNextEpisode() {
        let parentKey = seasonRatingKey ?? metadata?.parentRatingKey
        guard let parentKey else { return }
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
                    showRatingKey: showRatingKey ?? metadata?.grandparentRatingKey,
                    seasonRatingKey: parentKey
                )
                navigationController?.pushViewController(vc, animated: true)
            } catch {}
        }
    }

    private func navigateToShow() {
        let key = showRatingKey ?? metadata?.grandparentRatingKey
        guard let key else { return }
        let seasonKey = seasonRatingKey ?? metadata?.parentRatingKey
        let vc = ShowDetailViewController(api: api, showRatingKey: key, initialSeasonKey: seasonKey)
        navigationController?.pushViewController(vc, animated: true)
    }
}

struct HeroContentConfiguration: UIContentConfiguration, Hashable {
    let metadata: PlexMetadata
    var onPlay: (() -> Void)?
    var onShowTap: (() -> Void)?

    static func == (lhs: HeroContentConfiguration, rhs: HeroContentConfiguration) -> Bool {
        lhs.metadata.id == rhs.metadata.id && lhs.metadata.viewOffset == rhs.metadata.viewOffset
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(metadata.id)
        hasher.combine(metadata.viewOffset)
    }

    func makeContentView() -> UIView & UIContentView {
        HeroContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> HeroContentConfiguration {
        self
    }
}

final class HeroContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private var currentImagePath: String?

    private let backdropImageView = UIImageView()
    private let gradientLayer = CAGradientLayer()
    private let overlayStack = UIStackView()
    private let titleLabel = UILabel()
    private let metadataStack = UIStackView()
    private let badgeStack = UIStackView()
    private let playButton = UIButton(configuration: .filled())
    private var episodeButton = UIButton(configuration: .plain())
    private var imageTask: Task<Void, Never>?
    private var onPlay: (() -> Void)?
    private var onShowTap: (() -> Void)?

    init(configuration: HeroContentConfiguration) {
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

        metadataStack.axis = .horizontal
        metadataStack.spacing = 12

        badgeStack.axis = .horizontal
        badgeStack.spacing = 6

        playButton.addAction(UIAction { [unowned self] _ in
            self.onPlay?()
        }, for: .touchUpInside)

        var showConfig = UIButton.Configuration.plain()
        showConfig.contentInsets = .zero
        showConfig.baseForegroundColor = .systemOrange
        episodeButton = UIButton(configuration: showConfig)
        episodeButton.contentHorizontalAlignment = .leading
        episodeButton.addAction(UIAction { [unowned self] _ in
            self.onShowTap?()
        }, for: .touchUpInside)

        overlayStack.axis = .vertical
        overlayStack.spacing = 8
        overlayStack.setCustomSpacing(12, after: badgeStack)
        overlayStack.alignment = .leading
        overlayStack.translatesAutoresizingMaskIntoConstraints = false
        overlayStack.addArrangedSubview(titleLabel)
        overlayStack.addArrangedSubview(metadataStack)
        overlayStack.addArrangedSubview(badgeStack)
        overlayStack.addArrangedSubview(playButton)
        overlayStack.addArrangedSubview(episodeButton)

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

            playButton.heightAnchor.constraint(equalToConstant: 50),
            playButton.widthAnchor.constraint(equalTo: overlayStack.widthAnchor),
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
        guard let config = configuration as? HeroContentConfiguration else { return }
        let item = config.metadata
        onPlay = config.onPlay
        onShowTap = config.onShowTap

        titleLabel.text = item.title

        metadataStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let year = item.year {
            metadataStack.addArrangedSubview(makeMetaLabel("\(year)"))
        }
        if let rating = Formatters.rating(item.rating ?? item.audienceRating) {
            let label = makeMetaLabel("★ \(rating)")
            label.textColor = .systemYellow
            metadataStack.addArrangedSubview(label)
        }
        metadataStack.addArrangedSubview(makeMetaLabel(Formatters.duration(item.durationSecs)))

        badgeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let res = Formatters.resolution(item.videoWidth, item.videoHeight) {
            badgeStack.addArrangedSubview(makeBadge(res))
        }
        if let profile = item.Media?.first?.videoProfile, profile.lowercased().contains("10") {
            badgeStack.addArrangedSubview(makeBadge("HDR"))
        }
        if let codec = item.videoCodec {
            badgeStack.addArrangedSubview(makeBadge(codec.uppercased()))
        }

        var playConfig = Glass.prominentButton {
            var config = UIButton.Configuration.filled()
            config.baseBackgroundColor = .systemOrange
            config.baseForegroundColor = .white
            return config
        }
        playConfig.image = UIImage(systemName: "play.fill")
        playConfig.imagePadding = 10
        playConfig.cornerStyle = .large
        if item.positionSecs > 0 {
            playConfig.title = "Resume from \(Formatters.timestamp(item.positionSecs))"
        } else {
            playConfig.title = "Play"
        }
        playButton.configuration = playConfig

        if item.mediaType == "episode" {
            episodeButton.isHidden = false
            var parts = [String]()
            if let code = Formatters.episodeCode(item.parentIndex, item.index) { parts.append(code) }
            if let show = item.grandparentTitle { parts.append(show) }
            var btnConfig = episodeButton.configuration ?? .plain()
            btnConfig.title = parts.joined(separator: " — ")
            btnConfig.baseForegroundColor = .systemOrange
            episodeButton.configuration = btnConfig
            episodeButton.isEnabled = config.onShowTap != nil
        } else {
            episodeButton.isHidden = true
        }

        let imagePath = item.art ?? item.thumb
        guard let imagePath, !imagePath.isEmpty else { return }
        guard imagePath != currentImagePath else { return }
        currentImagePath = imagePath

        imageTask?.cancel()
        let isBackdrop = item.art != nil
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

    private func makeMetaLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.8)
        return label
    }

    private func makeBadge(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.9)
        label.translatesAutoresizingMaskIntoConstraints = false

        let container: UIView
        let host: UIView
        if #available(iOS 26.0, tvOS 26.0, *) {
            let effectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            effectView.cornerConfiguration = .corners(radius: .containerConcentric())
            container = effectView
            host = effectView.contentView
        } else {
            let view = UIView()
            view.backgroundColor = UIColor.white.withAlphaComponent(0.15)
            view.layer.cornerRadius = 4
            view.layer.cornerCurve = .continuous
            view.layer.borderWidth = 0.5
            view.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
            container = view
            host = view
        }
        container.clipsToBounds = true
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
        ])
        return container
    }
}
