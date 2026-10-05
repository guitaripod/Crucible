@preconcurrency import UIKit

final class SettingsViewController: UICollectionViewController {
    enum Section: Int, CaseIterable {
        case playback, downloads, home, appearance, support, account

        var title: String? {
            switch self {
            case .playback: return "Playback"
            case .downloads: return "Downloads"
            case .home: return "Home & Statistics"
            case .appearance: return "Appearance"
            case .support: return "Support"
            case .account: return nil
            }
        }
    }

    enum Item: Hashable {
        case streamingQuality, skipIntro, autoplay
        case downloadQuality, downloadCellular, deleteWatched, manageStorage
        case libraries
        case appearance, libraryGrid
        case shareLogs, clearCache, sourceCode
        case signOut

        var isSelectable: Bool {
            switch self {
            case .manageStorage, .libraries, .shareLogs, .clearCache, .sourceCode, .signOut: return true
            default: return false
            }
        }
    }

    private let api: APIClient
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var loadTask: Task<Void, Never>?
    private var storageText = "None"
    private var cacheText = "…"

    init(api: APIClient) {
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.showsVerticalScrollIndicator = false
        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
        applySnapshot()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadSizes()
        reconfigure([.libraries])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            let section = self?.dataSource?.sectionIdentifier(for: index)
            config.headerMode = section?.title == nil ? .none : .supplementary
            config.footerMode = (section == .playback || section == .home || section == .account) ? .supplementary : .none
            if section == .account {
                config.itemSeparatorHandler = nil
            }
            return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.streamingQuality, .skipIntro, .autoplay], toSection: .playback)
        snapshot.appendItems([.downloadQuality, .downloadCellular, .deleteWatched, .manageStorage], toSection: .downloads)
        snapshot.appendItems([.libraries], toSection: .home)
        snapshot.appendItems([.appearance, .libraryGrid], toSection: .appearance)
        snapshot.appendItems([.shareLogs, .clearCache, .sourceCode], toSection: .support)
        snapshot.appendItems([.signOut], toSection: .account)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func loadSizes() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let usedBytes = await DownloadManager.shared.totalBytesOnDisk()
            let cacheBytes = await ImageCacheMeter.totalBytes()
            guard let self, !Task.isCancelled else { return }
            storageText = usedBytes > 0 ? Formatters.fileSize(usedBytes) : "None"
            cacheText = ImageCacheMeter.formatted(cacheBytes)
            reconfigure([.manageStorage, .clearCache])
        }
    }

    private func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(items.filter { snapshot.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configureDataSource() {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            cell.applyThemedBackground()
            switch item {
            case .streamingQuality:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "dial.high", title: "Streaming Quality",
                    value: Preferences.streamingQuality.title, menu: streamingQualityMenu()
                )
            case .skipIntro:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "forward.end", title: "Skip Intro", badge: "NEW",
                    value: Preferences.skipIntroMode.title, menu: skipIntroMenu()
                )
            case .autoplay:
                toggleRow(cell, symbol: "play", title: "Autoplay Next Episode", isOn: Preferences.autoplayNextEpisode) { newValue in
                    Preferences.autoplayNextEpisode = newValue
                }
            case .downloadQuality:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "arrow.down.circle", title: "Download Quality",
                    value: Preferences.downloadQuality.title, menu: downloadQualityMenu()
                )
            case .downloadCellular:
                toggleRow(cell, symbol: "cellularbars", title: "Download over Cellular", isOn: Preferences.downloadOverCellular) { newValue in
                    Preferences.downloadOverCellular = newValue
                    DownloadManager.shared.cellularPreferenceChanged()
                }
            case .deleteWatched:
                toggleRow(cell, symbol: "trash", title: "Delete Watched Downloads", isOn: Preferences.deleteWatchedDownloads) { newValue in
                    Preferences.deleteWatchedDownloads = newValue
                }
            case .manageStorage:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "internaldrive", title: "Manage Storage", value: storageText)
                cell.accessories = [.disclosureIndicator()]
            case .libraries:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "rectangle.stack", title: "Libraries", value: Self.librariesSummary()
                )
                cell.accessories = [.disclosureIndicator()]
            case .appearance:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "sun.max", title: "Appearance",
                    value: Preferences.appearance.title, menu: appearanceMenu()
                )
            case .libraryGrid:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "square.grid.3x3", title: "Library Grid",
                    value: "\(Preferences.libraryColumns) Columns", menu: libraryGridMenu()
                )
            case .shareLogs:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "doc.text", title: "Share Diagnostic Logs")
                cell.accessories = [.disclosureIndicator()]
            case .clearCache:
                cell.contentConfiguration = IconRowContentConfiguration(symbol: "trash", title: "Clear Image Cache", value: cacheText)
            case .sourceCode:
                cell.contentConfiguration = IconRowContentConfiguration(
                    symbol: "chevron.left.forwardslash.chevron.right", title: "Source Code", value: "GitHub"
                )
            case .signOut:
                var content = UIListContentConfiguration.cell()
                content.text = "Sign Out"
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

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section)?.title
            content.textProperties.transform = .uppercase
            content.textProperties.font = Theme.Font.footnoteSemibold
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
            cell.accessibilityTraits = .header
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedFooter()
            content.textProperties.font = Theme.Font.caption1Regular
            content.textProperties.color = Theme.Color.labelSecondary
            switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .playback:
                content.text = "Skip Intro can show a button, skip automatically, or stay out of the way."
            case .home:
                content.text = "Choose which libraries appear on Home and count toward your statistics."
            case .account:
                content.text = "Crucible \(AboutViewController.versionText) (\(AboutViewController.buildText))"
                content.textProperties.alignment = .center
                content.textProperties.color = Theme.Color.labelTertiary
            default:
                content.text = nil
            }
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            if kind == UICollectionView.elementKindSectionHeader {
                return collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
    }

    private func toggleRow(_ cell: UICollectionViewListCell, symbol: String, title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        var content = IconRowContentConfiguration(symbol: symbol, title: title)
        content.toggle = .init(isOn: isOn, onChange: onChange)
        cell.contentConfiguration = content
    }

    private static func librariesSummary() -> String? {
        let libraries = LibraryVisibility.libraries
        guard !libraries.isEmpty else { return nil }
        let included = libraries.filter { LibraryVisibility.isIncluded($0.id) }.count
        return included == libraries.count ? "All" : "\(included) of \(libraries.count)"
    }

    private func streamingQualityMenu() -> UIMenu {
        let current = Preferences.streamingQuality
        let actions = Preferences.Quality.allCases.map { quality in
            UIAction(title: quality.title, state: quality == current ? .on : .off) { [weak self] _ in
                Haptics.selection()
                Preferences.streamingQuality = quality
                self?.reconfigure([.streamingQuality])
            }
        }
        return UIMenu(title: "Streaming Quality", children: actions)
    }

    private func skipIntroMenu() -> UIMenu {
        let current = Preferences.skipIntroMode
        let actions = Preferences.SkipIntroMode.allCases.map { mode in
            UIAction(title: mode.title, state: mode == current ? .on : .off) { [weak self] _ in
                Haptics.selection()
                Preferences.skipIntroMode = mode
                self?.reconfigure([.skipIntro])
            }
        }
        return UIMenu(title: "Skip Intro", children: actions)
    }

    private func downloadQualityMenu() -> UIMenu {
        let current = Preferences.downloadQuality
        let actions = DownloadQuality.allCases.map { quality in
            let action = UIAction(title: quality.title, subtitle: quality.detail, state: quality == current ? .on : .off) { [weak self] _ in
                Haptics.selection()
                Preferences.downloadQuality = quality
                self?.reconfigure([.downloadQuality])
            }
            return action
        }
        return UIMenu(title: "Download Quality", children: actions)
    }

    private func appearanceMenu() -> UIMenu {
        let current = Preferences.appearance
        let actions = Preferences.Appearance.allCases.map { appearance in
            UIAction(title: appearance.title, state: appearance == current ? .on : .off) { [weak self] _ in
                Haptics.selection()
                self?.apply(appearance)
            }
        }
        return UIMenu(title: "Appearance", children: actions)
    }

    private func apply(_ appearance: Preferences.Appearance) {
        Preferences.appearance = appearance
        if let window = view.window, !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve) {
                AppearanceController.apply()
            }
        } else {
            AppearanceController.apply()
        }
        reconfigure([.appearance])
    }

    private func libraryGridMenu() -> UIMenu {
        let current = Preferences.libraryColumns
        let actions = [2, 3].map { columns in
            UIAction(title: "\(columns) Columns", state: columns == current ? .on : .off) { [weak self] _ in
                Haptics.selection()
                Preferences.libraryColumns = columns
                self?.reconfigure([.libraryGrid])
            }
        }
        return UIMenu(title: "Library Grid", children: actions)
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath)?.isSelectable ?? false
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .manageStorage:
            tabBarController?.selectedIndex = 2
        case .libraries:
            navigationController?.pushViewController(LibrariesViewController(api: api), animated: true)
        case .shareLogs:
            shareLogs(from: collectionView.cellForItem(at: indexPath))
        case .clearCache:
            confirmClearCache()
        case .sourceCode:
            if let url = AboutViewController.sourceURL {
                UIApplication.shared.open(url)
            }
        case .signOut:
            confirmSignOut()
        default:
            break
        }
    }

    private func shareLogs(from source: UIView?) {
        Task { [weak self] in
            let url = await DiagnosticLogExporter.export()
            guard let self else { return }
            guard let url else {
                let alert = UIAlertController(title: "No Logs Yet", message: "There are no diagnostic logs to share.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
                return
            }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in
                try? FileManager.default.removeItem(at: url)
            }
            activity.popoverPresentationController?.sourceView = source ?? view
            activity.popoverPresentationController?.sourceRect = source?.bounds ?? .zero
            present(activity, animated: true)
        }
    }

    private func confirmClearCache() {
        let alert = UIAlertController(
            title: "Clear Image Cache?",
            message: "Posters and backdrops will be downloaded again as you browse.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            Task { [weak self] in
                await ImageLoader.shared.clearCache()
                Haptics.success()
                self?.loadSizes()
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func confirmSignOut() {
        let alert = UIAlertController(title: "Sign Out", message: "Are you sure you want to sign out?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
            guard let self else { return }
            DownloadManager.shared.handleSignOut()
            StatsManager.shared.handleSignOut()
            HomeSnapshotStore.destroy()
            Task { await ImageLoader.shared.clearCache() }
            ServerBootstrap.clear()
            if let scene = view.window?.windowScene?.delegate as? SceneDelegate {
                scene.reconfigureRoot()
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
