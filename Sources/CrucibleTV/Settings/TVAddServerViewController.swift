import CrucibleCore
import CrucibleDesign
import UIKit

/// Add Server by Address: an address typed on the system keyboard is expanded into candidate URLs,
/// the first one that answers `/identity` is pinned as the server, and the app reconnects to it.
final class TVAddServerViewController: UIViewController {
    private static let fieldWidth: CGFloat = 1000
    private static let fieldHeight: CGFloat = 86

    private let env: TVAppEnvironment
    private let textField = UITextField()
    private let errorLabel = UILabel()
    private lazy var connectButton = TVButton.make(.primary, title: "Connect") { [weak self] in self?.connect() }
    private var connectTask: Task<Void, Never>?

    init(env: TVAppEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
        title = "Add Server by Address"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        connectTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas

        let heading = TVSettingsHeadingView(
            title: "Add Server by Address",
            body: "Enter an IP address, hostname or full URL. The default port is 32400."
        )
        heading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heading)

        configureField()
        configureError()
        connectButton.accessibilityIdentifier = "addServer.connect"

        let form = UIStackView(arrangedSubviews: [textField, errorLabel, connectButton])
        form.axis = .vertical
        form.alignment = .leading
        form.spacing = Theme.Space.m
        form.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(form)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            heading.widthAnchor.constraint(equalToConstant: TVSettingsScaffold.Layout.contextWidth),
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: TVSettingsScaffold.Layout.contentTop),
            form.leadingAnchor.constraint(equalTo: heading.trailingAnchor, constant: TVSettingsScaffold.Layout.columnGap),
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: TVSettingsScaffold.Layout.contentTop),
            form.widthAnchor.constraint(equalToConstant: Self.fieldWidth),
            textField.widthAnchor.constraint(equalTo: form.widthAnchor),
            textField.heightAnchor.constraint(equalToConstant: Self.fieldHeight),
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            connectTask?.cancel()
        }
    }

    private func configureField() {
        textField.font = Theme.Font.callout
        textField.attributedPlaceholder = NSAttributedString(
            string: "192.168.1.20 or https://host:32400",
            attributes: [.font: Theme.Font.callout]
        )
        textField.keyboardType = .URL
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = .go
        textField.accessibilityLabel = "Server address"
        textField.accessibilityIdentifier = "addServer.address"
        textField.addAction(UIAction { [weak self] _ in self?.clearError() }, for: .editingChanged)
        textField.addAction(UIAction { [weak self] _ in self?.connect() }, for: .editingDidEndOnExit)
    }

    private func configureError() {
        errorLabel.font = Theme.Font.callout
        errorLabel.textColor = Theme.Color.destructive
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "addServer.error"
    }

    private func clearError() {
        errorLabel.isHidden = true
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func setConnecting(_ connecting: Bool) {
        var configuration = TVButton.configuration(.primary, title: connecting ? "Connecting…" : "Connect")
        configuration.showsActivityIndicator = connecting
        connectButton.configuration = configuration
        connectButton.isEnabled = !connecting
        textField.isEnabled = !connecting
    }

    private func connect() {
        guard connectTask == nil else { return }
        let input = textField.text ?? ""
        guard let candidates = AddServerLookup.candidates(from: input) else {
            showError(AddServerLookup.invalidAddressMessage)
            return
        }
        clearError()
        setConnecting(true)
        let token = env.connection.authToken
        connectTask = Task { [weak self] in
            let found = await AddServerLookup.find(among: candidates, token: token)
            guard !Task.isCancelled, let self else { return }
            connectTask = nil
            setConnecting(false)
            guard let found else {
                AppLogger.error("Add server: nothing answered at \(input)", .networking)
                showError(AddServerLookup.notFoundMessage(for: input))
                return
            }
            AddServerLookup.save(found)
            env.session.reconnect()
        }
    }
}
