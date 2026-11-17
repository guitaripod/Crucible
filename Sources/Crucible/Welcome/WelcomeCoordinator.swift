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
    /// How long the welcome waits for something already open over Home (a pairing question from the link that opened the app, a
    /// notification's screen) to close before it gives up until the next launch.
    private static let patience: Duration = .seconds(120)

    private var isPresenting = false

    func mainAppDidAppear(_ tabBar: TabBarController) {
        guard WelcomeLedger.shared.isWelcomeOwed, !DemoMode.shared.isActive, !isPresenting else { return }
        isPresenting = true
        Task { [weak self, weak tabBar] in
            await Self.waitForStore()
            try? await Task.sleep(for: Self.settle)
            let isFree = await Self.waitUntilUnobstructed(tabBar)
            guard let self else { return }
            isPresenting = false
            guard let tabBar, isFree else {
                MidgarLog.notice("Welcome held back until the next launch: the window stayed busy", category: .lifecycle)
                return
            }
            present(over: tabBar)
        }
    }

    /// Waits while something covers Home, and reports whether Home came free in time and is still on screen.
    private static func waitUntilUnobstructed(_ tabBar: TabBarController?) async -> Bool {
        let deadline = ContinuousClock.now + patience
        while let tabBar, tabBar.view.window != nil, ContinuousClock.now < deadline {
            if tabBar.presentedViewController == nil { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func present(over tabBar: TabBarController) {
        guard tabBar.view.window != nil, tabBar.presentedViewController == nil, WelcomeLedger.shared.isWelcomeOwed else { return }
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
