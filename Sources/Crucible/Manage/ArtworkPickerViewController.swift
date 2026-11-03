import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Choose Poster or Choose Background: every picture the server's agents and the owner's uploads offer, with the one in use
/// marked. Picking one makes it the title's artwork.
final class ArtworkPickerViewController: UICollectionViewController {
    private let ratingKey: String
    private let kind: ArtworkKind
    private let api: APIClient
    private let onChosen: @MainActor () -> Void
    private var dataSource: UICollectionViewDiffableDataSource<Int, PlexArtworkChoice>!
    private var loadTask: Task<Void, Never>?

    init(ratingKey: String, kind: ArtworkKind, api: APIClient, onChosen: @escaping @MainActor () -> Void) {
        self.ratingKey = ratingKey
        self.kind = kind
        self.api = api
        self.onChosen = onChosen
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = kind == .poster
            ? String(localized: "Choose Poster", comment: "Title of the poster picker")
            : String(localized: "Choose Background", comment: "Title of the background picker")
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.collectionViewLayout = makeLayout()
        let poster = UICollectionView.CellRegistration<UICollectionViewCell, PlexArtworkChoice> { cell, _, choice in
            var config = PosterContentConfiguration()
            config.posterPath = choice.imagePath
            config.title = choice.selected == true ? String(localized: "In Use", comment: "Caption of the artwork a title uses now") : (choice.provider ?? "")
            cell.contentConfiguration = config
            cell.accessibilityIdentifier = "artwork.\(choice.ratingKey)"
        }
        let background = UICollectionView.CellRegistration<UICollectionViewCell, PlexArtworkChoice> { cell, _, choice in
            var config = LandscapeContentConfiguration()
            config.imagePath = choice.imagePath
            config.title = choice.selected == true ? String(localized: "In Use", comment: "Caption of the artwork a title uses now") : (choice.provider ?? "")
            config.placeholderIcon = "photo"
            cell.contentConfiguration = config
            cell.accessibilityIdentifier = "artwork.\(choice.ratingKey)"
        }
        let kind = kind
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, choice in
            kind == .poster
                ? collectionView.dequeueConfiguredReusableCell(using: poster, for: indexPath, item: choice)
                : collectionView.dequeueConfiguredReusableCell(using: background, for: indexPath, item: choice)
        }
        load()
    }

    private func makeLayout() -> UICollectionViewLayout {
        let kind = kind
        return UICollectionViewCompositionalLayout { _, environment in
            let width = environment.container.effectiveContentSize.width
            let columns = kind == .poster ? max(3, Int(width / 140)) : max(1, Int(width / 320))
            let itemWidth = NSCollectionLayoutDimension.fractionalWidth(1 / CGFloat(columns))
            let height: NSCollectionLayoutDimension = .estimated(kind == .poster ? 220 : 180)
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: itemWidth, heightDimension: height))
            item.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: height),
                repeatingSubitem: item,
                count: columns
            )
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
            return section
        }
    }

    private func load() {
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let choices = try await LibraryManagement.artwork(ratingKey: ratingKey, kind: kind, api: api)
                var snapshot = NSDiffableDataSourceSnapshot<Int, PlexArtworkChoice>()
                snapshot.appendSections([0])
                snapshot.appendItems(choices)
                await dataSource.apply(snapshot, animatingDifferences: false)
                if choices.isEmpty {
                    var empty = UIContentUnavailableConfiguration.empty()
                    empty.text = String(localized: "Nothing to Choose From", comment: "Artwork picker empty state")
                    contentUnavailableConfiguration = empty
                } else {
                    contentUnavailableConfiguration = nil
                }
            } catch {
                var failed = UIContentUnavailableConfiguration.empty()
                failed.text = ManageCopy.failed
                failed.secondaryText = ConnectionError.message(for: error)
                contentUnavailableConfiguration = failed
            }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let choice = dataSource.itemIdentifier(for: indexPath), choice.selected != true else { return }
        let api = api
        let key = ratingKey
        let kind = kind
        let onChosen = onChosen
        ManageMenus.run(host: self) { [weak self] in
            try await LibraryManagement.select(choice, kind: kind, ratingKey: key, api: api)
            self?.dismiss(animated: true)
            onChosen()
        }
    }
}
