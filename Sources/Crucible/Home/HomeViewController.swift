@preconcurrency import UIKit
import os

final class HomeViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case continueWatching, onDeck, recentlyAdded, recentlyWatched, surpriseMe
    }

    enum Item: Hashable {
        case continueWatching(ContinueWatchingItem)
        case onDeck(OnDeckItem)
        case recent(MediaSummary)
        case watched(MediaSummary)
        case surpriseMe
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

            let itemSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(240))
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(widthDimension: .absolute(140), heightDimension: .estimated(240))
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
        let continueReg = UICollectionView.CellRegistration<UICollectionViewCell, ContinueWatchingItem> { [unowned self] cell, _, item in
            var config = PosterContentConfiguration()
            config.posterPath = item.posterPath
            config.blurhash = item.posterBlurhash
            if item.mediaType == "episode", let showName = item.showName {
                config.title = showName
                var sub = [String]()
                if let code = Formatters.episodeCode(item.seasonNumber, item.episodeNumber) { sub.append(code) }
                if let epTitle = item.episodeTitle { sub.append(epTitle) }
                config.subtitle = sub.isEmpty ? nil : sub.joined(separator: " · ")
                config.placeholderIcon = "tv"
            } else {
                config.title = item.title
                if let year = Formatters.relativeDate(item.lastPlayedAt) { config.subtitle = year }
            }
            config.progress = item.progressPercent.map { $0 / 100.0 }
            config.baseURL = self.api.baseURL
            cell.contentConfiguration = config
        }

        let onDeckReg = UICollectionView.CellRegistration<UICollectionViewCell, OnDeckItem> { [unowned self] cell, _, item in
            var config = PosterContentConfiguration()
            config.posterPath = item.posterPath
            config.blurhash = item.posterBlurhash
            config.title = item.showName
            config.placeholderIcon = "tv"
            if let code = Formatters.episodeCode(item.seasonNumber, item.episodeNumber) {
                let title = item.episodeTitle ?? ""
                config.subtitle = title.isEmpty ? code : "\(code) — \(title)"
            }
            config.baseURL = self.api.baseURL
            cell.contentConfiguration = config
        }

        let posterReg = UICollectionView.CellRegistration<UICollectionViewCell, MediaSummary> { [unowned self] cell, _, item in
            var config = PosterContentConfiguration()
            config.posterPath = item.posterPath
            config.blurhash = item.posterBlurhash
            if item.mediaType == "episode", let showName = item.showName {
                config.title = showName
                var sub = [String]()
                if let code = Formatters.episodeCode(item.seasonNumber, item.episodeNumber) { sub.append(code) }
                if let epTitle = item.episodeTitle { sub.append(epTitle) }
                config.subtitle = sub.isEmpty ? nil : sub.joined(separator: " · ")
                config.placeholderIcon = "tv"
            } else {
                config.title = item.title
                if let year = item.year { config.subtitle = "\(year)" }
            }
            config.baseURL = self.api.baseURL
            cell.contentConfiguration = config
        }

        let surpriseReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { cell, _, _ in
            var config = UIButton.Configuration.filled()
            config.title = "Surprise Me"
            config.image = UIImage(systemName: "shuffle")
            config.imagePadding = 8
            config.cornerStyle = .medium
            let button = UIButton(configuration: config)
            button.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.subviews.forEach { $0.removeFromSuperview() }
            cell.contentView.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: cell.contentView.topAnchor),
                button.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor),
                button.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor),
                button.heightAnchor.constraint(equalToConstant: 50),
            ])
            button.isUserInteractionEnabled = false
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .continueWatching(let cw):
                return collectionView.dequeueConfiguredReusableCell(using: continueReg, for: indexPath, item: cw)
            case .onDeck(let od):
                return collectionView.dequeueConfiguredReusableCell(using: onDeckReg, for: indexPath, item: od)
            case .recent(let m), .watched(let m):
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
            case .recentlyWatched: config.title = "Recently Watched"
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
                async let cwResponse: ContinueWatchingResponse = api.request(.continueWatching())
                async let odResponse: [OnDeckItem] = api.request(.onDeck())
                async let recentResponse: [MediaSummary] = api.request(.recentItems())
                async let watchedResponse: [MediaSummary] = api.request(.recentlyWatched())

                let (cw, od, recent, watched) = try await (cwResponse, odResponse, recentResponse, watchedResponse)
                guard !Task.isCancelled else { return }

                var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()

                if !cw.items.isEmpty {
                    snapshot.appendSections([.continueWatching])
                    snapshot.appendItems(cw.items.map { .continueWatching($0) }, toSection: .continueWatching)
                }
                if !od.isEmpty {
                    snapshot.appendSections([.onDeck])
                    snapshot.appendItems(od.map { .onDeck($0) }, toSection: .onDeck)
                }
                if !recent.isEmpty {
                    snapshot.appendSections([.recentlyAdded])
                    snapshot.appendItems(recent.map { .recent($0) }, toSection: .recentlyAdded)
                }
                if !watched.isEmpty {
                    snapshot.appendSections([.recentlyWatched])
                    snapshot.appendItems(watched.map { .watched($0) }, toSection: .recentlyWatched)
                }

                snapshot.appendSections([.surpriseMe])
                snapshot.appendItems([.surpriseMe], toSection: .surpriseMe)

                await self.dataSource.apply(snapshot, animatingDifferences: true)
                self.collectionView.refreshControl?.endRefreshing()
            } catch {
                guard !Task.isCancelled else { return }
                Logger(subsystem: "com.guitaripod.crucible", category: "home").error("Load failed: \(error)")
                collectionView.refreshControl?.endRefreshing()
            }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .continueWatching(let cw):
            let detail = MediaDetailViewController(api: api, mediaId: cw.id, mediaType: cw.mediaType, showId: cw.showId)
            navigationController?.pushViewController(detail, animated: true)
        case .onDeck(let od):
            let detail = MediaDetailViewController(api: api, mediaId: od.episodeId, mediaType: "episode", showId: od.showId)
            navigationController?.pushViewController(detail, animated: true)
        case .recent(let m), .watched(let m):
            let detail = MediaDetailViewController(api: api, mediaId: m.id, mediaType: m.mediaType, showId: m.showId)
            navigationController?.pushViewController(detail, animated: true)
        case .surpriseMe:
            Task { [weak self] in
                guard let self else { return }
                do {
                    let item: MediaSummary? = try await api.request(.randomItem())
                    guard let item else { return }
                    let detail = MediaDetailViewController(api: api, mediaId: item.id, mediaType: item.mediaType, showId: item.showId)
                    navigationController?.pushViewController(detail, animated: true)
                } catch {}
            }
        }
    }
}
