import CrucibleCore
import CrucibleDesign
import CrucibleStats
@preconcurrency import UIKit

/// The first Settings screen: a search field that finds any setting by name or by what it does, Crucible Pro, one row per
/// category with the value that matters most in it, and signing out.
final class SettingsViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case pro, categories, account
    }

    enum Item: Hashable {
        case pro
        case category(SettingsCategory)
        case signOut, leaveDemo
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var proObservation: ProObservation?
    private var demoObservation: DemoObservation?
    private lazy var navigator = SettingsNavigator(api: api, host: self)
    private lazy var results = SettingsSearchResultsViewController(api: api)
    private lazy var searchController = UISearchController(searchResultsController: results)

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Settings")
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.allowsKeyboardFocus()
        collectionView.showsVerticalScrollIndicator = false
        collectionView.accessibilityIdentifier = "settings.root"
        collectionView.collectionViewLayout = makeLayout()
        configureSearch()
        configureDataSource()
        applySnapshot()
        proObservation = ProObservation { [weak self] in self?.reconfigure([.pro]) }
        demoObservation = DemoObservation { [weak self] in self?.demoChanged() }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        reconfigure(SettingsCatalog.categories(on: .phone).map(Item.category))
    }

    private func configureSearch() {
        searchController.searchResultsUpdater = results
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Search Settings", comment: "Placeholder of the Settings search field")
        searchController.searchBar.searchTextField.accessibilityIdentifier = "settings.search"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        results.openEntry = { [weak self] entry, source in self?.open(entry, source: source) }
    }

    /// A search result: a row that leads somewhere opens that screen, any other opens its category with the row highlighted.
    private func open(_ entry: SettingsEntry, source: UIView?) {
        searchController.isActive = false
        if case .destination(let destination) = entry.item {
            navigator.open(destination, source: source)
        } else {
            navigationController?.pushViewController(SettingsCategoryViewController(api: api, category: entry.category, highlighting: entry.id), animated: true)
        }
    }

    private func demoChanged() {
        guard DemoMode.shared.isActive else { return }
        reconfigure([.pro])
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            let section = self?.dataSource?.sectionIdentifier(for: index)
            config.headerMode = .none
            config.footerMode = section == .account ? .supplementary : .none
            if section == .account { config.itemSeparatorHandler = nil }
            let listSection = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(listSection, environment)
            return listSection
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases.filter { $0 != .pro || ProAccess.shared.isStoreBacked })
        if ProAccess.shared.isStoreBacked { snapshot.appendItems([.pro], toSection: .pro) }
        snapshot.appendItems(SettingsCatalog.categories(on: .phone).map(Item.category), toSection: .categories)
        snapshot.appendItems([DemoMode.shared.isActive ? .leaveDemo : .signOut], toSection: .account)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(items.filter { snapshot.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            cell.accessories = []
            cell.applyThemedBackground()
            switch item {
            case .pro:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "sparkles", title: Self.proTitle(), subtitle: Self.proSubtitle())
                cell.accessories = [.disclosureIndicator()]
            case .category(let category):
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: category.symbol,
                    title: category.title(on: .phone),
                    subtitle: SettingsCatalog.summary(of: category, on: .phone)
                )
                cell.accessories = [.disclosureIndicator()]
                cell.accessibilityIdentifier = "settings.category.\(category.rawValue)"
            case .signOut, .leaveDemo:
                var content = UIListContentConfiguration.cell()
                content.text = item == .leaveDemo ? DemoPhoneCopy.leaveTitle : String(localized: "Sign Out")
                content.textProperties.color = Theme.Color.destructive
                content.textProperties.font = Theme.Font.headline
                content.textProperties.alignment = .center
                content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
                cell.contentConfiguration = content
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { cell, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = String(localized: "Crucible \(AppInfo.versionSummary)")
            content.textProperties.font = Theme.Font.caption1Regular
            content.textProperties.alignment = .center
            content.textProperties.color = Theme.Color.labelTertiary
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
    }

    private static func proTitle() -> String {
        showsDemoOffer ? DemoPhoneCopy.unlockProTitle : "Crucible Pro"
    }

    private static func proSubtitle() -> String {
        guard let entitlement = ProAccess.shared.status.entitlement else { return DemoPhoneCopy.unlockProDetail }
        return entitlement.summary()
    }

    /// While the demo runs everything is unlocked, but the row still offers Pro, so it reads as the offer instead of a status.
    private static var showsDemoOffer: Bool {
        DemoMode.shared.isActive && !ProAccess.shared.isPro
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .pro:
            openPro()
        case .category(let category):
            navigationController?.pushViewController(SettingsCategoryViewController(api: api, category: category), animated: true)
        case .signOut:
            confirmSignOut()
        case .leaveDemo:
            DemoCoordinator.shared.confirmLeaving(from: self)
        }
    }

    private func openPro() {
        guard ProAccess.shared.isPro else {
            PaywallPresenter.showOffer(from: self)
            return
        }
        navigationController?.pushViewController(ProStatusViewController(), animated: true)
    }

    private func confirmSignOut() {
        let alert = UIAlertController(title: String(localized: "Sign Out"), message: String(localized: "Are you sure you want to sign out?"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Sign Out"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            AccountSessionReset.signOut(.phone)
            if let scene = view.window?.windowScene?.delegate as? SceneDelegate {
                scene.reconfigureRoot()
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }
}
