@preconcurrency import UIKit
import os

final class HomeViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case continueWatching, onDeck, recentlyAdded, surpriseMe
    }

    enum Item: Hashable {
        case media(PlexMetadata, String)
        case surpriseMe

        static func == (lhs: Item, rhs: Item) -> Bool {
            switch (lhs, rhs) {
            case (.media(let a, let sa), .media(let b, let sb)):
                return a.id == b.id && sa == sb
            case (.surpriseMe, .surpriseMe):
                return true
            default:
                return false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .media(let m, let section):
                hasher.combine(m.id)
                hasher.combine(section)
            case .surpriseMe:
                hasher.combine("surprise")
            }
        }
    }

    private let api: APIClient
    private var loadTask: Task<Void, Never>?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
        navigationController?.navigationBar.prefersLargeTitles = true
        collectionView.collectionViewLayout = createLayout()
        configureDataSource()

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [unowned self] _ in loadData() }, for: .valueChanged)
        collectionView.refreshControl = refresh
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadData()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func createLayout() -> UICollectionViewCompositionalLayout {
        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44))
        let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)

        return UICollectionViewCompositionalLayout { sectionIndex, environment in
            guard let section = Section(rawValue: sectionIndex) else { return nil }

            if section == .surpriseMe {
                let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(50)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(50)), subitems: [item])
                let layoutSection = NSCollectionLayoutSection(group: group)
                layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16)
                layoutSection.boundarySupplementaryItems = [header]
                return layoutSection
            }

            let cardWidth: CGFloat = 140
            let cardHeight: CGFloat = 210
            let itemSize = NSCollectionLayoutSize(widthDimension: .absolute(cardWidth), heightDimension: .absolute(cardHeight))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(widthDimension: .absolute(cardWidth), heightDimension: .absolute(cardHeight))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
            let layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
            layoutSection.interGroupSpacing = 12
            layoutSection.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 16, trailing: 16)
            layoutSection.boundarySupplementaryItems = [header]
            return layoutSection
        }
    }

    private func configureDataSource() {
        let posterReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, item in
            var config = PosterContentConfiguration()
            config.posterPath = item.thumb ?? item.grandparentThumb
            if item.mediaType == "episode", let showName = item.grandparentTitle {
                config.title = showName
                var sub = [String]()
                if let code = Formatters.episodeCode(item.parentIndex, item.index) { sub.append(code) }
                sub.append(item.title)
                config.subtitle = sub.joined(separator: " · ")
                config.placeholderIcon = "tv"
            } else {
                config.title = item.title
                if let year = item.year { config.subtitle = "\(year)" }
            }
            if item.viewOffset != nil && item.duration != nil {
                config.progress = item.progressPercent
            }
            cell.contentConfiguration = config
        }

        let surpriseReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, _ in
            var config = UIButton.Configuration.filled()
            config.title = "Surprise Me"
            config.subtitle = "Pick something random"
            config.titleAlignment = .leading
            config.image = UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20))
            config.imagePadding = 14
            config.cornerStyle = .large
            config.baseBackgroundColor = UIColor.systemOrange.withAlphaComponent(0.15)
            config.baseForegroundColor = .systemOrange
            let button = UIButton(configuration: config)
            button.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            cell.contentView.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                button.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                button.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                button.heightAnchor.constraint(equalToConstant: 56),
            ])
            button.isUserInteractionEnabled = false
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .media(let m, _):
                return collectionView.dequeueConfiguredReusableCell(using: posterReg, for: indexPath, item: m)
            case .surpriseMe:
                return collectionView.dequeueConfiguredReusableCell(using: surpriseReg, for: indexPath, item: "surprise")
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { cell, _, indexPath in
            guard let section = Section(rawValue: indexPath.section) else { return }
            var config = SectionHeaderConfiguration()
            switch section {
            case .continueWatching: config.title = "Continue Watching"
            case .onDeck: config.title = "On Deck"
            case .recentlyAdded: config.title = "Recently Added"
            case .surpriseMe: config.title = "Discover"
            }
            cell.contentConfiguration = config
        }

        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func loadData() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let container = try await api.requestContainer(.hubs())
                guard !Task.isCancelled else { return }

                var continueItems = [PlexMetadata]()
                var onDeckItems = [PlexMetadata]()
                var recentItems = [PlexMetadata]()

                for hub in container.Hub ?? [] {
                    guard let id = hub.hubIdentifier, let items = hub.Metadata, !items.isEmpty else { continue }
                    let lowered = id.lowercased()
                    if lowered.contains("continue") || lowered.contains("inprogress") {
                        continueItems.append(contentsOf: items)
                    } else if lowered.contains("ondeck") {
                        onDeckItems.append(contentsOf: items)
                    } else if lowered.contains("recentlyadded") || lowered.contains("recent") {
                        recentItems.append(contentsOf: items)
                    }
                }

                var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

                if !continueItems.isEmpty {
                    snapshot.appendSections([.continueWatching])
                    snapshot.appendItems(continueItems.map { .media($0, "cw") }, toSection: .continueWatching)
                }
                if !onDeckItems.isEmpty {
                    snapshot.appendSections([.onDeck])
                    snapshot.appendItems(onDeckItems.map { .media($0, "od") }, toSection: .onDeck)
                }
                if !recentItems.isEmpty {
                    snapshot.appendSections([.recentlyAdded])
                    snapshot.appendItems(recentItems.map { .media($0, "ra") }, toSection: .recentlyAdded)
                }

                snapshot.appendSections([.surpriseMe])
                snapshot.appendItems([.surpriseMe], toSection: .surpriseMe)

                await self.dataSource.apply(snapshot, animatingDifferences: true)
                self.collectionView.refreshControl?.endRefreshing()

                if continueItems.isEmpty && onDeckItems.isEmpty && recentItems.isEmpty {
                    var emptyConfig = UIContentUnavailableConfiguration.empty()
                    emptyConfig.image = UIImage(systemName: "play.rectangle")
                    emptyConfig.text = "No content yet"
                    emptyConfig.secondaryText = "Add media to your Plex libraries to see it here"
                    contentUnavailableConfiguration = emptyConfig
                } else {
                    contentUnavailableConfiguration = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                collectionView.refreshControl?.endRefreshing()
                var errConfig = UIContentUnavailableConfiguration.empty()
                errConfig.image = UIImage(systemName: "exclamationmark.triangle")
                errConfig.text = "Failed to load"
                errConfig.secondaryText = error.localizedDescription
                contentUnavailableConfiguration = errConfig
            }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .media(let m, _):
            if m.mediaType == "show" {
                let detail = ShowDetailViewController(api: api, showRatingKey: m.id)
                navigationController?.pushViewController(detail, animated: true)
            } else {
                let detail = MediaDetailViewController(
                    api: api,
                    ratingKey: m.id,
                    mediaType: m.mediaType,
                    showRatingKey: m.grandparentRatingKey,
                    seasonRatingKey: m.parentRatingKey
                )
                navigationController?.pushViewController(detail, animated: true)
            }
        case .surpriseMe:
            Task { [weak self] in
                guard let self else { return }
                do {
                    let container = try await api.requestContainer(.recentlyAdded(start: 0, size: 100))
                    guard let items = container.Metadata, let random = items.randomElement() else { return }
                    if random.mediaType == "show" {
                        let detail = ShowDetailViewController(api: api, showRatingKey: random.id)
                        navigationController?.pushViewController(detail, animated: true)
                    } else {
                        let detail = MediaDetailViewController(api: api, ratingKey: random.id, mediaType: random.mediaType)
                        navigationController?.pushViewController(detail, animated: true)
                    }
                } catch {}
            }
        }
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let item = dataSource.itemIdentifier(for: indexPath),
              case .media(let m, _) = item,
              m.mediaType != "show" else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                    guard let self else { return }
                    quickPlay(m)
                },
            ])
        })
    }

    private var playerCoordinator: PlayerCoordinator?

    private func quickPlay(_ item: PlexMetadata) {
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }
}
