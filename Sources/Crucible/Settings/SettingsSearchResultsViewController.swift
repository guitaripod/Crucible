import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Settings search: every setting whose name, keywords or description match, best first, each working right in the list
/// (a switch flips, a choice opens its menu) with where it lives written under it. An action runs from here; any other row
/// is opened by Settings itself.
final class SettingsSearchResultsViewController: UICollectionViewController, UISearchResultsUpdating {
    private let api: APIClient
    private lazy var navigator = SettingsNavigator(api: api, host: self)
    /// Opens a result that leads somewhere, or the category of any other result.
    var openEntry: ((SettingsEntry, UIView?) -> Void)?
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var results: [SettingsEntry] = []
    private var query = ""

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.keyboardDismissMode = .onDrag
        collectionView.accessibilityIdentifier = "settings.search.results"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            let section = NSCollectionLayoutSection.list(using: .wellRows(), layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let entry = results.first(where: { $0.id == id }) else { return }
            SettingsRows.configure(cell, entry: entry, subtitle: SettingsRows.breadcrumb(for: entry), status: nil) { [weak self] in
                self?.reconfigure(id)
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        results = SettingsCatalog.search(query, on: .phone)
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(results.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: false)
        if results.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            var empty = UIContentUnavailableConfiguration.search()
            empty.text = String(localized: "No Settings Found", comment: "Settings search empty state title")
            empty.secondaryText = String(localized: "Try another word, like quality, subtitles or notifications.", comment: "Settings search empty state message")
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func reconfigure(_ id: String) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(id) != nil else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let entry = results.first(where: { $0.id == id }) else { return }
        let source = collectionView.cellForItem(at: indexPath)
        if case .action(let action) = entry.item {
            navigator.perform(action, source: source)
        } else {
            openEntry?(entry, source)
        }
    }
}
