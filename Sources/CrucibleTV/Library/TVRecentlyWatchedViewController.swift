import CrucibleCore
import CrucibleDesign
import UIKit

/// "See All" for a library's Recently Watched shelf: the same play history as a poster grid with far
/// more titles than the shelf holds. It opens on the shelf's items and fills in once the longer
/// history arrives.
final class TVRecentlyWatchedViewController: UIViewController {
    enum Section: Hashable {
        case title, grid
    }

    enum Item: Hashable {
        case title(TVScreenTitle.Content)
        case recent(String)
    }

    private let env: TVAppEnvironment
    private let section: LibrarySection
    private let collectionView: TVCollectionView
    private let stateView = TVStateView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var items: [PlexMetadata]
    private var itemsById: [String: PlexMetadata] = [:]
    private var loadTask: Task<Void, Never>?

    init(env: TVAppEnvironment, section: LibrarySection, items: [PlexMetadata]) {
        self.env = env
        self.section = section
        self.items = items
        collectionView = TVCollectionView(frame: .zero, collectionViewLayout: UICollectionViewLayout())
        super.init(nibName: nil, bundle: nil)
        title = "Recently Watched"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.onPlayPause = { [weak self] indexPath in
            self?.playItem(at: indexPath)
        }
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
        apply(items)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadHistory()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        stateView.isHidden ? [collectionView] : [stateView]
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let self else { return nil }
            let sections = dataSource.snapshot().sectionIdentifiers
            guard sections.indices.contains(index) else { return nil }
            return sections[index] == .title ? TVScreenTitle.section() : TVShelf.grid()
        }
    }

    private func configureDataSource() {
        let titleRegistration = TVScreenTitle.registration()
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
    }

    private func loadHistory() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
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
        snapshot.appendItems([.title(TVScreenTitle.Content(title: "Recently Watched"))], toSection: .title)
        snapshot.appendSections([.grid])
        snapshot.appendItems(ids.map(Item.recent), toSection: .grid)
        snapshot.reconfigureItems(ids.filter { dataSource.snapshot().indexOfItem(.recent($0)) != nil }.map(Item.recent))
        dataSource.apply(snapshot, animatingDifferences: false)
        showEmptyState(ids.isEmpty)
    }

    private func showEmptyState(_ isEmpty: Bool) {
        if isEmpty {
            stateView.show(.empty(
                title: "Nothing Watched Yet",
                message: "Titles you watch from this library appear here.",
                symbol: section.kind.placeholderIcon,
                action: nil
            ))
        }
        stateView.isHidden = !isEmpty
        collectionView.isHidden = isEmpty
        setNeedsFocusUpdate()
    }

    private func playItem(at indexPath: IndexPath) {
        guard case .recent(let id) = dataSource.itemIdentifier(for: indexPath),
              let item = itemsById[id], item.mediaType != "show"
        else { return }
        TVScreens.play(env, request: TVPlaybackRequest(item: item, resumeSeconds: 0), from: self)
    }
}

extension TVRecentlyWatchedViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, canFocusItemAt indexPath: IndexPath) -> Bool {
        if case .title = dataSource.itemIdentifier(for: indexPath) { return false }
        return true
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard case .recent(let id) = dataSource.itemIdentifier(for: indexPath), let item = itemsById[id] else { return }
        TVScreens.open(LibraryDestination(recent: item, kind: section.kind), env: env, on: navigationController)
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
        let menu = UIMenu(libraryActions: LibraryItemAction.recent(for: item, kind: section.kind)) { [weak self] action in
            self?.perform(action, on: item)
        }
        return TVContextMenu.configuration(menu: menu)
    }

    private func perform(_ action: LibraryItemAction, on item: PlexMetadata) {
        switch action.kind {
        case .play:
            TVScreens.play(env, request: TVPlaybackRequest(item: item, resumeSeconds: 0), from: self)
        case .goToShow(let showKey):
            TVScreens.open(.show(ratingKey: showKey), env: env, on: navigationController)
        case .viewDetails:
            TVScreens.open(.media(item), env: env, on: navigationController)
        case .setWatched:
            return
        }
    }
}
