import CrucibleCore
import CrucibleDesign
import MidgarCore
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
        connectButton.isPointerInteractionEnabled = true

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
        guard let candidates = AddServerLookup.candidates(from: input) else {
            showError(AddServerLookup.invalidAddressMessage)
            return
        }
        clearError()
        setConnecting(true)
        let token = token
        connectTask = Task { [weak self] in
            let found = await AddServerLookup.find(among: candidates, token: token)
            guard !Task.isCancelled, let self else { return }
            connectTask = nil
            setConnecting(false)
            guard let found else {
                MidgarLog.error("Add server: nothing answered at \(input)", category: .networking)
                showError(AddServerLookup.notFoundMessage(for: input))
                return
            }
            save(found)
        }
    }

    private func save(_ server: FoundServer) {
        AddServerLookup.save(server)
        Haptics.success()
        dismiss(animated: true) { [onSaved] in onSaved?() }
    }
}
