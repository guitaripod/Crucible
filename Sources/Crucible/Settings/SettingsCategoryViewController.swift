import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// One category of Settings: its rows in their sections, each with a line saying what it does, and Restore Defaults at the
/// end once anything in it was changed.
final class SettingsCategoryViewController: UICollectionViewController {
    private enum Item: Hashable {
        case entry(String)
        case restoreDefaults
    }

    private let api: APIClient
    private let category: SettingsCategory
    private let highlightedEntryID: String?
    private lazy var navigator = SettingsNavigator(api: api, host: self)
    private var dataSource: UICollectionViewDiffableDataSource<Int, Item>!
    private var sections: [(title: String?, entries: [SettingsEntry])] = []
    private var statuses: [String: String] = [:]
    private var statusTask: Task<Void, Never>?

    init(api: APIClient, category: SettingsCategory, highlighting entryID: String? = nil) {
        self.api = api
        self.category = category
        highlightedEntryID = entryID
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { statusTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = category.title(on: .phone)
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.allowsKeyboardFocus()
        collectionView.accessibilityIdentifier = "settings.category.\(category.rawValue)"
        collectionView.collectionViewLayout = makeLayout()
        navigator.onChange = { [weak self] in self?.refresh() }
        configureDataSource()
        sections = SettingsCatalog.sections(of: category, on: .phone)
        applySnapshot()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        flashHighlightedEntry()
    }

    private func refresh() {
        applySnapshot()
        loadStatuses()
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] index, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            let title = self?.sections[safe: index]?.title
            config.headerMode = title == nil ? .none : .supplementary
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
    }

    private func configureDataSource() {
        let entryRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let entry = entry(withID: id) else { return }
            SettingsRows.configure(cell, entry: entry, subtitle: entry.explanation, status: statuses[id]) { [weak self] in
                self?.settingChanged(entry)
            }
        }
        let restoreRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Restore Defaults", comment: "Button at the end of a settings category that resets its settings")
            content.textProperties.color = Theme.Color.accent
            content.textProperties.font = Theme.Font.headline
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.applyThemedBackground()
            cell.accessibilityIdentifier = "settings.restoreDefaults"
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .entry(let id):
                return collectionView.dequeueConfiguredReusableCell(using: entryRegistration, for: indexPath, item: id)
            case .restoreDefaults:
                return collectionView.dequeueConfiguredReusableCell(using: restoreRegistration, for: indexPath, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            var content = UIListContentConfiguration.groupedHeader()
            content.text = self?.sections[safe: indexPath.section]?.title
            content.textProperties.transform = .uppercase
            content.textProperties.font = Theme.Font.footnoteSemibold
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
            cell.accessibilityTraits = .header
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Item>()
        for (index, section) in sections.enumerated() {
            snapshot.appendSections([index])
            snapshot.appendItems(section.entries.map { .entry($0.id) }, toSection: index)
        }
        if SettingsCatalog.preferences(in: category, on: .phone).contains(where: \.isChanged), let last = snapshot.sectionIdentifiers.last {
            snapshot.appendItems([.restoreDefaults], toSection: last)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
    }

    private func loadStatuses() {
        statusTask?.cancel()
        let entries = sections.flatMap(\.entries)
        statusTask = Task { [weak self] in
            for entry in entries {
                let status = await SettingsNavigator.status(of: entry.item)
                guard let self, !Task.isCancelled else { return }
                guard statuses[entry.id] != status else { continue }
                statuses[entry.id] = status
                var snapshot = dataSource.snapshot()
                guard snapshot.indexOfItem(.entry(entry.id)) != nil else { continue }
                snapshot.reconfigureItems([.entry(entry.id)])
                await dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
    }

    private func settingChanged(_ entry: SettingsEntry) {
        applySnapshot()
        if entry.item == .preference(.libraryGrid) || entry.item == .preference(.appearance) {
            loadStatuses()
        }
    }

    private func entry(withID id: String) -> SettingsEntry? {
        sections.lazy.flatMap(\.entries).first { $0.id == id }
    }

    /// A search result opens its category with the row it found briefly highlighted.
    private func flashHighlightedEntry() {
        guard let id = highlightedEntryID, let indexPath = dataSource.indexPath(for: .entry(id)) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [])
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.collectionView.deselectItem(at: indexPath, animated: true)
        }
    }

    private func confirmRestoreDefaults() {
        let alert = UIAlertController(
            title: String(localized: "Restore Defaults?", comment: "Confirmation title for resetting a settings category"),
            message: String(localized: "Every setting in \(category.title(on: .phone)) goes back to how Crucible starts out.", comment: "Confirmation message for resetting a settings category"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Restore", comment: "Button that confirms resetting a settings category"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            for setting in SettingsCatalog.preferences(in: category, on: .phone) where setting.isChanged {
                setting.restoreDefault()
            }
            Haptics.success()
            refresh()
        })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .restoreDefaults: return true
        case .entry(let id): return entry(withID: id).map(SettingsRows.isSelectable) ?? false
        case nil: return false
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .restoreDefaults:
            confirmRestoreDefaults()
        case .entry(let id):
            guard let entry = entry(withID: id) else { return }
            let source = collectionView.cellForItem(at: indexPath)
            switch entry.item {
            case .destination(let destination): navigator.open(destination, source: source)
            case .action(let action): navigator.perform(action, source: source)
            case .preference, .privacyStatement: break
            }
        case nil:
            break
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
