import CrucibleCore
import CrucibleDesign
import UIKit

/// "See All" for a Home rail: every card of the rail in a grid (six posters or four landscape cards
/// across) under the screen title. It stays live: Home pushes its refreshed rail into `update(items:)`.
final class TVHomeSeeAllViewController: TVScreenViewController {
    let bucket: HomeBucket
    private let actions: TVHomeActions
    private let screenTitle: String
    private var items: [PlexMetadata]
    private var mediaByID: [String: PlexMetadata] = [:]
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var posterStyle = TVCardStyle.poster

    init(env: TVAppEnvironment, bucket: HomeBucket, title: String, items: [PlexMetadata], onChange: @escaping @MainActor () -> Void) {
        self.bucket = bucket
        self.items = items
        screenTitle = title
        actions = TVHomeActions(env: env, onChange: onChange)
        super.init(layout: UICollectionViewLayout())
        self.title = title
        collectionView.collectionViewLayout = makeLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDataSource()
        update(items: items)
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        guard let media = media(at: indexPath) else { return false }
        actions.playPause(media, from: self)
        return true
    }

    func update(items newItems: [PlexMetadata]) {
        items = newItems
        guard isViewLoaded else { return }
        mediaByID = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let ids = newItems.map(\.id)
        adoptArtworkStyle(of: newItems)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        dataSource.applyReconfiguringExisting(snapshot, animated: view.window != nil)
        if ids.isEmpty {
            showEmptyState()
        } else if isShowingState {
            showContent()
        }
    }

    private func showEmptyState() {
        show(state: .empty(
            title: String(localized: "Nothing Here"),
            message: String(localized: "This list is empty right now."),
            symbol: "rectangle.stack",
            action: TVStateView.Action(title: String(localized: "Back")) { [weak self] in
                guard let self else { return }
                TVNavigation.pop(from: self)
            }
        ))
    }

    private var isPoster: Bool { bucket == .recentlyAdded }

    /// Recently Added lays its cards out in the shape most of their artwork has (posters, or the frames of personal videos);
    /// the snapshot that follows redraws the cards on screen in it.
    private func adoptArtworkStyle(of items: [PlexMetadata]) {
        guard isPoster else { return }
        let bucket = bucket
        let style = TVCardStyle.grid(aspect: ArtworkAspect.dominant(items.map {
            ArtworkAspect.of($0, path: TVHomeContent.card(for: $0, bucket: bucket).artworkPath)
        }))
        guard style != posterStyle else { return }
        posterStyle = style
        collectionView.collectionViewLayout.invalidateLayout()
    }

    private func makeLayout() -> UICollectionViewLayout {
        let poster = isPoster
        return UICollectionViewCompositionalLayout { [weak self] _, _ in
            let section = poster
                ? TVShelf.grid(self?.posterStyle ?? .poster)
                : TVShelf.grid(columns: 4, itemHeight: TVCardStyle.landscape.itemSize.height, header: false)
            section.boundarySupplementaryItems = [TVScreenTitleView.headerItem()]
            return section
        }
    }

    private func configureDataSource() {
        let bucket = bucket
        let poster = TVPosterCell.registration { [weak self] in self?.posterStyle ?? .poster }
        let landscape = TVLandscapeCell.registration()
        let header = TVScreenTitleView.headerRegistration { [weak self] _ in
            guard let self else { return nil }
            return TVScreenTitleContent(title: screenTitle, summary: Self.countText(items.count))
        }
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
        adopt(dataSource)
    }

    private static func countText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 title") : String(localized: "\(count) titles")
    }

    private func media(at indexPath: IndexPath) -> PlexMetadata? {
        dataSource.itemIdentifier(for: indexPath).flatMap { mediaByID[$0] }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let media = media(at: indexPath) else { return }
        actions.openDetail(media, from: self)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let media = media(at: indexPath) else { return nil }
        return TVContextMenu.configuration(menu: actions.menu(for: media, in: bucket, from: self))
    }
}
