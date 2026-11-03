import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Home's rows in the order Home draws them: a switch turns each one on or off and the handle drags it to another place.
/// Changes show on Home at once.
final class HomeRowsViewController: UICollectionViewController {
    private var dataSource: UICollectionViewDiffableDataSource<Int, HomeRow>!

    init() {
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SettingsCatalog.title(.homeRows)
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "settings.homeRows"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.footerMode = .supplementary
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        configureDataSource()
        applySnapshot(animated: false)
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: String(localized: "Reset", comment: "Button that puts Home's rows back in their default order"), primaryAction: UIAction { [weak self] _ in
            HomeLayout.reset()
            Haptics.success()
            self?.applySnapshot(animated: true)
        })
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, HomeRow> { [weak self] cell, _, row in
            var content = IconRowContentConfiguration(symbol: row.symbol, title: row.title, subtitle: row.explanation)
            content.toggle = .init(isOn: HomeLayout.isOn(row)) { isOn in
                Haptics.selection()
                HomeLayout.setOn(row, isOn)
                self?.reconfigure(row)
            }
            cell.contentConfiguration = content
            cell.accessories = [.reorder(displayed: .always)]
            cell.applyThemedBackground()
            cell.accessibilityIdentifier = "settings.homeRows.\(row.rawValue)"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        dataSource.reorderingHandlers.canReorderItem = { _ in true }
        dataSource.reorderingHandlers.didReorder = { transaction in
            let order = transaction.finalSnapshot.itemIdentifiers
            let entries = HomeLayout.entries()
            HomeLayout.save(order.compactMap { row in entries.first { $0.row == row } })
            Haptics.selection()
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { cell, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = String(localized: "Drag a row by its handle to move it. Continue Watching's newest title stays the big card at the top of Home.", comment: "Footer of the Home rows settings")
            content.textProperties.font = Theme.Font.caption1Regular
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, HomeRow>()
        snapshot.appendSections([0])
        snapshot.appendItems(HomeLayout.entries().map(\.row))
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func reconfigure(_ row: HomeRow) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([row])
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}
