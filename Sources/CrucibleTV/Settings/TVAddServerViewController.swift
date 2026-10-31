import CrucibleCore
import CrucibleDesign
import MidgarCore
import UIKit

/// Add Server by Address: an address typed on the system keyboard is expanded into candidate URLs,
/// the first one that answers `/identity` is pinned as the server, and the app reconnects to it.
/// Connecting to a different server resets what was bound to the old one when the launch starts.
final class TVAddServerViewController: UIViewController {
    private let env: TVAppEnvironment
    private let form = TVAddressForm(identifierPrefix: "addServer", layout: .leading, initialText: nil)
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

        let heading = TVSettingsHeading(
            title: "Add Server by Address",
            body: "Enter an IP address, hostname or full URL. The default port is 32400."
        )
        heading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heading)

        form.onSubmit = { [weak self] text in self?.connect(text) }
        form.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(form)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            heading.widthAnchor.constraint(equalToConstant: TVSettingsScaffold.Layout.contextWidth),
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: TVSettingsScaffold.Layout.contentTop),
            form.leadingAnchor.constraint(equalTo: heading.trailingAnchor, constant: TVSettingsScaffold.Layout.columnGap),
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: TVSettingsScaffold.Layout.contentTop),
            form.widthAnchor.constraint(equalToConstant: TVMetrics.Column.form),
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            connectTask?.cancel()
        }
    }

    private func connect(_ input: String) {
        guard connectTask == nil else { return }
        guard let candidates = AddServerLookup.candidates(from: input) else {
            form.showError(AddServerLookup.invalidAddressMessage)
            return
        }
        form.setBusy(true)
        view.layoutIfNeeded()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        let token = env.connection.authToken
        connectTask = Task { [weak self] in
            let found = await AddServerLookup.find(among: candidates, token: token)
            guard !Task.isCancelled, let self else { return }
            connectTask = nil
            form.setBusy(false)
            guard let found else {
                MidgarLog.error("Add server: nothing answered at \(input)", category: .networking)
                form.showError(AddServerLookup.notFoundMessage(for: input))
                return
            }
            AddServerLookup.save(found)
            env.session.reconnect()
        }
    }
}
