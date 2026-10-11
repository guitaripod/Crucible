import CrucibleCore
import CrucibleDesign
import UIKit

/// "See All" for a Home rail: every card of the rail in a grid (six posters or four landscape cards
/// across). It stays live: Home pushes its refreshed rail into `update(items:)`.
final class TVHomeSeeAllViewController: UIViewController, UICollectionViewDelegate {
    private static let topInset: CGFloat = 140

    let bucket: HomeBucket
    private let actions: TVHomeActions
    private let screenTitle: String
    private var items: [PlexMetadata]
    private var mediaByID: [String: PlexMetadata] = [:]
    private lazy var collectionView = TVCollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private let stateView = TVStateView()
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private let focusMemory = TVFocusMemory()

    init(env: TVAppEnvironment, bucket: HomeBucket, title: String, items: [PlexMetadata], onChange: @escaping @MainActor () -> Void) {
        self.bucket = bucket
        self.items = items
        screenTitle = title
        actions = TVHomeActions(env: env, onChange: onChange)
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        [collectionView, stateView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
            NSLayoutConstraint.activate([
                $0.topAnchor.constraint(equalTo: view.topAnchor),
                $0.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                $0.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }
        stateView.isHidden = true
        collectionView.contentInset.top = Self.topInset
        collectionView.contentOffset.y = -Self.topInset
        collectionView.delegate = self
        collectionView.onPlayPause = { [weak self] indexPath in self?.playPause(at: indexPath) }
        configureDataSource()
        update(items: items)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        stateView.isHidden ? [collectionView] : [stateView]
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        focusMemory.preferredIndexPath(in: collectionView)
    }

    func update(items newItems: [PlexMetadata]) {
        items = newItems
        guard isViewLoaded else { return }
        mediaByID = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let ids = newItems.map(\.id)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        snapshot.reconfigureItems(ids.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil && !UIAccessibility.isReduceMotionEnabled)
        showEmptyState(ids.isEmpty)
    }

    private func showEmptyState(_ isEmpty: Bool) {
        collectionView.isHidden = isEmpty
        stateView.isHidden = !isEmpty
        if isEmpty {
            stateView.show(.empty(
                title: "Nothing Here",
                message: "This list is empty right now.",
                symbol: "rectangle.stack",
                action: TVStateView.Action(title: "Back") { [weak self] in
                    self?.navigationController?.popViewController(animated: true)
                }
            ))
        }
        setNeedsFocusUpdate()
    }

    private var isPoster: Bool { bucket == .recentlyAdded }

    private func makeLayout() -> UICollectionViewLayout {
        let poster = isPoster
        return UICollectionViewCompositionalLayout { _, _ in
            let section = TVShelf.grid(
                columns: poster ? 6 : 4,
                itemHeight: (poster ? TVCardStyle.poster : TVCardStyle.landscape).itemSize.height,
                header: true
            )
            return section
        }
    }

    private func configureDataSource() {
        let bucket = bucket
        let poster = TVPosterCell.registration()
        let landscape = TVLandscapeCell.registration()
        let header = TVSectionHeaderView.registration { [screenTitle] _ in TVSectionHeader(title: screenTitle) }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            let data = self?.mediaByID[id].map { TVHomeContent.card(for: $0, bucket: bucket) } ?? TVCardItem(id: id, title: "")
            let cell: UICollectionViewCell
            if bucket == .recentlyAdded {
                cell = collectionView.dequeueConfiguredReusableCell(using: poster, for: indexPath, item: data)
            } else {
                cell = collectionView.dequeueConfiguredReusableCell(using: landscape, for: indexPath, item: data)
            }
            cell.accessibilityIdentifier = "home.seeAll.\(id)"
            return cell
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func media(at indexPath: IndexPath) -> PlexMetadata? {
        dataSource.itemIdentifier(for: indexPath).flatMap { mediaByID[$0] }
    }

    private func playPause(at indexPath: IndexPath) {
        guard let media = media(at: indexPath) else { return }
        actions.playPause(media, from: self)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let media = media(at: indexPath) else { return }
        actions.openDetail(media, from: self)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        focusMemory.record(context)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let media = media(at: indexPath) else { return nil }
        return TVContextMenu.configuration(menu: actions.menu(for: media, from: self))
    }
}
