import CrucibleCore
import CrucibleDesign
import UIKit

/// Connects to a server by its address: an IP address, a hostname or a full URL, typed on the
/// system keyboard. Crucible tries https first, then http, and keeps the server's identity when
/// it is the one the person was already choosing.
final class TVAddressViewController: TVOnboardingViewController {
    private let token: String
    private let known: ServerChoice?
    private let introMessage: String?
    private let form = TVAddressForm(identifierPrefix: "onboarding", layout: .centered, initialText: RememberedServerAddress.text)
    private var connectTask: Task<Void, Never>?

    init(flow: TVOnboardingFlow, token: String, known: ServerChoice?, message: String?) {
        self.token = token
        self.known = known
        self.introMessage = message
        super.init(flow: flow)
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        connectTask == nil ? [form.textField] : []
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installContent()
        form.onSubmit = { [weak self] text in self?.connect(text) }
        if let introMessage { form.showError(introMessage) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isMovingFromParent || navigationController?.isBeingDismissed == true else { return }
        connectTask?.cancel()
        connectTask = nil
    }

    private func connect(_ text: String) {
        guard connectTask == nil else { return }
        guard let address = ServerAddress.parse(text) else {
            form.showError(AddServerLookup.invalidAddressMessage)
            return
        }
        RememberedServerAddress.remember(address)
        form.setBusy(true, status: "Connecting to \(address.host)…")
        refocus()
        connectTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await ServerDiscovery(token: token).connect(toAddress: address, known: known) { [weak self] progress in
                self?.form.updateStatus(progress.message)
            }
            guard !Task.isCancelled else { return }
            connectTask = nil
            switch outcome {
            case .connected(let connection):
                flow.didConnect(connection)
            case .failed(let message), .needsAddress(let message?):
                form.setBusy(false)
                form.showError(message)
                refocus()
            case .needsAddress(nil), .cancelled:
                form.setBusy(false)
                refocus()
            }
        }
    }

    private static func detail(for known: ServerChoice?) -> String {
        let base = "Enter your server’s IP address or hostname, such as 192.168.1.20 or a Tailscale name. The default port is 32400."
        guard let known, TailnetPresence.isConnected, let note = ConnectRecovery.tailnetLookupNote(serverName: known.name) else { return base }
        return base + " " + note
    }

    private func refocus() {
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    private func installContent() {
        let title = TVScreenTitleView(clearsTabBar: false, column: TVMetrics.Column.form)
        title.configure(TVScreenTitleContent(
            title: "Add by Address",
            detail: Self.detail(for: known)
        ))

        let stack = UIStackView(arrangedSubviews: [title, form])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Space.l
        stack.setCustomSpacing(Theme.Space.xl, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: TVMetrics.Column.form),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
}
