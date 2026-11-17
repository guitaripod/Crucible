import CrucibleCore
import MidgarCore
import UIKit

extension TVAppCoordinator {
    private static let storeAnswerWait: Duration = .milliseconds(1500)
    private static let storeAnswerPoll: Duration = .milliseconds(100)

    /// Shows the welcome over the main UI the first time a library opens on this Apple TV, outside the demo, which has a welcome of its
    /// own. It waits a moment for the store to say whether the viewer has Pro, so what it says does not change as it appears, and is
    /// only marked shown once it is on screen. Returns whether the welcome takes this moment, so the other notes after a launch wait.
    func presentWelcomeIfOwed(over root: TVRootTabBarController) -> Bool {
        guard WelcomeLedger.shared.isWelcomeOwed, !DemoMode.shared.isActive else { return false }
        let serverName = root.environment.connection.serverName
        Task { @MainActor [weak self, weak root] in
            await Self.waitForStoreAnswer()
            guard let self, let root, window.rootViewController === root, root.presentedViewController == nil, !root.isBeingDismissed else {
                MidgarLog.notice("Welcome deferred: the main UI is covered", category: .lifecycle)
                return
            }
            WelcomeLedger.shared.welcomeWasShown()
            MidgarLog.notice("Welcome shown (Pro: \(ProAccess.shared.status.isPro), Trakt: \(TraktAccount.shared.isConnected))", category: .lifecycle)
            let navigation = TVNavigation.makeNavigationController(root: TVLibraryWelcomeViewController(serverName: serverName))
            navigation.modalPresentationStyle = .fullScreen
            root.present(navigation, animated: TVMotion.animationsEnabled)
        }
        return true
    }

    /// Waits, at most `storeAnswerWait`, while the store has not answered yet.
    private static func waitForStoreAnswer() async {
        var waited: Duration = .zero
        while ProAccess.shared.status == .unknown, waited < storeAnswerWait {
            try? await Task.sleep(for: storeAnswerPoll)
            waited += storeAnswerPoll
        }
    }
}
