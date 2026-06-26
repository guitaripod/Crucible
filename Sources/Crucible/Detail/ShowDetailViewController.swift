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
    private var loadTask: Task<Void, Never>?
    private var seasonTask: Task<Void, Never>?
    private var show: PlexMetadata?
    private var seasons: [PlexMetadata] = []
    private var selectedSeasonKey: String?
    private var episodes: [PlexMetadata] = []
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(api: APIClient, showRatingKey: String) {
        self.api = api
        self.showRatingKey = showRatingKey
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
        loadData()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        seasonTask?.cancel()
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { sectionIndex, environment in
            guard let section = Section(rawValue: sectionIndex) else { return nil }

            switch section {
            case .hero:
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(300)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(300)), subitems: [item])
                return NSCollectionLayoutSection(group: group)

            case .seasonPicker:
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .estimated(80), heightDimension: .absolute(36)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .estimated(80), heightDimension: .absolute(36)), subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.orthogonalScrollingBehavior = .continuous
                layoutSection.interGroupSpacing = 8
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
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
            config.title = "Season \(season.index ?? 0)"
            config.cornerStyle = .capsule
            config.buttonSize = .small
            button.configuration = config
        }

        let episodeReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, episode in
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
            cell.contentConfiguration = config
        }

        let actionReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [unowned self] cell, _, action in
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

                let seasonsContainer = try await api.requestContainer(.children(ratingKey: showRatingKey))
                guard !Task.isCancelled else { return }
                seasons = (seasonsContainer.Metadata ?? []).filter { $0.mediaType == "season" }

                let firstUnwatched = seasons.first {
                    let watched = $0.viewedLeafCount ?? 0
                    let total = $0.leafCount ?? 0
                    return watched < total
                }
                selectedSeasonKey = firstUnwatched?.id ?? seasons.first?.id

                if let selectedSeasonKey {
                    await loadSeason(selectedSeasonKey)
                }
                await applySnapshot()
            } catch {
                guard !Task.isCancelled else { return }
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
        snapshot.appendItems([.action("watchAll"), .action("unwatchAll")], toSection: .actions)

        await dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .season(let season):
            selectedSeasonKey = season.id
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

    private var playerCoordinator: PlayerCoordinator?

    private func quickPlay(_ item: PlexMetadata) {
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
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
        didSet {
            imageTask?.cancel()
            apply()
        }
    }

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
        overlayStack.spacing = 6
        overlayStack.setCustomSpacing(10, after: overviewLabel)
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
