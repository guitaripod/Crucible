import CrucibleCore
import CrucibleDesign
import UIKit

/// Every title of one genre as a poster grid sorted by title. The first page of each library the
/// genre spans paints the grid and the rest arrives as focus nears the end, like a library grid;
/// loading, empty and failed states come from the shared screen host.
final class TVGenreBrowseViewController: TVScreenViewController {
    private let env: TVAppEnvironment
    private let genre: SearchGenre
    private let model: GenreGridModel
    private var dataSource: UICollectionViewDiffableDataSource<Int, PlexMetadata>!

    init(env: TVAppEnvironment, genre: SearchGenre) {
        self.env = env
        self.genre = genre
        model = GenreGridModel(genre: genre, loader: SearchLoader(api: env.api))
        super.init(layout: UICollectionViewLayout())
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, _ in
            let grid = TVShelf.grid(columns: 6)
            grid.boundarySupplementaryItems = [TVScreenTitleView.headerItem()]
            return grid
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureDataSource()
        model.onUpdate = { [weak self] update in self?.render(update) }
        show(state: .loading(title: nil))
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        model.appear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappear()
    }

    private func configureDataSource() {
        let posters = TVPosterCell.registration()
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: posters, for: indexPath, item: TVSearchCards.poster(item))
        }
        adopt(dataSource)
        let titles = TVScreenTitleView.headerRegistration { [weak self] _ in
            self.map { TVScreenTitleContent(title: $0.genre.title, summary: $0.countText) }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: titles, for: indexPath)
        }
    }

    private var countText: String {
        let count = model.pager.totalCount ?? model.items.count
        return count == 1 ? "1 title" : "\(count) titles"
    }

    private func render(_ update: GenreGridModel.Update) {
        switch update {
        case .contentState:
            renderState()
        case .pageLoaded:
            applyItems()
        case .pageFailed:
            break
        }
    }

    private func renderState() {
        switch model.contentState {
        case .loading:
            show(state: .loading(title: nil))
        case .content:
            applyItems()
            showContent()
        case .empty:
            show(state: .empty(
                title: SearchCopy.genreEmptyTitle(genre.title),
                message: SearchCopy.genreEmptyMessage,
                symbol: "film.stack",
                action: TVStateView.Action(title: "Back") { [weak self] in
                    guard let self else { return }
                    TVNavigation.pop(from: self)
                }
            ))
        case .failed(let message):
            show(state: .error(title: SearchCopy.genreFailureTitle(genre.title), message: message, retryTitle: SearchCopy.retry) { [weak self] in
                self?.model.appear()
            })
        }
    }

    private func applyItems() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, PlexMetadata>()
        snapshot.appendSections([0])
        snapshot.appendItems(model.items, toSection: 0)
        dataSource.applyReconfiguringExisting(snapshot)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let screen: UIViewController
        switch SearchDestination(item: item) {
        case .show(let ratingKey, let initialSeasonKey):
            screen = TVScreens.showDetail(env, ratingKey: ratingKey, initialSeasonKey: initialSeasonKey)
        case .movie, .episode:
            screen = TVScreens.movieDetail(env, ratingKey: item.id, mediaType: "movie")
        }
        TVNavigation.push(screen, from: self)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.collectionView(collectionView, didUpdateFocusIn: context, with: coordinator)
        if let index = context.nextFocusedIndexPath?.item {
            model.itemFocused(at: index)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath), item.mediaType == "movie" else {
            return nil
        }
        let play = UIAction(title: SearchItemActions.playTitle(for: item), image: UIImage(systemName: "play.fill")) { [weak self] _ in
            self?.play(item)
        }
        return TVContextMenu.configuration(menu: UIMenu(children: [play]))
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        guard let item = dataSource.itemIdentifier(for: indexPath), item.mediaType == "movie" else { return false }
        play(item)
        return true
    }

    private func play(_ item: PlexMetadata) {
        TVScreens.play(env, request: TVPlaybackRequest(item: item), from: tabBarController ?? self)
    }
}
