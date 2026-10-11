import UIKit

extension UIViewController {
    /// A two-button confirmation: a cancel button that Menu also triggers and a destructive confirm
    /// button. Does nothing when another controller is already presented.
    ///
    /// TODO(ds): `presentAlert` only offers one cancel-style button; move this next to it once the design
    /// system has a confirmation variant.
    @MainActor
    func presentConfirmation(
        title: String,
        message: String?,
        confirmTitle: String,
        handler: @escaping @MainActor () -> Void
    ) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: confirmTitle, style: .destructive) { _ in handler() })
        present(alert, animated: TVMotion.animationsEnabled)
    }
}
