@preconcurrency import UIKit

final class ShowDetailViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case hero, seasonPicker, episodes, actions
    }

    enum Item: Hashable {
        case hero
        case season(SeasonSummary)
        case episode(EpisodeSummary)
        case action(String)
    }

    private let api: APIClient
    private let showId: String
    private var loadTask: Task<Void, Never>?
    private var seasonTask: Task<Void, Never>?
    private var show: TvShow?
    private var seasons: [SeasonSummary] = []
    private var selectedSeason: Int?
    private var episodes: [EpisodeSummary] = []
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(api: APIClient, showId: String) {
        self.api = api
        self.showId = showId
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
            cell.contentConfiguration = ShowHeroConfiguration(show: show, seasons: self.seasons, baseURL: self.api.baseURL)
        }

        let seasonReg = UICollectionView.CellRegistration<UICollectionViewCell, SeasonSummary> { [unowned self] cell, _, season in
            var config = UIButton.Configuration.gray()
            config.title = "Season \(season.seasonNumber)"
            config.cornerStyle = .capsule
            config.buttonSize = .small
            if self.selectedSeason == season.seasonNumber {
                config.baseBackgroundColor = .systemBlue
                config.baseForegroundColor = .white
            }
            let button = UIButton(configuration: config)
            button.isUserInteractionEnabled = false
            button.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            cell.contentView.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                button.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                button.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
            ])
        }

        let episodeReg = UICollectionView.CellRegistration<UICollectionViewCell, EpisodeSummary> { cell, _, episode in
            var config = EpisodeContentConfiguration()
            config.episodeNumber = episode.episodeNumber
            config.title = episode.episodeTitle ?? "Episode \(episode.episodeNumber ?? 0)"
            config.duration = Formatters.duration(episode.durationSecs)
            config.isWatched = episode.isWatched
            if !episode.isWatched && episode.positionSecs > 0, let dur = episode.durationSecs, dur > 0 {
                config.progress = episode.positionSecs / dur
            }
            cell.contentConfiguration = config
        }

        let actionReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [unowned self] cell, _, action in
            var buttonConfig = UIButton.Configuration.tinted()
            buttonConfig.cornerStyle = .medium
            switch action {
            case "watchAll":
                buttonConfig.title = "Mark All Watched"
                buttonConfig.image = UIImage(systemName: "checkmark.circle")
            case "unwatchAll":
                buttonConfig.title = "Mark All Unwatched"
                buttonConfig.image = UIImage(systemName: "circle")
            default: break
            }
            buttonConfig.imagePadding = 8
            let button = UIButton(configuration: buttonConfig)
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                Task {
                    switch action {
                    case "watchAll": try? await self.api.requestVoid(.markShowWatched(showId: self.showId))
                    case "unwatchAll": try? await self.api.requestVoid(.markShowUnwatched(showId: self.showId))
                    default: break
                    }
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
                let response: ShowDetailResponse = try await api.request(.getShow(id: showId))
                guard !Task.isCancelled else { return }
                show = response.show
                seasons = response.seasons
                title = response.show.name

                let firstUnwatched = response.seasons.first { $0.watchedCount < $0.episodeCount }
                selectedSeason = firstUnwatched?.seasonNumber ?? response.seasons.first?.seasonNumber

                if let selectedSeason {
                    await loadSeason(selectedSeason)
                }
                await applySnapshot()
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    private func loadSeason(_ seasonNumber: Int) async {
        do {
            let eps: [EpisodeSummary] = try await api.request(.getSeasonEpisodes(showId: showId, season: seasonNumber))
            guard !Task.isCancelled else { return }
            episodes = eps
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
            selectedSeason = season.seasonNumber
            seasonTask?.cancel()
            seasonTask = Task { [weak self] in
                guard let self else { return }
                await loadSeason(season.seasonNumber)
                guard !Task.isCancelled else { return }
                await applySnapshot()
            }
        case .episode(let episode):
            let detail = MediaDetailViewController(api: api, mediaId: episode.id, mediaType: "episode", showId: showId)
            navigationController?.pushViewController(detail, animated: true)
        default:
            break
        }
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath),
              case .season(let season) = item else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: "Mark Season Watched", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                    guard let self else { return }
                    Task {
                        try? await self.api.requestVoid(.markSeasonWatched(showId: self.showId, season: season.seasonNumber))
                        self.loadData()
                    }
                },
                UIAction(title: "Mark Season Unwatched", image: UIImage(systemName: "circle")) { [weak self] _ in
                    guard let self else { return }
                    Task {
                        try? await self.api.requestVoid(.markSeasonUnwatched(showId: self.showId, season: season.seasonNumber))
                        self.loadData()
                    }
                },
            ])
        })
    }
}

struct ShowHeroConfiguration: UIContentConfiguration, Hashable {
    let show: TvShow
    let seasons: [SeasonSummary]
    let baseURL: URL

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
        backdropImageView.backgroundColor = .systemGray6
        backdropImageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.numberOfLines = 0

        metadataLabel.font = .systemFont(ofSize: 14)
        metadataLabel.textColor = .secondaryLabel

        overviewLabel.font = .systemFont(ofSize: 15)
        overviewLabel.textColor = .secondaryLabel
        overviewLabel.numberOfLines = 4

        progressLabel.font = .systemFont(ofSize: 13)
        progressLabel.textColor = .secondaryLabel

        progressBar.translatesAutoresizingMaskIntoConstraints = false

        let progressStack = UIStackView(arrangedSubviews: [progressLabel, progressBar])
        progressStack.axis = .vertical
        progressStack.spacing = 4

        let contentStack = UIStackView(arrangedSubviews: [titleLabel, metadataLabel, overviewLabel, progressStack])
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.setCustomSpacing(12, after: overviewLabel)

        let mainStack = UIStackView(arrangedSubviews: [backdropImageView, contentStack])
        mainStack.axis = .vertical
        mainStack.spacing = 16
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            backdropImageView.heightAnchor.constraint(equalTo: backdropImageView.widthAnchor, multiplier: 9.0 / 16.0),
        ])

        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? ShowHeroConfiguration else { return }
        let show = config.show

        titleLabel.text = show.name

        var meta = [String]()
        if let rating = Formatters.rating(show.rating) { meta.append("★ \(rating)") }
        if let date = show.firstAirDate { meta.append(String(date.prefix(4))) }
        let totalEps = config.seasons.reduce(0) { $0 + $1.episodeCount }
        meta.append("\(totalEps) episodes")
        metadataLabel.text = meta.joined(separator: " · ")

        overviewLabel.text = show.overview
        overviewLabel.isHidden = show.overview == nil

        let totalWatched = config.seasons.reduce(0) { $0 + $1.watchedCount }
        progressLabel.text = "\(totalWatched)/\(totalEps) episodes watched"
        if totalEps > 0 {
            progressBar.progress = Double(totalWatched) / Double(totalEps)
        }

        let imagePath = show.backdropPath ?? show.posterPath
        guard let imagePath else { return }
        if let blurhash = show.posterBlurhash, let decoded = BlurhashDecoder.decode(blurhash) {
            backdropImageView.image = decoded
        }
        let size = show.backdropPath != nil ? "w780" : "w500"
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: imagePath, size: size, baseURL: config.baseURL)
            guard !Task.isCancelled, let self else { return }
            if let image { self.backdropImageView.image = image }
        }
    }
}
