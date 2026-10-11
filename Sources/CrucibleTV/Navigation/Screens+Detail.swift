import UIKit

extension TVScreens {
    static func movieDetail(_ env: TVAppEnvironment, ratingKey: String, mediaType: String) -> UIViewController {
        TVMediaDetailViewController(env: env, ratingKey: ratingKey)
    }

    static func showDetail(_ env: TVAppEnvironment, ratingKey: String, initialSeasonKey: String?) -> UIViewController {
        TVShowDetailViewController(env: env, ratingKey: ratingKey, initialSeasonKey: initialSeasonKey)
    }
}
