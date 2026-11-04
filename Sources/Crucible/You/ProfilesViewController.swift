import CrucibleCore
import CrucibleDesign
import MidgarCore
@preconcurrency import UIKit

/// The members of the account's Plex Home, with the one watching now ticked. Picking another asks for its PIN when it has one,
/// then the app starts over as that profile; the account's own sign-in stays as it was.
final class ProfilesViewController: UICollectionViewController {
    private let machineIdentifier: String
    private var profiles: [HomeProfile] = []
    private var accountID: String?
    private var switchingID: String?
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var loadTask: Task<Void, Never>?
    private var switchTask: Task<Void, Never>?

    /// Called once another profile is in use, to start the app over as it.
    var onSwitched: (() -> Void)?

    init(machineIdentifier: String) {
        self.machineIdentifier = machineIdentifier
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        loadTask?.cancel()
        switchTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = HomeProfiles.title
        navigationItem.largeTitleDisplayMode = .never
        collectionView.backgroundColor = Theme.Color.canvas
        collectionView.accessibilityIdentifier = "profiles"
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

    private var currentID: String? { HomeProfiles.active?.id ?? accountID }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            guard let self, let profile = profiles.first(where: { $0.id == id }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = profile.title
            content.secondaryText = profile.detail
            content.image = UIImage(systemName: profile.isRestricted ? "figure.and.child.holdinghands" : "person.crop.circle.fill")
            content.imageProperties.tintColor = Theme.Color.accent
            content.textProperties.font = Theme.Font.body
            content.secondaryTextProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
            cell.accessories = accessories(for: profile)
            cell.accessibilityIdentifier = "profiles.\(profile.title)"
            cell.accessibilityTraits = id == currentID ? [.button, .selected] : .button
            cell.accessibilityHint = profile.isProtected && id != currentID ? String(localized: "Asks for the profile’s PIN", comment: "VoiceOver hint of a PIN-protected Plex Home profile") : nil
            cell.applyThemedBackground()
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { cell, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = String(localized: "Each profile has its own Continue Watching, watched titles, ratings and watchlist. Downloads stay on this device.", comment: "Footer under the Plex Home profile list")
            content.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    /// A spinner on the profile being switched to, a tick on the one in use, a lock on one with a PIN.
    private func accessories(for profile: HomeProfile) -> [UICellAccessory] {
        if profile.id == switchingID {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            return [.customView(configuration: .init(customView: spinner, placement: .trailing()))]
        }
        if profile.id == currentID { return [.checkmark()] }
        if profile.isProtected {
            let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
            lock.tintColor = Theme.Color.labelSecondary
            lock.isAccessibilityElement = false
            return [.customView(configuration: .init(customView: lock, placement: .trailing()))]
        }
        return []
    }

    private func load() {
        guard let token = ServerBootstrap.accountToken else { return }
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        loadTask = Task { [weak self] in
            do {
                let loaded = try await HomeProfiles.load(accountToken: token)
                guard let self, !Task.isCancelled else { return }
                profiles = loaded.profiles
                accountID = loaded.accountID
                contentUnavailableConfiguration = profiles.isEmpty ? Self.noHome() : nil
                applySnapshot()
            } catch {
                guard let self, !Task.isCancelled else { return }
                MidgarLog.error("Home profiles failed to load: \(error.localizedDescription)", category: .networking)
                var failed = UIContentUnavailableConfiguration.empty()
                failed.image = UIImage(systemName: "person.2.slash")
                failed.text = String(localized: "Couldn\u{2019}t Load Profiles")
                failed.secondaryText = ConnectionError.message(for: error)
                var retry = UIButton.Configuration.filled()
                retry.title = String(localized: "Try Again")
                failed.button = retry
                failed.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load() }
                contentUnavailableConfiguration = failed
            }
        }
    }

    private static func noHome() -> UIContentUnavailableConfiguration {
        var empty = UIContentUnavailableConfiguration.empty()
        empty.image = UIImage(systemName: "person.2")
        empty.text = String(localized: "No Other Profiles", comment: "Title when the account has no Plex Home profiles")
        empty.secondaryText = String(localized: "Profiles for the people you live with are set up in Plex, under Plex Home.", comment: "Explanation when the account has no Plex Home profiles")
        return empty
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(profiles.map(\.id))
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard switchingID == nil, let id = dataSource.itemIdentifier(for: indexPath), id != currentID,
              let profile = profiles.first(where: { $0.id == id }) else { return }
        if profile.isProtected {
            askForPIN(for: profile)
        } else {
            switchTo(profile, pin: nil)
        }
    }

    /// The four-digit PIN of a protected profile, typed into a secure field with the number pad.
    private func askForPIN(for profile: HomeProfile, after error: String? = nil) {
        let alert = UIAlertController(
            title: String(localized: "Enter PIN for \(profile.title)", comment: "Title of the PIN prompt for a Plex Home profile"),
            message: error,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.keyboardType = .numberPad
            field.textContentType = .oneTimeCode
            field.accessibilityIdentifier = "profiles.pin"
            field.placeholder = String(localized: "PIN")
        }
        let confirm = UIAlertAction(title: String(localized: "Switch", comment: "Button that switches to a Plex Home profile"), style: .default) { [weak self, weak alert] _ in
            let pin = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            self?.switchTo(profile, pin: pin)
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(confirm)
        alert.preferredAction = confirm
        present(alert, animated: true)
    }

    private func switchTo(_ profile: HomeProfile, pin: String?) {
        guard let token = ServerBootstrap.accountToken else { return }
        switchingID = profile.id
        applySnapshot()
        let isAccount = profile.id == accountID
        let machine = machineIdentifier
        switchTask = Task { [weak self] in
            do {
                try await HomeProfiles.switchTo(profile, pin: pin, isAccount: isAccount, accountToken: token, machineIdentifier: machine)
                guard let self else { return }
                Haptics.success()
                AccountSessionReset.switchedProfile(.phone)
                onSwitched?()
            } catch {
                guard let self else { return }
                switchingID = nil
                applySnapshot()
                if case HomeProfiles.SwitchError.wrongPIN = error {
                    Haptics.error()
                    askForPIN(for: profile, after: error.localizedDescription)
                } else {
                    MidgarLog.error("Switching Home profile failed: \(error.localizedDescription)", category: .networking)
                    let alert = UIAlertController(title: String(localized: "Couldn\u{2019}t Switch Profile"), message: ConnectionError.message(for: error), preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                    present(alert, animated: true)
                }
            }
        }
    }
}
