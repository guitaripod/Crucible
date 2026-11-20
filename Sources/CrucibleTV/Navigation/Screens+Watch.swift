import UIKit

extension TVScreens {
    static func whatToWatchAsk(_ env: TVAppEnvironment) -> UIViewController {
        TVWhatToWatchAskViewController(env: env)
    }

    static func whatToWatch(_ env: TVAppEnvironment, request: String, asTaste: Bool = false) -> UIViewController {
        TVWhatToWatchViewController(env: env, request: request, asTaste: asTaste)
    }
}
