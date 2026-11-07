import CrucibleCore
import CrucibleDesign
import DeviceDiscoveryUI
import Network
import UIKit

/// Settings › Crucible Server on Apple TV: what it is and how to set it up, or which computer this Apple TV is paired
/// with and how it is doing. Pairing takes the code `crucible-server pair` prints, tried beside the Plex server; the
/// server's proof of the code stands in for the fingerprint a QR code would carry.
final class TVCompanionViewController: UIViewController {
    private let heading = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private lazy var phoneButton = TVButton.make(.glass, title: CompanionCopy.pairWithIPhone) { [weak self] in self?.pairWithIPhone() }
    private lazy var showCodeButton = TVButton.make(.glass, title: CompanionCopy.showCode) { [weak self] in self?.showCode() }
    private lazy var codeButton = TVButton.make(.glass, title: CompanionCopy.enterCode) { [weak self] in self?.askForCode() }
    private let handOffQueue = DispatchQueue(label: "com.guitaripod.crucible.companion-handoff")
    private static let handOff = NWBrowser.Descriptor.applicationService(name: CompanionHandOff.serviceName)
    private lazy var unpairButton = TVButton.make(.glass, title: CompanionCopy.unpair) { [weak self] in self?.confirmUnpair() }
    private var statusTask: Task<Void, Never>?
    private var handingOff = false

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
        phoneButton.accessibilityIdentifier = "settings.crucibleServer.pairWithIPhone"
        showCodeButton.accessibilityIdentifier = "settings.crucibleServer.showCode"
        let buttons = UIStackView(arrangedSubviews: [phoneButton, showCodeButton, codeButton])
        buttons.axis = .horizontal
        buttons.spacing = Theme.Space.m
        unpairButton.accessibilityIdentifier = "settings.crucibleServer.unpair"
        let stack = UIStackView(arrangedSubviews: [heading, statusLabel, detailLabel, buttons, unpairButton])
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
        guard CompanionStore.current() == nil else { return [unpairButton] }
        return [Self.canPairWithIPhone ? phoneButton : showCodeButton]
    }

    /// Whether this Apple TV can show the system's picker of nearby iPhones and iPads running Crucible.
    private static var canPairWithIPhone: Bool {
        DDDevicePickerViewController.isSupported(handOff, using: .applicationService)
    }

    private func refresh() {
        let server = CompanionStore.current()
        heading.text = server.map { CompanionCopy.paired($0.name) } ?? CompanionCopy.title
        statusLabel.text = server == nil ? CompanionCopy.pitch : CompanionCopy.checking
        detailLabel.text = server == nil ? "\(CompanionCopy.stepsTV)\n\(CompanionCopy.installURL.absoluteString)" : nil
        detailLabel.isHidden = server != nil
        codeButton.isHidden = server != nil
        showCodeButton.isHidden = server != nil
        phoneButton.isHidden = server != nil || !Self.canPairWithIPhone
        unpairButton.isHidden = server == nil
        setNeedsFocusUpdate()
        statusTask?.cancel()
        guard let server else { return }
        statusTask = Task { [weak self] in
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
            guard !Task.isCancelled else { return }
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

    /// Lets the person pick a nearby iPhone or iPad running Crucible; once they allow it there, it hands over a pairing
    /// for the server it is paired with, including the certificate fingerprint it pinned.
    private func pairWithIPhone() {
        guard !handingOff, let picker = DDDevicePickerViewController(browseDescriptor: Self.handOff, parameters: .applicationService) else { return }
        handingOff = true
        present(picker, animated: TVMotion.animationsEnabled)
        Task { [weak self] in
            let endpoint: NWEndpoint
            do {
                endpoint = try await picker.endpoint
            } catch {
                picker.dismiss(animated: TVMotion.animationsEnabled)
                self?.handingOff = false
                return
            }
            picker.dismiss(animated: TVMotion.animationsEnabled)
            await self?.handOff(from: endpoint)
            self?.handingOff = false
        }
    }

    private func handOff(from endpoint: NWEndpoint) async {
        statusTask?.cancel()
        statusLabel.text = CompanionCopy.waitingForIPhone
        let connection = NWConnection(to: endpoint, using: .applicationService)
        defer { connection.cancel() }
        let line: String
        do throws(CompanionHandOffChannel.Failure) {
            try await CompanionHandOffChannel.ready(connection, queue: handOffQueue)
            try await CompanionHandOffChannel.send(CompanionHandOff.helloLine(deviceName: UIDevice.current.name), on: connection)
            line = try await CompanionHandOffChannel.readLine(from: connection, timeout: .seconds(120))
        } catch {
            statusLabel.text = CompanionCopy.handOffEnded
            return
        }
        switch CompanionHandOff.answer(inLine: line) {
        case .invite(let invite)?:
            statusLabel.text = CompanionCopy.pairing
            do throws(CompanionError) {
                _ = try await PreviouslyOnRequest.pair(invite, deviceName: UIDevice.current.name, platform: "tvos", handedOn: true)
                refresh()
            } catch {
                statusLabel.text = error.message
            }
        case .declined?, nil:
            statusLabel.text = CompanionCopy.declined
        }
    }

    private func showCode() {
        let screen = TVCompanionCodeViewController()
        screen.onPaired = { [weak self] in
            guard let self else { return }
            navigationController?.popToViewController(self, animated: TVMotion.animationsEnabled)
            refresh()
        }
        TVNavigation.push(screen, from: self)
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
