@preconcurrency import UIKit

final class FolderBrowserViewController: UICollectionViewController {
    enum Item: Hashable {
        case folder(key: String, title: String)
        case media(PlexMetadata)
    }

    private let api: APIClient
    private let sectionId: String
    private let folderKey: String?
    private let folderTitle: String?
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var loadTask: Task<Void, Never>?

    init(api: APIClient, sectionId: String, folderKey: String? = nil, folderTitle: String? = nil) {
        self.api = api
        self.sectionId = sectionId
        self.folderKey = folderKey
        self.folderTitle = folderTitle
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = folderTitle
        navigationItem.largeTitleDisplayMode = .never

        var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
        listConfig.showsSeparators = true
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout.list(using: listConfig)

        configureDataSource()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if dataSource.snapshot().numberOfItems == 0 {
            loadData()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func configureDataSource() {
        let folderReg = UICollectionView.CellRegistration<UICollectionViewListCell, (String, String)> { cell, _, item in
            var config = UIListContentConfiguration.cell()
            config.text = item.1
            config.image = UIImage(systemName: "folder.fill")
            config.imageProperties.tintColor = .systemBlue
            cell.contentConfiguration = config
            cell.accessories = [.disclosureIndicator()]
        }

        let mediaReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, item in
            var config = PosterContentConfiguration()
            config.posterPath = item.thumb ?? item.grandparentThumb
            config.title = item.title
            if let year = item.year {
                config.subtitle = "\(year)"
            } else if let show = item.grandparentTitle {
                var sub = [String]()
                if let code = Formatters.episodeCode(item.parentIndex, item.index) { sub.append(code) }
                sub.append(show)
                config.subtitle = sub.joined(separator: " · ")
            }
            if item.type == "show" || item.type == "episode" {
                config.placeholderIcon = "tv"
            }
            cell.contentConfiguration = config
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, item in
            switch item {
            case .folder(let key, let title):
                return cv.dequeueConfiguredReusableCell(using: folderReg, for: indexPath, item: (key, title))
            case .media(let m):
                return cv.dequeueConfiguredReusableCell(using: mediaReg, for: indexPath, item: m)
            }
        }
    }

    private func loadData() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let endpoint: PlexEndpoint
                if let folderKey {
                    endpoint = .sectionFolder(sectionId: sectionId, folderId: folderKey)
                } else {
                    endpoint = .sectionFolder(sectionId: sectionId)
                }
                let container = try await api.requestContainer(endpoint)
                guard !Task.isCancelled else { return }

                var items = [Item]()

                for dir in container.Directory ?? [] {
                    items.append(.folder(key: dir.key, title: dir.title))
                }
                for meta in container.Metadata ?? [] {
                    items.append(.media(meta))
                }

                var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
                snapshot.appendSections([0])
                snapshot.appendItems(items, toSection: 0)
                await dataSource.apply(snapshot, animatingDifferences: false)

                if items.isEmpty {
                    var config = UIContentUnavailableConfiguration.empty()
                    config.image = UIImage(systemName: "folder")
                    config.text = "Empty folder"
                    contentUnavailableConfiguration = config
                } else {
                    contentUnavailableConfiguration = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                var config = UIContentUnavailableConfiguration.empty()
                config.image = UIImage(systemName: "exclamationmark.triangle")
                config.text = "Failed to load"
                config.secondaryText = error.localizedDescription
                contentUnavailableConfiguration = config
            }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .folder(let key, let title):
            let vc = FolderBrowserViewController(api: api, sectionId: sectionId, folderKey: key, folderTitle: title)
            navigationController?.pushViewController(vc, animated: true)
        case .media(let m):
            if m.type == "show" {
                let vc = ShowDetailViewController(api: api, showRatingKey: m.ratingKey)
                navigationController?.pushViewController(vc, animated: true)
            } else {
                let vc = MediaDetailViewController(
                    api: api,
                    ratingKey: m.ratingKey,
                    mediaType: m.type,
                    showRatingKey: m.grandparentRatingKey,
                    seasonRatingKey: m.parentRatingKey
                )
                navigationController?.pushViewController(vc, animated: true)
            }
        }
    }
}
