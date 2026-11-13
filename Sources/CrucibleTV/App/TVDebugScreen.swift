#if DEBUG
import CrucibleCore
import Foundation
import UIKit

/// With `CRUCIBLE_OPEN=<name>` pushes a screen on Home as soon as the main UI is up, so UI tests
/// and screenshots can reach screens whose entry point lives in a tab that is not built yet, or
/// behind a row a screenshot in another language cannot name.
@MainActor
enum TVDebugScreen {
    static func openIfRequested(on tabBar: TVRootTabBarController) {
        guard let name = ProcessInfo.processInfo.environment["CRUCIBLE_OPEN"] else { return }
        let environment = tabBar.environment
        switch name {
        case "history":
            tabBar.showHome().pushViewController(TVScreens.history(environment), animated: false)
        case "statistics":
            tabBar.showHome().pushViewController(TVScreens.statistics(environment), animated: false)
        case "pro":
            openPro(on: tabBar)
        case "whattowatch":
            tabBar.showHome().pushViewController(TVScreens.whatToWatchAsk(environment), animated: false)
        default:
            break
        }
    }

    /// What the Crucible Pro row of You opens, once the store has answered: the plan for an owner, the paywall for everyone else.
    private static func openPro(on tabBar: TVRootTabBarController) {
        Task {
            await ProAccess.shared.refreshNow()
            if ProAccess.shared.isPro {
                tabBar.showHome().pushViewController(TVScreens.settings(tabBar.environment, page: .pro), animated: false)
            } else {
                ProAccess.shared.requestUnlock(nil)
            }
        }
    }
}
#endif
