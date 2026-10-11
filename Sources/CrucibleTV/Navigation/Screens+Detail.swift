import CrucibleCore
import UIKit

extension TVScreens {
    static func movieDetail(_ env: TVAppEnvironment, ratingKey: String, mediaType: String) -> UIViewController {
        TVMediaDetailViewController(env: env, ratingKey: ratingKey)
    }

    static func showDetail(_ env: TVAppEnvironment, ratingKey: String, initialSeasonKey: String?) -> UIViewController {
        TVShowDetailViewController(env: env, ratingKey: ratingKey, initialSeasonKey: initialSeasonKey)
    }

    /// The screen a Detail route leads to: the one place that turns a `DetailRoute` into a detail screen.
    static func screen(for route: DetailRoute, env: TVAppEnvironment) -> UIViewController {
        switch route {
        case .show(let ratingKey, let initialSeasonKey):
            showDetail(env, ratingKey: ratingKey, initialSeasonKey: initialSeasonKey)
        case .item(let ratingKey, let mediaType, _, _):
            movieDetail(env, ratingKey: ratingKey, mediaType: mediaType)
        }
    }
}
