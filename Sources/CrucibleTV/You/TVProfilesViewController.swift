import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

/// The members of the account's Plex Home on Apple TV, the one watching now ticked. Select asks for a profile's PIN when it has
/// one, then the app starts over as that profile; the account's own sign-in stays as it was.
final class TVProfilesViewController: TVSettingsScaffold {
    private static let prefix = "profiles."

    private let machineIdentifier: String
    private let onSwitched: @MainActor () -> Void
    private var profiles: [HomeProfile] = []
    private var accountID: String?
    private var switchingID: String?
    private let heading = TVSettingsHeading(
        title: HomeProfiles.title,
        body: String(localized: "Each profile has its own Continue Watching, watched titles, ratings and watchlist.", comment: "Explanation beside the Plex Home profile list on Apple TV")
    )
    private lazy var loadSlot = makeTaskSlot()
    private lazy var switchSlot = makeTaskSlot()

    init(machineIdentifier: String, onSwitched: @escaping @MainActor () -> Void) {
        self.machineIdentifier = machineIdentifier
        self.onSwitched = onSwitched
        super.init()
        title = HomeProfiles.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var preferredFocusRowID: String? {
        currentID.map { Self.prefix + $0 }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installHeading(heading)
        presentState(.loading(title: nil))
        load()
    }

    private var currentID: String? { HomeProfiles.active?.id ?? accountID }

    override func rowDidSelect(_ id: String) {
        guard switchingID == nil, let profile = profiles.first(where: { Self.prefix + $0.id == id }), profile.id != currentID else { return }
        if profile.isProtected {
            askForPIN(for: profile)
        } else {
            switchTo(profile, pin: nil)
        }
    }

    private func load() {
        guard let token = ServerBootstrap.accountToken else { return }
        loadSlot.run { [weak self] in
            do {
                let loaded = try await HomeProfiles.load(accountToken: token)
                guard let self, !Task.isCancelled else { return }
                profiles = loaded.profiles
                accountID = loaded.accountID
                if profiles.isEmpty {
                    presentState(.empty(
                        title: String(localized: "No Other Profiles", comment: "Title when the account has no Plex Home profiles"),
                        message: String(localized: "Profiles for the people you live with are set up in Plex, under Plex Home.", comment: "Explanation when the account has no Plex Home profiles"),
                        symbol: "person.2",
                        action: nil
                    ))
                } else {
                    render()
                    presentState(nil)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                MidgarLog.error("Home profiles failed to load: \(error.localizedDescription)", category: .networking)
                presentState(.error(title: String(localized: "Couldn\u{2019}t Load Profiles"), message: ConnectionError.message(for: error), retryTitle: String(localized: "Try Again")) { [weak self] in
                    self?.presentState(.loading(title: nil))
                    self?.load()
                })
            }
        }
    }

    private func render() {
        setRows(profiles.map { profile in
            TVRowItem(
                id: Self.prefix + profile.id,
                title: profile.title,
                subtitle: profile.detail,
                value: profile.id == switchingID ? String(localized: "Switching…", comment: "Shown beside a Plex Home profile while switching to it") : nil,
                symbol: profile.isProtected && profile.id != currentID ? "lock.fill" : (profile.isRestricted ? "figure.and.child.holdinghands" : "person.crop.circle"),
                accessory: profile.id == currentID ? .checkmark : .none
            )
        })
    }

    /// The four-digit PIN of a protected profile, typed on the system keyboard in a secure field.
    private func askForPIN(for profile: HomeProfile, after error: String? = nil) {
        let alert = UIAlertController(
            title: String(localized: "Enter PIN for \(profile.title)", comment: "Title of the PIN prompt for a Plex Home profile"),
            message: error,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.keyboardType = .numberPad
            field.accessibilityIdentifier = "profiles.pin"
            field.placeholder = String(localized: "PIN")
        }
        let confirm = UIAlertAction(title: String(localized: "Switch", comment: "Button that switches to a Plex Home profile"), style: .default) { [weak self, weak alert] _ in
            let pin = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            self?.switchTo(profile, pin: pin)
        }
        alert.addAction(confirm)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.preferredAction = confirm
        present(alert, animated: true)
    }

    private func switchTo(_ profile: HomeProfile, pin: String?) {
        guard let token = ServerBootstrap.accountToken else { return }
        switchingID = profile.id
        render()
        let isAccount = profile.id == accountID
        let machine = machineIdentifier
        switchSlot.run(.keepAlive) { [weak self] in
            do {
                try await HomeProfiles.switchTo(profile, pin: pin, isAccount: isAccount, accountToken: token, machineIdentifier: machine)
                AccountSessionReset.switchedProfile(.tv)
                self?.onSwitched()
            } catch {
                guard let self else { return }
                switchingID = nil
                render()
                if case HomeProfiles.SwitchError.wrongPIN = error {
                    askForPIN(for: profile, after: error.localizedDescription)
                } else {
                    MidgarLog.error("Switching Home profile failed: \(error.localizedDescription)", category: .networking)
                    presentAlert(title: String(localized: "Couldn\u{2019}t Switch Profile"), message: ConnectionError.message(for: error))
                }
            }
        }
    }
}
