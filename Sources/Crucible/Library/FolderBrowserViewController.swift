import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

final class FolderBrowserViewController: UICollectionViewController {
    enum SectionKind: Int, Hashable {
        case folders, media
    }

    enum Item: Hashable {
        case folder(key: String, title: String)
        case media(PlexMetadata)

        static func == (lhs: Item, rhs: Item) -> Bool {
            switch (lhs, rhs) {
            case (.folder(let a, _), .folder(let b, _)): return a == b
            case (.media(let a), .media(let b)): return a.id == b.id
            default: return false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .folder(let key, _): hasher.combine("f"); hasher.combine(key)
            case .media(let m): hasher.combine("m"); hasher.combine(m.id)
            }
        }
    }

    private let api: APIClient
    private let source: LibraryFolderListing.Source
    private let folderTitle: String?
    private var dataSource: UICollectionViewDiffableDataSource<SectionKind, Item>!
    private var loadTask: Task<Void, Never>?
    private var playerCoordinator: PlayerCoordinator?

    init(api: APIClient, source: LibraryFolderListing.Source, folderTitle: String? = nil) {
        self.api = api
        self.source = source
        self.folderTitle = folderTitle
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = folderTitle ?? "Browse"
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        configureDataSource()
        collectionView.collectionViewLayout = createLayout()
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

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let identifiers = dataSource.snapshot().sectionIdentifiers
            guard sectionIndex < identifiers.count else { return nil }
            let sectionIdentifier = identifiers[sectionIndex]

            if sectionIdentifier == .folders {
                var listConfig = UICollectionLayoutListConfiguration(appearance: .plain)
                listConfig.showsSeparators = true
                listConfig.backgroundColor = Theme.Color.canvas
                return NSCollectionLayoutSection.list(using: listConfig, layoutEnvironment: environment)
            }

            return Theme.gridLayout(environment: environment)
        }
    }

    private func configureDataSource() {
        let folderReg = UICollectionView.CellRegistration<UICollectionViewListCell, (String, String)> { cell, _, item in
            var config = UIListContentConfiguration.cell()
            config.text = item.1
            config.textProperties.font = Theme.Font.scaled(.callout, 16, .semibold)
            config.textProperties.color = Theme.Color.label
            config.image = UIImage(systemName: "folder.fill")
            config.imageProperties.tintColor = Theme.Color.accentText
            cell.contentConfiguration = config
            cell.accessories = [.disclosureIndicator()]
        }

        let mediaReg = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { [unowned self] cell, _, item in
            var config = LibraryPoster(folderItem: item).configuration
            config.showPlayButton = item.ratingKey != nil
            config.onQuickPlay = { [weak self] in
                self?.quickPlay(item)
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
                let listing = try await LibraryFolderListing.load(source, api: api)
                let folders = listing.folders.map { Item.folder(key: $0.key, title: $0.title) }
                let media = listing.media.map(Item.media)

                var snapshot = NSDiffableDataSourceSnapshot<SectionKind, Item>()
                if !folders.isEmpty {
                    snapshot.appendSections([.folders])
                    snapshot.appendItems(folders, toSection: .folders)
                }
                if !media.isEmpty {
                    snapshot.appendSections([.media])
                    snapshot.appendItems(media, toSection: .media)
                }
                await dataSource.apply(snapshot, animatingDifferences: false)
                collectionView.collectionViewLayout.invalidateLayout()

                if listing.isEmpty {
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

    private func quickPlay(_ item: PlexMetadata) {
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }

        switch item {
        case .folder(let key, let title):
            let vc = FolderBrowserViewController(api: api, source: .folder(key), folderTitle: title)
            navigationController?.pushViewController(vc, animated: true)
        case .media(let m):
            guard let destination = LibraryDestination(browsing: m) else { return }
            navigationController?.pushViewController(destination.viewController(api: api), animated: true)
        }
    }
}
