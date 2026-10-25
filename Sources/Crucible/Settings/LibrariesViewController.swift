import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Picks which libraries appear on Home and count toward Statistics. A switch per library, each
/// defaulting to what Plex says about Home; at least one library always stays on.
final class LibrariesViewController: UICollectionViewController {
    private enum Section: Hashable {
        case libraries, reset
    }

    private enum Item: Hashable {
        case library(Int)
        case reset
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var loadTask: Task<Void, Never>?
    private var observer: UUID?

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
        title = "Libraries"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        if let observer {
            Task { @MainActor in LibraryVisibility.removeObserver(observer) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .always
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.allowsKeyboardFocus()
        collectionView.showsVerticalScrollIndicator = false
        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
        applySnapshot()
        observer = LibraryVisibility.addObserver { [weak self] in
            self?.applySnapshot()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        refreshLibraries()
    }

    private func refreshLibraries() {
        loadTask?.cancel()
        loadTask = Task { [api] in
            await LibrariesSettings.refresh(api: api)
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            let section = self?.dataSource?.sectionIdentifier(for: index)
            config.footerMode = section == .libraries ? .supplementary : .none
            let listSection = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(listSection, environment)
            return listSection
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.libraries])
        snapshot.appendItems(LibrariesSettings.libraryIDs.map { .library($0) }, toSection: .libraries)
        if LibrariesSettings.canReset {
            snapshot.appendSections([.reset])
            snapshot.appendItems([.reset], toSection: .reset)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil && !UIAccessibility.isReduceMotionEnabled)
        updateEmptyState(isEmpty: LibrariesSettings.isLoading)
    }

    private func updateEmptyState(isEmpty: Bool) {
        guard isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.loading()
        config.text = LibrariesSettings.loadingTitle
        contentUnavailableConfiguration = config
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            cell.applyThemedBackground()
            cell.accessories = []
            switch item {
            case .library(let id):
                guard let row = LibrariesSettings.row(id: id) else { return }
                cell.contentConfiguration = self?.rowConfiguration(for: row)
            case .reset:
                var content = UIListContentConfiguration.cell()
                content.text = LibrariesSettings.resetTitle
                content.textProperties.color = Theme.Color.accentText
                content.textProperties.font = Theme.Font.headline
                content.textProperties.alignment = .center
                content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
                cell.contentConfiguration = content
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { cell, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = LibrariesSettings.footerText
            content.textProperties.font = Theme.Font.caption1Regular
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func rowConfiguration(for row: LibrariesSettings.Row) -> IconRowContentConfiguration {
        var content = IconRowContentConfiguration(symbol: row.symbol, title: row.title, subtitle: row.subtitle)
        content.toggle = .init(isOn: row.isIncluded, isEnabled: !row.isLocked) { [id = row.id] isOn in
            if !LibraryVisibility.setIncluded(id, isOn) {
                Haptics.error()
            }
        }
        return content
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .reset
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard dataSource.itemIdentifier(for: indexPath) == .reset else { return }
        Haptics.light()
        LibraryVisibility.resetToPlexDefaults()
    }
}
