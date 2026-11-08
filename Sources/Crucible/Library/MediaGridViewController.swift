import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// A poster grid of whatever `load` brings: a collection's titles, the viewer's playlists, a playlist's entries. The screen owns loading,
/// the empty and failed states and pull to refresh; its owner says what a card looks like, what a tap does and what a long press offers.
final class MediaGridViewController: UICollectionViewController {
    struct Empty {
        var symbol = "rectangle.stack"
        var title = String(localized: "Nothing Here")
        var text = String(localized: "This list is empty right now.")
    }

    var onSelect: ((PlexMetadata) -> Void)?
    var onLoaded: (([PlexMetadata]) -> Void)?
    var refreshInterval: Duration?
    /// Reloads as soon as the server announces an event that matters to this list, besides the regular refresh.
    var liveRefresh: (api: APIClient, matches: @Sendable (ServerEvent) -> Bool)?
    var retainedPlayer: PlayerCoordinator?
    var contextMenu: ((PlexMetadata) -> UIMenu?)?
    var configuration: (PlexMetadata) -> PosterContentConfiguration = { DetailLayout.posterConfiguration(for: $0) }

    private let load: () async throws -> [PlexMetadata]
    private let empty: Empty
    private var items: [PlexMetadata] = []
    private var itemsByID: [String: PlexMetadata] = [:]
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private lazy var artworkShape = ArtworkShapeTracker { [weak self] in
        guard let self else { return [] }
        return items.map { item in
            let path = self.configuration(item).posterPath
            return ArtworkAspect.Sample(path: path, guess: ArtworkAspect.of(item, path: path))
        }
    } onChange: { [weak self] in
        self?.artworkShapeDidChange()
    }
    private var artworkAspect: CGFloat { CGFloat(artworkShape.aspect) }
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var listening: ServerEventListening?
    private var hasLoaded = false
    private lazy var mediaDrag = MediaDragSource { [weak self] indexPath in self?.item(at: indexPath) }

    init(title: String, empty: Empty = Empty(), load: @escaping () async throws -> [PlexMetadata]) {
        self.load = load
        self.empty = empty
        super.init(collectionViewLayout: UICollectionViewLayout())
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        refreshTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.allowsKeyboardFocus()
        collectionView.dragDelegate = mediaDrag
        collectionView.refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in self?.reload() })
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { [weak self] _, environment in
            Theme.gridLayout(environment: environment, aspect: self?.artworkAspect ?? Theme.Size.posterAspect)
        }
        configureDataSource()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        reload()
        startRefreshing()
        if let liveRefresh {
            listening?.cancel()
            listening = ServerEventHub.shared.listen(api: liveRefresh.api, every: .seconds(1), matching: liveRefresh.matches) { [weak self] in
                self?.reload()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
        refreshTask?.cancel()
        listening?.cancel()
        listening = nil
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        guard let interval = refreshInterval else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
    }

    func reload() {
        loadTask?.cancel()
        if !hasLoaded { contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading() }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await load()
                guard !Task.isCancelled else { return }
                hasLoaded = true
                display(loaded)
            } catch {
                guard !Task.isCancelled else { return }
                MidgarLog.error("Grid load failed for \(title ?? "grid"): \(error.localizedDescription)", category: .networking)
                collectionView.refreshControl?.endRefreshing()
                if !hasLoaded { showFailure(error.localizedDescription) }
            }
        }
    }

    private func display(_ loaded: [PlexMetadata]) {
        items = loaded
        onLoaded?(loaded)
        itemsByID = Dictionary(loaded.map { ($0.entryID, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen = Set<String>()
        let ids = loaded.map(\.entryID).filter { seen.insert($0).inserted }
        if artworkShape.update() { collectionView.collectionViewLayout.invalidateLayout() }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        snapshot.reconfigureItems(ids.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil && !UIAccessibility.isReduceMotionEnabled)
        collectionView.refreshControl?.endRefreshing()
        if ids.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: empty.symbol)
            config.text = empty.title
            config.secondaryText = empty.text
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    /// Artwork that loaded since showed the grid's real shape (square playlist covers, a collection of videos without posters):
    /// re-lays it out and reshapes the cards already on screen.
    private func artworkShapeDidChange() {
        guard isViewLoaded else { return }
        collectionView.collectionViewLayout.invalidateLayout()
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func showFailure(_ message: String) {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "exclamationmark.triangle")
        config.text = String(localized: "Couldn\u{2019}t Load")
        config.secondaryText = message
        var button = UIButton.Configuration.filled()
        button.title = String(localized: "Retry")
        button.baseBackgroundColor = Theme.Color.accent
        button.baseForegroundColor = Theme.Color.onAccent
        button.cornerStyle = .capsule
        config.button = button
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.reload() }
        contentUnavailableConfiguration = config
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let item = itemsByID[id] else { return }
            var config = configuration(item)
            config.artworkAspect = artworkAspect
            cell.contentConfiguration = config
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    /// Redraws the cards of `ids` after something they show changed outside the grid.
    func reconfigure(_ ids: [String]) {
        var snapshot = dataSource.snapshot()
        let present = ids.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func item(at indexPath: IndexPath) -> PlexMetadata? {
        dataSource.itemIdentifier(for: indexPath).flatMap { itemsByID[$0] }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = item(at: indexPath) else { return }
        onSelect?(item)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = item(at: indexPath), let contextMenu else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in contextMenu(item) })
    }
}
