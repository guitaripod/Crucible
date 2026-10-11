import UIKit

extension TVScreens {
    static func play(_ env: TVAppEnvironment, request: TVPlaybackRequest, from presenter: UIViewController) {
        let alert = UIAlertController(
            title: request.display?.title ?? "Player",
            message: "Playback for item \(request.ratingKey) isn't available yet.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        presenter.present(alert, animated: true)
    }
}
