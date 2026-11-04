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
        buttonTitle: String = String(localized: "OK"),
        style: UIAlertAction.Style = .cancel,
        handler: (@MainActor () -> Void)? = nil
    ) -> UIAlertController? {
        guard presentedViewController == nil else { return nil }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: buttonTitle, style: style) { _ in handler?() })
        present(alert, animated: TVMotion.animationsEnabled)
        return alert
    }

    /// Presents a two-button confirmation: a cancel button, which Menu also triggers, and a destructive
    /// confirm button. Does nothing when another controller is already presented.
    @discardableResult
    @MainActor
    func presentConfirmation(
        title: String,
        message: String? = nil,
        confirmTitle: String,
        handler: @escaping @MainActor () -> Void
    ) -> UIAlertController? {
        guard presentedViewController == nil else { return nil }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: confirmTitle, style: .destructive) { _ in handler() })
        present(alert, animated: TVMotion.animationsEnabled)
        return alert
    }

    /// Presents an alert with one text field that opens the on-screen keyboard, a cancel button, which Menu also
    /// triggers, and a button that hands the typed text to `handler`. Does nothing when another controller is already presented.
    @discardableResult
    @MainActor
    func presentTextEntry(
        title: String,
        message: String? = nil,
        text: String,
        placeholder: String? = nil,
        keyboard: UIKeyboardType = .default,
        confirmTitle: String,
        handler: @escaping @MainActor (String) -> Void
    ) -> UIAlertController? {
        guard presentedViewController == nil else { return nil }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = text
            field.placeholder = placeholder
            field.keyboardType = keyboard
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "textEntry.field"
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: confirmTitle, style: .default) { [weak alert] _ in
            handler(alert?.textFields?.first?.text ?? "")
        })
        present(alert, animated: TVMotion.animationsEnabled)
        return alert
    }
}
