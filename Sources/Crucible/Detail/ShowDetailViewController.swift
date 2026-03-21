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
            var config = UIButton.Configuration.gray()
            config.title = "Season \(season.index ?? 0)"
            config.cornerStyle = .capsule
            config.buttonSize = .small
            if self.selectedSeasonKey == season.ratingKey {
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

        let episodeReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, episode in
            var config = EpisodeContentConfiguration()
            config.episodeNumber = episode.index
            config.title = episode.title
            config.duration = Formatters.duration(episode.durationSecs)
            config.isWatched = episode.isWatched
            if !episode.isWatched && episode.positionSecs > 0 && episode.durationSecs > 0 {
                config.progress = episode.positionSecs / episode.durationSecs
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
                    case "watchAll": try? await self.api.requestVoid(.scrobble(ratingKey: self.showRatingKey))
                    case "unwatchAll": try? await self.api.requestVoid(.unscrobble(ratingKey: self.showRatingKey))
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
                let showContainer = try await api.requestContainer(.metadata(ratingKey: showRatingKey))
                guard !Task.isCancelled, let showMeta = showContainer.Metadata?.first else { return }
                show = showMeta
                title = showMeta.title

                let seasonsContainer = try await api.requestContainer(.children(ratingKey: showRatingKey))
                guard !Task.isCancelled else { return }
                seasons = (seasonsContainer.Metadata ?? []).filter { $0.type == "season" }

                let firstUnwatched = seasons.first {
                    let watched = $0.viewedLeafCount ?? 0
                    let total = $0.leafCount ?? 0
                    return watched < total
                }
                selectedSeasonKey = firstUnwatched?.ratingKey ?? seasons.first?.ratingKey

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
            selectedSeasonKey = season.ratingKey
            seasonTask?.cancel()
            seasonTask = Task { [weak self] in
                guard let self else { return }
                await loadSeason(season.ratingKey)
                guard !Task.isCancelled else { return }
                await applySnapshot()
            }
        case .episode(let episode):
            let detail = MediaDetailViewController(
                api: api,
                ratingKey: episode.ratingKey,
                mediaType: "episode",
                showRatingKey: showRatingKey,
                seasonRatingKey: selectedSeasonKey
            )
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
                        try? await self.api.requestVoid(.scrobble(ratingKey: season.ratingKey))
                        self.loadData()
                    }
                },
                UIAction(title: "Mark Season Unwatched", image: UIImage(systemName: "circle")) { [weak self] _ in
                    guard let self else { return }
                    Task {
                        try? await self.api.requestVoid(.unscrobble(ratingKey: season.ratingKey))
                        self.loadData()
                    }
                },
            ])
        })
    }
}

struct ShowHeroConfiguration: UIContentConfiguration, Hashable {
    let show: PlexMetadata
    let seasons: [PlexMetadata]

    static func == (lhs: ShowHeroConfiguration, rhs: ShowHeroConfiguration) -> Bool {
        lhs.show.ratingKey == rhs.show.ratingKey
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(show.ratingKey)
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
        progressLabel.text = "\(totalWatched)/\(totalEps) episodes watched"
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
            if let image { self.backdropImageView.image = image }
        }
    }
}
