import UIKit

extension UIViewController {
    /// Presents a one-button alert. The button is a cancel action by default: on tvOS Menu dismisses an
    /// alert only when it has one, so a default-style OK would leave Menu doing nothing. Does nothing when another
    /// controller is already presented, so an error never stacks on an open menu or sheet.
    @discardableResult
    @MainActor
    func presentAlert(
        title: String,
        message: String? = nil,
        buttonTitle: String = "OK",
        style: UIAlertAction.Style = .cancel,
        handler: (@MainActor () -> Void)? = nil
    ) -> UIAlertController? {
        guard presentedViewController == nil else { return nil }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: buttonTitle, style: style) { _ in handler?() })
        present(alert, animated: TVMotion.animationsEnabled)
        return alert
    }
}
