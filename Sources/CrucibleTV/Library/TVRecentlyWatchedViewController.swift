import CrucibleCore
import CrucibleDesign
import UIKit

/// "See All" for a library's Recently Watched shelf: the same play history as a poster grid with far
/// more titles than the shelf holds. It opens on the shelf's items and fills in once the longer
/// history arrives.
final class TVRecentlyWatchedViewController: TVScreenViewController {
    enum Section: Hashable {
        case title, grid
    }

    enum Item: Hashable {
        case title(TVScreenTitleContent)
        case recent(String)
    }

    private let env: TVAppEnvironment
    private let section: LibrarySection
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var items: [PlexMetadata]
    private var itemsById: [String: PlexMetadata] = [:]
    private lazy var loadSlot = makeTaskSlot()
    private lazy var actions = TVLibraryItemActions(env: env, kind: section.kind, presenter: self)

    init(env: TVAppEnvironment, section: LibrarySection, items: [PlexMetadata]) {
        self.env = env
        self.section = section
        self.items = items
        super.init(layout: UICollectionViewLayout())
        title = "Recently Watched"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDataSource()
        collectionView.collectionViewLayout = makeLayout()
        apply(items)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadHistory()
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let self, dataSource.snapshot().sectionIdentifiers.indices.contains(index) else { return TVShelf.grid() }
            return dataSource.snapshot().sectionIdentifiers[index] == .title ? TVScreenTitleView.section() : TVShelf.grid()
        }
    }

    private func configureDataSource() {
        let titleRegistration = TVScreenTitleView.registration()
        let posterRegistration = TVPosterCell.registration()
        let kind = section.kind
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            switch item {
            case .title(let content):
                return collectionView.dequeueConfiguredReusableCell(using: titleRegistration, for: indexPath, item: content)
            case .recent(let id):
                let card = self?.itemsById[id].map { TVCardItem(recentItem: $0, kind: kind) } ?? TVCardItem(id: id, title: "")
                return collectionView.dequeueConfiguredReusableCell(using: posterRegistration, for: indexPath, item: card)
            }
        }
        adopt(dataSource)
    }

    private func loadHistory() {
        loadSlot.run { [weak self] in
            guard let self else { return }
            let loaded = await RecentlyWatched.load(
                api: env.api,
                sectionId: section.id,
                groupingByShow: section.kind.groupsHistoryByShow,
                limit: RecentlyWatched.gridLimit
            )
            guard !Task.isCancelled, !loaded.isEmpty else { return }
            apply(loaded)
        }
    }

    private func apply(_ newItems: [PlexMetadata]) {
        items = newItems
        itemsById = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen = Set<String>()
        let ids = newItems.map(\.id).filter { seen.insert($0).inserted }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.title])
        snapshot.appendItems([.title(TVScreenTitleContent(title: "Recently Watched"))], toSection: .title)
        snapshot.appendSections([.grid])
        snapshot.appendItems(ids.map(Item.recent), toSection: .grid)
        dataSource.applyReconfiguringExisting(snapshot)
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        guard case .recent(let id) = dataSource.itemIdentifier(for: indexPath), let item = itemsById[id] else { return false }
        return actions.play(item, isRecent: true)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .recent(let id) = dataSource.itemIdentifier(for: indexPath), let item = itemsById[id] else { return }
        actions.select(item, isRecent: true)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              case .recent(let id) = dataSource.itemIdentifier(for: indexPath),
              let item = itemsById[id]
        else { return nil }
        return TVContextMenu.configuration(menu: actions.menu(for: item, isRecent: true))
    }
}
