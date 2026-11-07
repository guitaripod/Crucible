import CrucibleCore
import CrucibleDesign
import UIKit

/// Settings › Crucible Server on Apple TV: what it is and how to set it up, or which computer this Apple TV is paired
/// with and how it is doing. Pairing takes the code `crucible-server pair` prints, tried beside the Plex server; the
/// server's proof of the code stands in for the fingerprint a QR code would carry.
final class TVCompanionViewController: UIViewController {
    private let heading = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private lazy var codeButton = TVButton.make(.glass, title: CompanionCopy.enterCode) { [weak self] in self?.askForCode() }
    private lazy var unpairButton = TVButton.make(.glass, title: CompanionCopy.unpair) { [weak self] in self?.confirmUnpair() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        heading.font = Theme.Font.title2
        heading.textColor = Theme.Color.label
        heading.accessibilityTraits = .header
        for label in [statusLabel, detailLabel] {
            label.numberOfLines = 0
            label.textColor = Theme.Color.labelSecondary
            label.font = Theme.Font.body
        }
        codeButton.accessibilityIdentifier = "settings.crucibleServer.enterCode"
        unpairButton.accessibilityIdentifier = "settings.crucibleServer.unpair"
        let stack = UIStackView(arrangedSubviews: [heading, statusLabel, detailLabel, codeButton, unpairButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Space.l
        stack.setCustomSpacing(Theme.Space.s, after: heading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Space.xl),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Space.xl),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 1200),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [CompanionStore.current() == nil ? codeButton : unpairButton]
    }

    private func refresh() {
        let server = CompanionStore.current()
        heading.text = server.map { CompanionCopy.paired($0.name) } ?? CompanionCopy.title
        statusLabel.text = server == nil ? CompanionCopy.pitch : CompanionCopy.checking
        detailLabel.text = server == nil ? "\(CompanionCopy.stepsTV)\n\(CompanionCopy.installURL.absoluteString)" : nil
        detailLabel.isHidden = server != nil
        codeButton.isHidden = server != nil
        unpairButton.isHidden = server == nil
        setNeedsFocusUpdate()
        guard let server else { return }
        Task { [weak self] in
            let token = ServerBootstrap.connection()?.authToken ?? ""
            let text: String
            do throws(CompanionError) {
                let brain = try await CompanionClient(server: server, plexToken: token).brain()
                switch (brain.model, brain.reachable) {
                case (let model?, false): text = CompanionCopy.modelSilent(model)
                case (let model, _): text = CompanionCopy.ready(model: model)
                }
            } catch {
                text = error.message
            }
            self?.statusLabel.text = text
        }
    }

    private func askForCode() {
        let alert = UIAlertController(title: CompanionCopy.enterCode, message: CompanionCopy.stepsTV, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = CompanionCopy.codePlaceholder
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: CompanionCopy.pair, style: .default) { [weak self, weak alert] _ in
            guard let self, let code = alert?.textFields?.first?.text else { return }
            pair(code: code)
        })
        present(alert, animated: TVMotion.animationsEnabled)
    }

    private func pair(code: String) {
        guard let invite = PreviouslyOnRequest.invite(code: code) else {
            statusLabel.text = CompanionError.codeRefused.message
            return
        }
        statusLabel.text = CompanionCopy.pairing
        Task { [weak self] in
            do throws(CompanionError) {
                _ = try await PreviouslyOnRequest.pair(invite, deviceName: UIDevice.current.name, platform: "tvos")
                self?.refresh()
            } catch {
                self?.statusLabel.text = error.message
            }
        }
    }

    private func confirmUnpair() {
        presentConfirmation(title: CompanionCopy.unpair, message: CompanionCopy.unpairMessage, confirmTitle: CompanionCopy.unpair) { [weak self] in
            CompanionStore.forget()
            self?.refresh()
        }
    }
}
