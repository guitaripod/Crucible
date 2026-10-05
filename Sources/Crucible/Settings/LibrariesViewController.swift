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
        loadTask = Task { [weak self] in
            guard let self, let container = try? await api.requestContainer(.sections), !Task.isCancelled else { return }
            LibraryVisibility.record(directories: container.Directory ?? [])
        }
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            let section = self?.dataSource?.sectionIdentifier(for: index)
            config.footerMode = section == .libraries ? .supplementary : .none
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        let libraries = LibraryVisibility.libraries
        snapshot.appendSections([.libraries])
        snapshot.appendItems(libraries.map { .library($0.id) }, toSection: .libraries)
        if LibraryVisibility.hasOverrides {
            snapshot.appendSections([.reset])
            snapshot.appendItems([.reset], toSection: .reset)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil && !UIAccessibility.isReduceMotionEnabled)
        updateEmptyState(isEmpty: libraries.isEmpty)
    }

    private func updateEmptyState(isEmpty: Bool) {
        guard isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.loading()
        config.text = "Loading Libraries"
        contentUnavailableConfiguration = config
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            cell.applyThemedBackground()
            cell.accessories = []
            switch item {
            case .library(let id):
                guard let library = LibraryVisibility.libraries.first(where: { $0.id == id }) else { return }
                cell.contentConfiguration = self?.rowConfiguration(for: library)
            case .reset:
                var content = UIListContentConfiguration.cell()
                content.text = "Reset to Plex Defaults"
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
            content.text = "Libraries Plex hides from Home start switched off. At least one library stays on."
            content.textProperties.font = Theme.Font.caption1Regular
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func rowConfiguration(for library: LibraryVisibility.Library) -> IconRowContentConfiguration {
        let included = LibraryVisibility.isIncluded(library.id)
        let isLastIncluded = included && LibraryVisibility.libraries.filter { LibraryVisibility.isIncluded($0.id) }.count <= 1
        var content = IconRowContentConfiguration(
            symbol: library.symbol,
            title: library.title,
            subtitle: library.hiddenOnPlex ? "Hidden from Home in Plex" : nil
        )
        content.toggle = .init(isOn: included, isEnabled: !isLastIncluded) { isOn in
            if !LibraryVisibility.setIncluded(library.id, isOn) {
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
