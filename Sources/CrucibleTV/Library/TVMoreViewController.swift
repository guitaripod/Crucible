import CrucibleCore
import CrucibleDesign
import UIKit

/// The More tab: the libraries that did not fit in the tab bar, as tiles with their kind and item
/// count. Selecting a tile opens that library.
final class TVMoreViewController: TVScreenViewController {
    enum Section: Hashable {
        case title, tiles
    }

    enum Item: Hashable {
        case title(TVScreenTitleContent)
        case library(String)
    }

    private let env: TVAppEnvironment
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var libraries: [PlexDirectory] = []
    private var counts: [String: Int] = [:]
    private lazy var countSlot = makeTaskSlot()

    init(env: TVAppEnvironment) {
        self.env = env
        super.init(layout: UICollectionViewLayout())
        title = "More"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDataSource()
        collectionView.collectionViewLayout = makeLayout()
        reloadLibraries()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadCounts()
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let self, dataSource.snapshot().sectionIdentifiers.indices.contains(index) else { return Self.tilesSection() }
            return dataSource.snapshot().sectionIdentifiers[index] == .title ? TVScreenTitleView.section() : Self.tilesSection()
        }
    }

    /// Four 410pt tiles with 40pt gutters fill the safe width exactly.
    private static func tilesSection() -> NSCollectionLayoutSection {
        TVShelf.grid(columns: 4, itemHeight: TVMetrics.Card.libraryTileSize.height)
    }

    private func configureDataSource() {
        let titleRegistration = TVScreenTitleView.registration()
        let tileRegistration = TVLibraryTile.registration()
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            switch item {
            case .title(let content):
                return collectionView.dequeueConfiguredReusableCell(using: titleRegistration, for: indexPath, item: content)
            case .library(let key):
                let tile = self?.tile(for: key) ?? TVTileItem(id: key, title: "")
                let cell = collectionView.dequeueConfiguredReusableCell(using: tileRegistration, for: indexPath, item: tile)
                cell.accessibilityIdentifier = "tv.more.library.\(key)"
                return cell
            }
        }
        adopt(dataSource)
    }

    private func tile(for key: String) -> TVTileItem? {
        guard let directory = libraries.first(where: { $0.key == key }) else { return nil }
        let kind = LibraryGridKind(sectionType: directory.type)
        let noun = kind == .show ? "shows" : "movies"
        let subtitle = counts[key].map { "\($0.formatted(.number)) \($0 == 1 ? String(noun.dropLast()) : noun)" } ?? kind?.defaultTitle
        return TVTileItem(id: key, title: directory.title ?? "Library", subtitle: subtitle, symbol: kind?.placeholderIcon)
    }

    private func reloadLibraries() {
        libraries = env.libraryLayout.overflow
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.title])
        snapshot.appendItems([.title(TVScreenTitleContent(title: "More Libraries"))], toSection: .title)
        snapshot.appendSections([.tiles])
        snapshot.appendItems(libraries.compactMap(\.key).map(Item.library), toSection: .tiles)
        dataSource.applyReconfiguringExisting(snapshot)
        if libraries.isEmpty {
            show(state: .empty(title: "No More Libraries", message: "Every library is in the tab bar.", symbol: "rectangle.stack", action: nil))
        } else {
            showContent()
        }
        if isViewLoaded, view.window != nil { loadCounts() }
    }

    private func reconfigureTile(_ key: String) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(.library(key)) != nil else { return }
        snapshot.reconfigureItems([.library(key)])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Fetches each library's item count with a zero-size page, which carries only the total.
    private func loadCounts() {
        let keys = libraries.compactMap(\.key)
        let api = env.api
        countSlot.run { [weak self] in
            await withTaskGroup(of: (String, Int?).self) { group in
                for key in keys {
                    group.addTask {
                        let container = try? await api.requestContainer(.sectionItems(sectionId: key, size: 0))
                        return (key, container?.totalSize)
                    }
                }
                for await (key, total) in group {
                    guard !Task.isCancelled, let self, let total, self.counts[key] != total else { continue }
                    self.counts[key] = total
                    self.reconfigureTile(key)
                }
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .library(let key) = dataSource.itemIdentifier(for: indexPath),
              let directory = libraries.first(where: { $0.key == key })
        else { return }
        TVNavigation.push(TVScreens.library(env, section: directory), from: self)
    }
}
