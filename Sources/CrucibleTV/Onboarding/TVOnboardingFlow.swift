import CrucibleCore
import UIKit

/// The route through onboarding: Welcome, the link code, server choice and add by address. Every
/// screen holds the flow and reports what the person did; the flow decides where to go next and
/// hands the saved connection to whoever presented onboarding.
@MainActor
final class TVOnboardingFlow {
    let mode: TVOnboardingMode
    private let onConnected: @MainActor (PlexConnection) -> Void

    init(mode: TVOnboardingMode, onConnected: @escaping @MainActor (PlexConnection) -> Void) {
        self.mode = mode
        self.onConnected = onConnected
    }

    /// Sign-in starts at Welcome. Switching servers starts at the server list for the saved
    /// account, or at Welcome when there is no account to list servers for.
    func makeRoot() -> UIViewController {
        switch mode {
        case .signIn:
            return TVWelcomeViewController(flow: self)
        case .switchServer:
            guard let token = ServerBootstrap.connection()?.authToken else {
                return TVWelcomeViewController(flow: self)
            }
            return TVChooseServerViewController(flow: self, token: token)
        }
    }

    func beginSignIn(from screen: UIViewController) {
        screen.navigationController?.pushViewController(TVLinkViewController(flow: self), animated: true)
    }

    /// The account token is saved: the link screen is replaced by the server list, so Back from
    /// the list returns to where sign-in started and never to a dead code.
    func didSignIn(token: String, from screen: UIViewController) {
        guard let navigation = screen.navigationController else { return }
        let servers = TVChooseServerViewController(flow: self, token: token)
        let remaining = navigation.viewControllers.filter { $0 !== screen }
        let keepsRoot = mode == .signIn && remaining.first is TVWelcomeViewController
        navigation.setViewControllers((keepsRoot ? remaining : []) + [servers], animated: true)
    }

    func addByAddress(token: String, known: ServerChoice?, message: String?, from screen: UIViewController) {
        let address = TVAddressViewController(flow: self, token: token, known: known, message: message)
        screen.navigationController?.pushViewController(address, animated: true)
    }

    func signInAgain(from screen: UIViewController) {
        beginSignIn(from: screen)
    }

    func didConnect(_ connection: PlexConnection) {
        onConnected(connection)
    }
}
