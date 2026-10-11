import CrucibleCore
import CrucibleDesign
import UIKit

/// Connects to a server by its address: an IP address, a hostname or a full URL, typed on the
/// system keyboard. Crucible tries https first, then http, and keeps the server's identity when
/// it is the one the person was already choosing.
final class TVAddressViewController: TVOnboardingViewController {
    private static let columnWidth: CGFloat = 1000

    private let token: String
    private let known: ServerChoice?
    private let introMessage: String?
    private let textField = UITextField()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusRow = UIStackView()
    private let errorLabel = UILabel()
    private lazy var connectButton = TVButton.make(.primary, title: "Connect") { [weak self] in
        self?.connect()
    }
    private var connectTask: Task<Void, Never>?

    init(flow: TVOnboardingFlow, token: String, known: ServerChoice?, message: String?) {
        self.token = token
        self.known = known
        self.introMessage = message
        super.init(flow: flow)
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        connectTask == nil ? [textField] : []
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installContent()
        if let introMessage { showError(introMessage) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || isBeingDismissed else { return }
        connectTask?.cancel()
        connectTask = nil
    }

    private func connect() {
        guard connectTask == nil else { return }
        guard let address = ServerAddress.parse(textField.text ?? "") else {
            showError(AddServerLookup.invalidAddressMessage)
            return
        }
        RememberedServerAddress.remember(address)
        errorLabel.isHidden = true
        setBusy(true, status: "Connecting to \(address.host)…")
        connectTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await ServerDiscovery(token: token).connect(toAddress: address, known: known) { [weak self] progress in
                self?.statusLabel.text = progress.message
            }
            guard !Task.isCancelled else { return }
            connectTask = nil
            switch outcome {
            case .connected(let connection):
                flow.didConnect(connection)
            case .failed(let message), .needsAddress(let message?):
                setBusy(false, status: nil)
                showError(message)
            case .needsAddress(nil), .cancelled:
                setBusy(false, status: nil)
            }
        }
    }

    private func setBusy(_ busy: Bool, status: String?) {
        textField.isEnabled = !busy
        connectButton.isEnabled = !busy
        statusRow.isHidden = !busy
        statusLabel.text = status
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func installContent() {
        let title = UILabel()
        title.text = "Add by Address"
        title.font = Theme.Font.title2
        title.textColor = Theme.Color.label
        title.textAlignment = .center
        title.accessibilityTraits = .header

        let hint = UILabel()
        hint.text = "Enter your server's IP address or hostname, such as 192.168.1.20 or a Tailscale name. The default port is 32400."
        hint.font = Theme.Font.callout
        hint.textColor = Theme.Color.labelSecondary
        hint.textAlignment = .center
        hint.numberOfLines = 3

        configureField()

        statusLabel.font = Theme.Font.callout
        statusLabel.textColor = Theme.Color.labelSecondary
        statusLabel.numberOfLines = 2
        spinner.color = Theme.Color.labelSecondary
        spinner.hidesWhenStopped = true
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = Theme.Space.m
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(statusLabel)
        statusRow.isHidden = true

        errorLabel.font = Theme.Font.callout
        errorLabel.textColor = Theme.Color.destructive
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 3
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "onboarding.error"

        connectButton.accessibilityIdentifier = "onboarding.connect"

        let stack = UIStackView(arrangedSubviews: [title, hint, textField, errorLabel, statusRow, connectButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Space.l
        stack.setCustomSpacing(Theme.Space.s, after: title)
        stack.setCustomSpacing(Theme.Space.xl, after: hint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            textField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    /// The system text field: Select opens the full-screen keyboard, and its go key connects.
    private func configureField() {
        textField.placeholder = "192.168.1.20 or https://host:32400"
        textField.text = RememberedServerAddress.text
        textField.font = Theme.Font.callout
        textField.textAlignment = .center
        textField.keyboardType = .URL
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = .go
        textField.accessibilityLabel = "Server address"
        textField.accessibilityIdentifier = "onboarding.address"
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.heightAnchor.constraint(greaterThanOrEqualToConstant: TVMetrics.Control.primaryHeight).isActive = true
        textField.addAction(UIAction { [weak self] _ in
            self?.errorLabel.isHidden = true
        }, for: .editingChanged)
        textField.addAction(UIAction { [weak self] _ in
            self?.connect()
        }, for: .editingDidEndOnExit)
    }
}
