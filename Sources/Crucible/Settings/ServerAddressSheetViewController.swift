import UIKit

/// A small input sheet for connecting by hostname or IP (for example a Tailscale 100.x address).
/// Validates as the user types and keeps the sheet open, with an inline message, when the submit
/// handler reports a failure.
final class ServerAddressSheetViewController: UIViewController {
    var onDidDismiss: (() -> Void)?

    private let onSubmit: (ServerAddress) async -> String?

    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let field = UITextField()
    private let errorLabel = UILabel()
    private let connectButton = ThemeButton.primary(title: "Connect")
    private var submitTask: Task<Void, Never>?
    private var isSubmitting = false

    init(prefill: String?, onSubmit: @escaping (ServerAddress) async -> String?) {
        self.onSubmit = onSubmit
        super.init(nibName: nil, bundle: nil)
        field.text = prefill
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        configureViews()
        layoutViews()
        refreshState()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        submitTask?.cancel()
    }

    private func configureViews() {
        titleLabel.text = "Server Address"
        titleLabel.font = Theme.Font.title2
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.accessibilityTraits = .header

        hintLabel.text = "A hostname or IP such as 100.x.x.x for Tailscale. Crucible tries HTTPS first."
        hintLabel.font = Theme.Font.footnote
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.textColor = Theme.Color.labelSecondary
        hintLabel.numberOfLines = 0

        field.placeholder = "100.64.0.12 or nas.local"
        field.font = Theme.Font.body
        field.adjustsFontForContentSizeCategory = true
        field.textColor = Theme.Color.label
        field.tintColor = Theme.Color.accent
        field.backgroundColor = Theme.Color.surfaceRaised
        field.layer.cornerRadius = 14
        field.layer.cornerCurve = .continuous
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        field.leftViewMode = .always
        field.accessibilityLabel = "Server address"
        field.addAction(UIAction { [weak self] _ in self?.fieldChanged() }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.expandForKeyboard() }, for: .editingDidBegin)
        field.addAction(UIAction { [weak self] _ in self?.submit() }, for: .editingDidEndOnExit)

        errorLabel.font = Theme.Font.footnote
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = Theme.Color.destructive
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        connectButton.addAction(UIAction { [weak self] _ in self?.submit() }, for: .touchUpInside)
    }

    private func layoutViews() {
        let stack = UIStackView(arrangedSubviews: [titleLabel, hintLabel, field, errorLabel])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(16, after: hintLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(connectButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            connectButton.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 16),
            connectButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            connectButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            connectButton.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
            connectButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    private var typedAddress: ServerAddress? {
        ServerAddress.parse(field.text ?? "")
    }

    private func fieldChanged() {
        errorLabel.isHidden = true
        refreshState()
        let text = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty, typedAddress == nil {
            showError("Enter a hostname or IP address, optionally with a port.")
        }
    }

    private func refreshState() {
        var config = connectButton.configuration ?? ThemeButton.primaryConfiguration(title: "Connect")
        config.title = isSubmitting ? "Connecting…" : "Connect"
        config.showsActivityIndicator = isSubmitting
        connectButton.configuration = config
        connectButton.isEnabled = typedAddress != nil && !isSubmitting
        field.isEnabled = !isSubmitting
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func expandForKeyboard() {
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.selectedDetentIdentifier = .large
        }
    }

    private func submit() {
        guard !isSubmitting, let address = typedAddress else { return }
        isSubmitting = true
        errorLabel.isHidden = true
        field.resignFirstResponder()
        refreshState()
        submitTask = Task { [weak self] in
            guard let self else { return }
            let failure = await onSubmit(address)
            guard !Task.isCancelled else { return }
            isSubmitting = false
            refreshState()
            if let failure {
                Haptics.error()
                showError(failure)
            } else {
                dismiss(animated: true) { [weak self] in self?.onDidDismiss?() }
            }
        }
    }
}
