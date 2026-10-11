import CrucibleCore
import CrucibleDesign
import UIKit

final class AboutViewController: UICollectionViewController {
    enum Item: Int, Hashable, CaseIterable {
        case version, build, license, source
    }

    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!

    init() {
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "About Crucible"
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas

        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.footerMode = .supplementary
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
        configureDataSource()

        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        snapshot.appendSections([0])
        snapshot.appendItems(Item.allCases, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            var content: IconRowContentConfiguration
            switch item {
            case .version:
                content = IconRowContentConfiguration(symbol: "info.circle", title: "Version", value: AppInfo.versionText)
            case .build:
                content = IconRowContentConfiguration(symbol: "hammer", title: "Build", value: AppInfo.buildText)
            case .license:
                content = IconRowContentConfiguration(symbol: "doc.text", title: "License", value: AppInfo.licenseName)
            case .source:
                content = IconRowContentConfiguration(symbol: "chevron.left.forwardslash.chevron.right", title: "Source Code", value: "GitHub")
            }
            cell.contentConfiguration = content
            cell.accessories = []
            cell.applyThemedBackground()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { cell, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = AppInfo.licenseSummary
            content.textProperties.font = Theme.Font.caption1Regular
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .source
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if let url = AppInfo.sourceURL {
            UIApplication.shared.open(url)
        }
    }
}
