import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// Runs the rating control for one title on a detail screen: shows the sheet or popover and hands the viewer's choice to the saver.
@MainActor
final class RatingCoordinator {
    private let saver: RatingSaver

    /// `refresh` redraws the rating control from `shown(served:)`; `reload` fetches the title again once the server has saved a rating.
    init(api: APIClient, ratingKey: String, refresh: @escaping () -> Void, reload: @escaping () -> Void) {
        saver = RatingSaver(api: api, ratingKey: ratingKey, changed: refresh, reload: reload, failed: { Haptics.error() })
    }

    func shown(served: UserRating?) -> UserRating? {
        saver.shown(served: served)
    }

    func loaded() {
        saver.loaded()
    }

    func present(from host: UIViewController, source: UIView, title: String, served: UserRating?) {
        RatingViewController.present(from: host, source: source, title: title, rating: shown(served: served)) { [saver] rating in
            saver.save(rating)
        }
    }
}
