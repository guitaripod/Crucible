import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// "See All" destination for a Home rail: the rail's items as a poster grid.
final class HomeSectionGridViewController: UICollectionViewController {
    let bucket: HomeBucket
    private let api: APIClient
    private let onChange: @MainActor () -> Void
    private var items: [PlexMetadata]
    private var mediaById: [String: PlexMetadata] = [:]
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var artworkAspect = Theme.Size.posterAspect
    private var playerCoordinator: PlayerCoordinator?
    private lazy var mediaDrag = MediaDragSource { [weak self] indexPath in self?.media(at: indexPath) }

    init(api: APIClient, title: String, bucket: HomeBucket, items: [PlexMetadata], onChange: @escaping @MainActor () -> Void) {
        self.api = api
        self.bucket = bucket
        self.items = items
        self.onChange = onChange
        super.init(collectionViewLayout: UICollectionViewLayout())
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.allowsKeyboardFocus()
        collectionView.dragDelegate = mediaDrag
        view.backgroundColor = Theme.Color.canvas
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            Theme.gridLayout(environment: environment, aspect: self?.artworkAspect ?? Theme.Size.posterAspect)
        }
        configureDataSource()
        update(items: items)
    }

    func update(items newItems: [PlexMetadata]) {
        items = newItems
        guard isViewLoaded else { return }
        mediaById = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen = Set<String>()
        let ids = newItems.map(\.id).filter { seen.insert($0).inserted }
        adoptArtworkAspect(of: newItems)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        snapshot.reconfigureItems(ids.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)

        if ids.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "rectangle.stack")
            empty.text = String(localized: "Nothing Here")
            empty.secondaryText = String(localized: "This list is empty right now.")
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    /// Lays the grid out in the shape most of the rail's artwork has; the snapshot that follows reshapes the cards on screen.
    private func adoptArtworkAspect(of items: [PlexMetadata]) {
        let bucket = bucket
        let aspect = CGFloat(ArtworkAspect.dominant(items.map {
            ArtworkAspect.of($0, path: HomeCardModel(item: $0, bucket: bucket, layout: .poster).imagePath)
        }))
        guard aspect != artworkAspect else { return }
        artworkAspect = aspect
        collectionView.collectionViewLayout.invalidateLayout()
    }

    private func configureDataSource() {
        let bucket = bucket
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let item = mediaById[id] else { return }
            var config = HomeMediaActions.posterConfiguration(for: item, bucket: bucket)
            config.artworkAspect = artworkAspect
            cell.contentConfiguration = config
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = mediaById[id] else { return }
        HomeMediaActions.openDetail(item, api: api, from: navigationController)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              let id = dataSource.itemIdentifier(for: indexPath),
              let item = mediaById[id] else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            return HomeMediaActions.contextMenu(
                for: item,
                in: bucket,
                api: api,
                navigation: { [weak self] in self?.navigationController },
                play: { [weak self] item in self?.play(item) },
                didChange: { [weak self] in self?.onChange() }
            ).addingNewWindow(for: item)
        })
    }

    private func media(at indexPath: IndexPath) -> PlexMetadata? {
        dataSource.itemIdentifier(for: indexPath).flatMap { mediaById[$0] }
    }

    private func play(_ item: PlexMetadata) {
        Haptics.light()
        playerCoordinator = Theme.quickPlay(api: api, item: item, from: self)
    }
}
