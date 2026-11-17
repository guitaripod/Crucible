import CrucibleCore
import MidgarCore
import UIKit

/// Brings the welcome up the first time a library opens on this device (`WelcomeLedger`): once Home is on screen and the store has
/// had a moment to say whether the viewer has Pro, over the window that connected. The demo has its own welcome, so a demo library
/// leaves it owed for the first real one. When the welcome closes, a new install is asked for permission to send notifications,
/// which it was not asked over the sign-in screen.
@MainActor
final class WelcomeCoordinator {
    static let shared = WelcomeCoordinator()

    /// How long the welcome waits on a store that has not answered, so it opens on the viewer's real standing.
    private static let storeGrace: Duration = .milliseconds(1_500)
    /// A beat for Home to settle under the launch screen's dissolve before the sheet rises over it.
    private static let settle: Duration = .milliseconds(450)

    private var isPresenting = false

    func mainAppDidAppear(_ tabBar: TabBarController) {
        guard WelcomeLedger.shared.isWelcomeOwed, !DemoMode.shared.isActive, !isPresenting else { return }
        isPresenting = true
        Task { [weak self, weak tabBar] in
            await Self.waitForStore()
            try? await Task.sleep(for: Self.settle)
            guard let self else { return }
            isPresenting = false
            guard let tabBar else { return }
            present(over: tabBar)
        }
    }

    private func present(over tabBar: TabBarController) {
        guard tabBar.view.window != nil, tabBar.presentedViewController == nil, WelcomeLedger.shared.isWelcomeOwed else {
            MidgarLog.notice("Welcome held back: the window is busy", category: .lifecycle)
            return
        }
        WelcomeLedger.shared.welcomeWasShown()
        let serverName = ServerBootstrap.connection()?.serverName ?? ""
        let welcome = WelcomeViewController(serverName: serverName, api: tabBar.api)
        welcome.onFinished = { AppDelegate.askForNotifications() }
        tabBar.present(welcome, animated: true)
        MidgarLog.notice("Welcome shown (\(ProAccess.shared.status))", category: .lifecycle)
    }

    private static func waitForStore() async {
        let access = ProAccess.shared
        guard access.isStoreBacked else { return }
        let deadline = ContinuousClock.now + storeGrace
        while access.status == .unknown, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
