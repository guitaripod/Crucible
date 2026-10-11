import CrucibleDesign
import UIKit

/// The address field, its error line and the Connect button, shared by onboarding and Settings.
/// The system text field takes the address on the full-screen keyboard; the keyboard's go key and
/// the Connect button both submit. The screen around it parses the text and reports back through
/// `setBusy` and `showError`.
final class TVAddressForm: UIStackView {
    enum Layout {
        case centered
        case leading
    }

    static let placeholder = "192.168.1.20 or https://host:32400"

    var onSubmit: (@MainActor (String) -> Void)?

    let textField = UITextField()
    private let errorLabel = UILabel()
    private let statusLabel = UILabel()
    private lazy var connectButton = TVButton.make(.primary, title: "Connect") { [weak self] in
        self?.submit()
    }

    var text: String { textField.text ?? "" }

    init(identifierPrefix: String, layout: Layout, initialText: String?) {
        super.init(frame: .zero)
        axis = .vertical
        self.alignment = layout == .centered ? .center : .leading
        spacing = Theme.Space.m
        configureField(identifierPrefix: identifierPrefix, layout: layout, initialText: initialText)
        configureLabels(identifierPrefix: identifierPrefix, layout: layout)
        connectButton.accessibilityIdentifier = "\(identifierPrefix).connect"
        [textField, errorLabel, statusLabel, connectButton].forEach(addArrangedSubview)
        NSLayoutConstraint.activate([
            textField.widthAnchor.constraint(equalTo: widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    /// Busy disables the field and shows the button's own activity indicator; `status` adds the
    /// current step under the field.
    func setBusy(_ busy: Bool, status: String? = nil) {
        var configuration = TVButton.configuration(.primary, title: busy ? "Connecting…" : "Connect")
        configuration.showsActivityIndicator = busy
        connectButton.configuration = configuration
        connectButton.isEnabled = !busy
        textField.isEnabled = !busy
        statusLabel.text = busy ? status : nil
        statusLabel.isHidden = !busy || (status ?? "").isEmpty
    }

    func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    func updateStatus(_ status: String) {
        statusLabel.text = status
    }

    private func submit() {
        onSubmit?(text)
    }

    private func configureField(identifierPrefix: String, layout: Layout, initialText: String?) {
        textField.text = initialText
        textField.font = Theme.Font.callout
        textField.attributedPlaceholder = NSAttributedString(string: Self.placeholder, attributes: [.font: Theme.Font.callout])
        textField.textAlignment = layout == .centered ? .center : .natural
        textField.keyboardType = .URL
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = .go
        textField.accessibilityLabel = "Server address"
        textField.accessibilityIdentifier = "\(identifierPrefix).address"
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.heightAnchor.constraint(greaterThanOrEqualToConstant: TVMetrics.Control.primaryHeight).isActive = true
        textField.addAction(UIAction { [weak self] _ in self?.errorLabel.isHidden = true }, for: .editingChanged)
        textField.addAction(UIAction { [weak self] _ in self?.submit() }, for: .editingDidEndOnExit)
    }

    private func configureLabels(identifierPrefix: String, layout: Layout) {
        let textAlignment: NSTextAlignment = layout == .centered ? .center : .natural
        errorLabel.font = Theme.Font.callout
        errorLabel.textColor = Theme.Color.destructive
        errorLabel.textAlignment = textAlignment
        errorLabel.numberOfLines = 3
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "\(identifierPrefix).error"
        statusLabel.font = Theme.Font.callout
        statusLabel.textColor = Theme.Color.labelSecondary
        statusLabel.textAlignment = textAlignment
        statusLabel.numberOfLines = 2
        statusLabel.isHidden = true
    }
}
