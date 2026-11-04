import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The server's settings for one show, for its owner: each setting with a menu of the choices the server offers, or a switch.
/// A change is sent at once; the server applies it to everyone who watches the show.
final class ShowSettingsViewController: UICollectionViewController {
    private let ratingKey: String
    private let api: APIClient
    private var settings: [ItemSetting] = []
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var loadTask: Task<Void, Never>?

    init(ratingKey: String, api: APIClient) {
        self.ratingKey = ratingKey
        self.api = api
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ManageCopy.showSettingsTitle
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "showSettings"
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, environment in
            var config = UICollectionLayoutListConfiguration.wellRows()
            config.footerMode = .supplementary
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            Theme.centerReadable(section, environment)
            return section
        }
        configureDataSource()
        load()
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let setting = settings.first(where: { $0.id == id }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = setting.label
            content.secondaryText = setting.isToggle ? setting.summary : setting.valueTitle
            content.textProperties.font = Theme.Font.callout
            content.secondaryTextProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "showSettings.\(setting.id)"
            cell.accessories = [accessory(for: setting)]
            cell.applyThemedBackground()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { cell, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = ManageCopy.showSettingsNote
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    /// A switch for an on/off setting, a menu of the server's choices for the rest.
    private func accessory(for setting: ItemSetting) -> UICellAccessory {
        if setting.isToggle {
            let toggle = UISwitch()
            toggle.isOn = setting.isOn
            toggle.accessibilityLabel = setting.label
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let toggle else { return }
                self?.change(setting, to: setting.toggleValue(toggle.isOn))
            }, for: .valueChanged)
            return .customView(configuration: .init(customView: toggle, placement: .trailing()))
        }
        let actions = setting.choices.map { choice in
            UIAction(title: choice.title, state: choice.value == setting.value ? .on : .off) { [weak self] _ in
                self?.change(setting, to: choice.value)
            }
        }
        return .popUpMenu(UIMenu(title: setting.label, children: actions))
    }

    private func load() {
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                settings = try await ItemSettings.load(ratingKey: ratingKey, api: api)
                apply()
                if settings.isEmpty {
                    var empty = UIContentUnavailableConfiguration.empty()
                    empty.text = ManageCopy.noShowSettings
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

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(settings.map(\.id))
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { dataSource.snapshot().indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Sends the change; on the server's refusal the row goes back to what the server still has.
    private func change(_ setting: ItemSetting, to value: String) {
        guard value != setting.value else { return }
        let api = api
        let key = ratingKey
        Task { @MainActor [weak self] in
            do {
                try await ItemSettings.set(setting, to: value, ratingKey: key, api: api)
                Haptics.success()
                self?.settings = (try? await ItemSettings.load(ratingKey: key, api: api)) ?? self?.settings ?? []
            } catch {
                Haptics.error()
                let alert = UIAlertController(title: ManageCopy.failed, message: ConnectionError.message(for: error), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                self?.present(alert, animated: true)
            }
            self?.apply()
        }
    }
}
