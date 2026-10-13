import CrucibleCore
import UIKit

extension UIViewController {
    /// Asks before the demo ends. Connecting a Plex server and leaving both end it, so both ask: the tour, the demo's viewing history
    /// and its statistics are forgotten and cannot be brought back.
    @discardableResult
    @MainActor
    func presentLeaveDemoConfirmation(connecting: Bool, handler: @escaping @MainActor () -> Void) -> UIAlertController? {
        if connecting {
            return presentConfirmation(
                title: DemoCopy.connectTitle,
                message: DemoCopy.connectBody + " The demo, its viewing history and your tour progress are removed.",
                confirmTitle: "Connect",
                handler: handler
            )
        }
        return presentConfirmation(
            title: "Leave the Demo?",
            message: "The demo library, its viewing history and your tour progress are removed. You can try the demo again from the welcome screen.",
            confirmTitle: "Leave the Demo",
            handler: handler
        )
    }
}
