import UIKit

/// A small sheet that takes a server address, finds a Plex server answering on it (https first, then
/// http) and saves it as the pinned route.
final class AddServerSheetViewController: UIViewController {
    var onSaved: (() -> Void)?

    private let token: String
    private let textField = UITextField()
    private let fieldBox = UIView()
    private let errorLabel = UILabel()
    private let connectButton = UIButton(configuration: ThemeButton.primaryConfiguration(title: "Connect"))
    private var connectTask: Task<Void, Never>?

    init(token: String) {
        self.token = token
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { connectTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas

        let titleLabel = UILabel()
        titleLabel.text = "Add Server by Address"
        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header

        let hintLabel = UILabel()
        hintLabel.text = "Enter an IP address, hostname or full URL. The default port is 32400."
        hintLabel.font = Theme.Font.footnote
        hintLabel.textColor = Theme.Color.labelSecondary
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.numberOfLines = 0

        configureField()

        errorLabel.font = Theme.Font.footnote
        errorLabel.textColor = Theme.Color.destructive
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        connectButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.primaryButtonHeight).isActive = true
        connectButton.addAction(UIAction { [weak self] _ in self?.connect() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [titleLabel, hintLabel, fieldBox, errorLabel, connectButton])
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        stack.setCustomSpacing(Theme.Space.xxs, after: titleLabel)
        stack.setCustomSpacing(Theme.Space.m, after: hintLabel)
        stack.setCustomSpacing(Theme.Space.m, after: errorLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Theme.Space.l),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textField.becomeFirstResponder()
    }

    private func configureField() {
        textField.placeholder = "192.168.1.20 or https://host:32400"
        textField.font = Theme.Font.body
        textField.adjustsFontForContentSizeCategory = true
        textField.textColor = Theme.Color.label
        textField.keyboardType = .URL
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = .go
        textField.clearButtonMode = .whileEditing
        textField.accessibilityLabel = "Server address"
        textField.addAction(UIAction { [weak self] _ in self?.clearError() }, for: .editingChanged)
        textField.addAction(UIAction { [weak self] _ in self?.connect() }, for: .editingDidEndOnExit)

        fieldBox.backgroundColor = Theme.Color.surface
        fieldBox.layer.cornerRadius = Theme.Radius.s
        fieldBox.layer.cornerCurve = .continuous
        fieldBox.layer.borderWidth = 1
        fieldBox.layer.borderColor = Theme.Color.separator.cgColor
        textField.translatesAutoresizingMaskIntoConstraints = false
        fieldBox.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: fieldBox.topAnchor, constant: 12),
            textField.bottomAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: -12),
            textField.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 14),
            textField.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -14),
            fieldBox.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget + 4),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: AddServerSheetViewController, _: UITraitCollection) in
            controller.fieldBox.layer.borderColor = Theme.Color.separator.cgColor
        }
    }

    private func clearError() {
        errorLabel.isHidden = true
        fieldBox.layer.borderColor = Theme.Color.separator.cgColor
    }

    private func showError(_ message: String) {
        errorLabel.text = message
        errorLabel.isHidden = false
        fieldBox.layer.borderColor = Theme.Color.destructive.cgColor
        Haptics.error()
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func setConnecting(_ connecting: Bool) {
        var config = ThemeButton.primaryConfiguration(title: connecting ? "Connecting…" : "Connect")
        config.showsActivityIndicator = connecting
        connectButton.configuration = config
        connectButton.isEnabled = !connecting
        textField.isEnabled = !connecting
        isModalInPresentation = connecting
    }

    private func connect() {
        guard connectTask == nil else { return }
        let input = textField.text ?? ""
        guard let candidates = ConnectionRoute.candidates(from: input) else {
            showError("Enter an address like 192.168.1.20 or https://plex.example.com:32400.")
            return
        }
        clearError()
        setConnecting(true)
        let token = token
        connectTask = Task { [weak self] in
            let found = await Self.findServer(among: candidates, token: token)
            guard !Task.isCancelled, let self else { return }
            connectTask = nil
            setConnecting(false)
            guard let found else {
                AppLogger.error("Add server: nothing answered at \(input)", .networking)
                showError("Couldn't find a Plex server at \(input.trimmingCharacters(in: .whitespacesAndNewlines)). Check the address and that the server is online.")
                return
            }
            save(found)
        }
    }

    private struct FoundServer: Sendable {
        let url: URL
        let name: String
        let machineIdentifier: String
        let candidates: [URL]
    }

    /// Tries each URL in order and returns the first that answers `/identity` with a machine id,
    /// enriched with the server's name and other advertised routes from plex.tv when it is known there.
    private static func findServer(among urls: [URL], token: String) async -> FoundServer? {
        for url in urls {
            guard !Task.isCancelled else { return nil }
            guard let probe = await ConnectionProber.probe(baseURL: url, token: token, timeout: 5),
                  let machineIdentifier = probe.machineIdentifier
            else { continue }
            let resources: [PlexResource] = (try? await APIClient.plexTVRequest(.resources, token: token)) ?? []
            let match = resources.first { $0.clientIdentifier == machineIdentifier && $0.provides.contains("server") }
            var candidates = match?.connections.compactMap { URL(string: $0.uri) } ?? []
            if let existing = ServerBootstrap.connection(), existing.machineIdentifier == machineIdentifier {
                candidates.append(contentsOf: existing.candidateURIs)
            }
            let others = candidates.filter { $0 != url }
            var seen = Set<URL>()
            let unique = others.filter { seen.insert($0).inserted }
            return FoundServer(
                url: url,
                name: match?.name ?? ServerBootstrap.connection().flatMap { $0.machineIdentifier == machineIdentifier ? $0.serverName : nil } ?? url.host ?? "Plex Server",
                machineIdentifier: machineIdentifier,
                candidates: unique
            )
        }
        return nil
    }

    private func save(_ server: FoundServer) {
        ServerBootstrap.saveServer(uri: server.url, name: server.name, machineIdentifier: server.machineIdentifier, candidates: server.candidates)
        AppLogger.notice("Added server \(server.name) at \(server.url.absoluteString)", .networking)
        Haptics.success()
        dismiss(animated: true) { [onSaved] in onSaved?() }
    }
}
