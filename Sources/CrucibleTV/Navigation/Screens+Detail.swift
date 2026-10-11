import UIKit

extension TVScreens {
    static func movieDetail(_ env: TVAppEnvironment, ratingKey: String, mediaType: String) -> UIViewController {
        TVPlaceholderViewController(name: "Detail \(ratingKey)")
    }

    static func showDetail(_ env: TVAppEnvironment, ratingKey: String, initialSeasonKey: String?) -> UIViewController {
        TVPlaceholderViewController(name: "Show \(ratingKey)")
    }
}
