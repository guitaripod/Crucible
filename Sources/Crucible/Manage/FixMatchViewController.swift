import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Fix Match: searches the server's agents for the right movie or show, starting from the title as it is, and matches the
/// one picked. A year typed after the name ("Dune 2021") narrows the search.
final class FixMatchViewController: UICollectionViewController, UISearchBarDelegate {
    private let item: PlexMetadata
    private let api: APIClient
    private let onMatched: @MainActor () -> Void
    private let searchBar = UISearchBar()
    private var dataSource: UICollectionViewDiffableDataSource<Int, PlexMatchResult>!
    private var searchTask: Task<Void, Never>?

    init(item: PlexMetadata, api: APIClient, onMatched: @escaping @MainActor () -> Void) {
        self.item = item
        self.api = api
        self.onMatched = onMatched
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { searchTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Fix Match", comment: "Title of the Fix Match screen")
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.keyboardDismissMode = .onDrag
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            NSCollectionLayoutSection.list(using: .wellRows(), layoutEnvironment: environment)
        }
        searchBar.text = MatchQuery.text(for: item)
        searchBar.placeholder = String(localized: "Title and year", comment: "Placeholder of the Fix Match search field")
        searchBar.delegate = self
        searchBar.sizeToFit()
        navigationItem.titleView = searchBar
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, PlexMatchResult> { cell, _, result in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = [result.name, result.year.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            content.secondaryText = result.score.map { String(localized: "\($0)% match", comment: "How sure the server's agent is of a Fix Match result, e.g. 92% match") }
            content.textProperties.font = Theme.Font.headline
            content.secondaryTextProperties.color = Theme.Color.labelSecondary
            content.image = UIImage(systemName: "film")
            content.imageProperties.maximumSize = CGSize(width: 40, height: 60)
            cell.contentConfiguration = content
            cell.accessories = result.matched == true ? [.checkmark()] : []
            cell.applyThemedBackground()
            cell.accessibilityIdentifier = "fixMatch.result.\(result.guid)"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, result in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: result)
        }
        search()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        search()
    }

    /// "Dune 2021" searches for Dune from 2021; a name without a year searches every year.
    private func search() {
        let query = MatchQuery(parsing: searchBar.text ?? "")
        searchTask?.cancel()
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results = try await LibraryManagement.matches(ratingKey: item.id, title: query.name, year: query.year, api: api)
                guard !Task.isCancelled else { return }
                var snapshot = NSDiffableDataSourceSnapshot<Int, PlexMatchResult>()
                snapshot.appendSections([0])
                snapshot.appendItems(results)
                await dataSource.apply(snapshot, animatingDifferences: false)
                contentUnavailableConfiguration = results.isEmpty ? Self.emptyConfiguration() : nil
            } catch {
                guard !Task.isCancelled else { return }
                var failed = UIContentUnavailableConfiguration.empty()
                failed.text = ManageCopy.failed
                failed.secondaryText = ConnectionError.message(for: error)
                contentUnavailableConfiguration = failed
            }
        }
    }

    private static func emptyConfiguration() -> UIContentUnavailableConfiguration {
        var empty = UIContentUnavailableConfiguration.search()
        empty.text = String(localized: "No Matches", comment: "Fix Match empty state title")
        empty.secondaryText = String(localized: "Try the original title, or add the year.", comment: "Fix Match empty state message")
        return empty
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let result = dataSource.itemIdentifier(for: indexPath) else { return }
        let name = [result.name, result.year.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        ManageMenus.confirm(
            title: String(localized: "Match to \(name)?", comment: "Fix Match confirmation title, e.g. Match to Dune (2021)?"),
            message: String(localized: "The title takes this one's details, artwork and ratings.", comment: "Fix Match confirmation message"),
            action: String(localized: "Match", comment: "Button that confirms a Fix Match choice"),
            host: self
        ) { [weak self] in
            guard let self else { return }
            let api = api
            let key = item.id
            let onMatched = onMatched
            ManageMenus.run(host: self) {
                try await LibraryManagement.match(ratingKey: key, to: result, api: api)
                self.dismiss(animated: true)
                try? await Task.sleep(for: .seconds(2))
                onMatched()
            }
        }
    }
}
