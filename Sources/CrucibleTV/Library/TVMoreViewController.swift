import CrucibleCore
import CrucibleDesign
import UIKit

/// The More tab: the libraries that did not fit in the tab bar, as tiles with their kind and item
/// count. Selecting a tile opens that library.
final class TVMoreViewController: UIViewController {
    enum Section: Hashable {
        case title, tiles
    }

    enum Item: Hashable {
        case title(TVScreenTitle.Content)
        case library(String)
    }

    private let env: TVAppEnvironment
    private let collectionView: TVCollectionView
    private let stateView = TVStateView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var libraries: [PlexDirectory] = []
    private var counts: [String: Int] = [:]
    private var countTasks: [Task<Void, Never>] = []
    private var visibilityObserver: UUID?

    init(env: TVAppEnvironment) {
        self.env = env
        collectionView = TVCollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        super.init(nibName: nil, bundle: nil)
        title = "More"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        countTasks.forEach { $0.cancel() }
        if let visibilityObserver {
            Task { @MainActor in LibraryVisibility.removeObserver(visibilityObserver) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        stateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        view.addSubview(stateView)
        for pinned in [collectionView, stateView] as [UIView] {
            NSLayoutConstraint.activate([
                pinned.topAnchor.constraint(equalTo: view.topAnchor),
                pinned.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                pinned.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                pinned.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        configureDataSource()
        collectionView.collectionViewLayout = makeLayout()
        visibilityObserver = LibraryVisibility.addObserver { [weak self] in
            self?.reloadLibraries()
        }
        reloadLibraries()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadCounts()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        countTasks.forEach { $0.cancel() }
        countTasks = []
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        stateView.isHidden ? [collectionView] : [stateView]
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let self, dataSource.snapshot().sectionIdentifiers.indices.contains(index) else { return Self.tilesSection() }
            return dataSource.snapshot().sectionIdentifiers[index] == .title ? TVScreenTitle.section() : Self.tilesSection()
        }
    }

    /// Four 410pt tiles with 40pt gutters fill the safe width exactly.
    private static func tilesSection() -> NSCollectionLayoutSection {
        TVShelf.grid(columns: 4, itemHeight: TVMetrics.Card.libraryTileSize.height)
    }

    private func configureDataSource() {
        let titleRegistration = TVScreenTitle.registration()
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
        snapshot.appendItems([.title(TVScreenTitle.Content(title: "More Libraries"))], toSection: .title)
        snapshot.appendSections([.tiles])
        snapshot.appendItems(libraries.compactMap(\.key).map(Item.library), toSection: .tiles)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
        showEmptyState(libraries.isEmpty)
        if isViewLoaded, view.window != nil { loadCounts() }
    }

    private func showEmptyState(_ isEmpty: Bool) {
        if isEmpty {
            stateView.show(.empty(
                title: "No More Libraries",
                message: "Every library is in the tab bar.",
                symbol: "rectangle.stack",
                action: nil
            ))
        }
        let changedVisibility = stateView.isHidden == isEmpty
        stateView.isHidden = !isEmpty
        collectionView.isHidden = isEmpty
        if changedVisibility { setNeedsFocusUpdate() }
    }

    private func reconfigureTile(_ key: String) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([.library(key)])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Fetches each library's item count with a zero-size page, which carries only the total.
    private func loadCounts() {
        countTasks.forEach { $0.cancel() }
        countTasks = libraries.compactMap(\.key).map { key in
            Task { [weak self] in
                guard let self else { return }
                do {
                    let container = try await env.api.requestContainer(.sectionItems(sectionId: key, size: 0))
                    guard !Task.isCancelled, let total = container.totalSize, counts[key] != total else { return }
                    counts[key] = total
                    reconfigureTile(key)
                } catch {
                    guard !Task.isCancelled else { return }
                    AppLogger.error("More library count failed section=\(key): \(error.localizedDescription)", .networking)
                }
            }
        }
    }
}

extension TVMoreViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        if case .title = dataSource.itemIdentifier(for: indexPath) { return false }
        return true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .library(let key) = dataSource.itemIdentifier(for: indexPath),
              let directory = libraries.first(where: { $0.key == key })
        else { return }
        navigationController?.pushViewController(TVScreens.library(env, section: directory), animated: true)
    }
}
