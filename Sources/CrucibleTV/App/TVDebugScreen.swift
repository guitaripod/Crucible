#if DEBUG
import Foundation
import UIKit

/// With `CRUCIBLE_OPEN=<name>` pushes a screen on Home as soon as the main UI is up, so UI tests
/// and screenshots can reach screens whose entry point lives in a tab that is not built yet.
@MainActor
enum TVDebugScreen {
    static func openIfRequested(on tabBar: TVRootTabBarController) {
        guard let name = ProcessInfo.processInfo.environment["CRUCIBLE_OPEN"] else { return }
        let environment = tabBar.environment
        switch name {
        case "history":
            tabBar.showHome().pushViewController(TVScreens.history(environment), animated: false)
        default:
            break
        }
    }
}
#endif
