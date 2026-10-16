import CrucibleCore
import CrucibleDesign
import UIKit

/// What the sheet offers when Crucible could not reach a server on its own: the likely causes with
/// the action that fixes each, and a way to run the search again.
struct ServerAddressRecovery {
    let model: ConnectRecovery
    let perform: (ConnectRecovery.Step) -> Void
    let retry: () -> Void
}

/// A small input sheet for connecting by hostname or IP (for example a Tailscale 100.x address).
/// Validates as the user types and keeps the sheet open, with an inline message, when the submit
/// handler reports a failure. After a failed automatic search it also lists what is likely wrong
/// and searches again by itself when the person returns from turning Tailscale on.
final class ServerAddressSheetViewController: UIViewController {
    var onDidDismiss: (() -> Void)?

    private let onSubmit: (ServerAddress) async -> String?
    private let recovery: ServerAddressRecovery?
    private let tailnetWasConnected = TailnetPresence.isConnected

    private let titleLabel = UILabel()
    private let hintLabel = UILabel()
    private let field = UITextField()
    private let errorLabel = UILabel()
    private let connectButton = ThemeButton.primary(title: "Connect")
    private var submitTask: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?
    private var isSubmitting = false

    init(prefill: String?, recovery: ServerAddressRecovery? = nil, onSubmit: @escaping (ServerAddress) async -> String?) {
        self.onSubmit = onSubmit
        self.recovery = recovery
        super.init(nibName: nil, bundle: nil)
        field.text = prefill
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = recovery == nil ? [.medium(), .large()] : [.large()]
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
        observeReturnToApp()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        submitTask?.cancel()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }

    /// Searching again is only worth it when something changed: the person went to turn Tailscale
    /// on (or off) and came back.
    private func observeReturnToApp() {
        guard recovery != nil else { return }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.isSubmitting, self.presentedViewController == nil,
                      TailnetPresence.isConnected != self.tailnetWasConnected
                else { return }
                self.retrySearch()
            }
        }
    }

    private func retrySearch() {
        guard let recovery else { return }
        dismiss(animated: true) { recovery.retry() }
    }

    private func configureViews() {
        titleLabel.text = "Server Address"
        titleLabel.font = Theme.Font.title2
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.accessibilityTraits = .header

        hintLabel.text = recovery.map { "\($0.model.headline) Fix one of these, or enter its address below." }
            ?? "A hostname or IP such as 100.x.x.x for Tailscale. Crucible tries HTTPS first."
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
        var arranged: [UIView] = [titleLabel, hintLabel]
        if let recovery {
            arranged += recovery.model.steps.map { step in
                RecoveryStepView(model: recovery.model, step: step) { [weak self] in self?.perform(step) }
            }
        }
        arranged += [field, errorLabel]
        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(16, after: hintLabel)
        if recovery != nil, let last = arranged.dropLast(2).last, last !== hintLabel {
            stack.setCustomSpacing(20, after: last)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        var actions: [UIView] = [connectButton]
        if recovery != nil {
            var retryConfig = UIButton.Configuration.plain()
            retryConfig.title = "Search Again"
            retryConfig.baseForegroundColor = Theme.Color.accentText
            let retry = UIButton(configuration: retryConfig)
            retry.addAction(UIAction { [weak self] _ in self?.retrySearch() }, for: .touchUpInside)
            actions.insert(retry, at: 0)
        }
        let actionStack = UIStackView(arrangedSubviews: actions)
        actionStack.axis = .vertical
        actionStack.spacing = 4
        actionStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scroll)
        view.addSubview(actionStack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -24),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            actionStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            actionStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            actionStack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
            connectButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    private func perform(_ step: ConnectRecovery.Step) {
        recovery?.perform(step)
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

/// One likely cause of a failed search: what is wrong in a line, why it matters, and the button that fixes it.
private final class RecoveryStepView: UIView {
    init(model: ConnectRecovery, step: ConnectRecovery.Step, action: @escaping () -> Void) {
        super.init(frame: .zero)
        backgroundColor = Theme.Color.surface
        layer.cornerRadius = Theme.Radius.m
        layer.cornerCurve = .continuous

        let icon = UIImageView(image: UIImage(systemName: model.symbol(of: step)))
        icon.tintColor = Theme.Color.accentText
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .headline)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let title = UILabel()
        title.text = model.title(of: step)
        title.font = Theme.Font.subheadlineSemibold
        title.textColor = Theme.Color.label
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0

        let detail = UILabel()
        detail.text = model.detail(of: step)
        detail.font = Theme.Font.footnote
        detail.textColor = Theme.Color.labelSecondary
        detail.adjustsFontForContentSizeCategory = true
        detail.numberOfLines = 0

        var text: [UIView] = [title, detail]
        if let actionTitle = model.actionTitle(of: step) {
            var config = UIButton.Configuration.tinted()
            config.title = actionTitle
            config.cornerStyle = .capsule
            config.baseForegroundColor = Theme.Color.accentText
            config.baseBackgroundColor = Theme.Color.accent
            let button = UIButton(configuration: config)
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            let row = UIStackView(arrangedSubviews: [button, UIView()])
            row.axis = .horizontal
            text.append(row)
        }
        let textStack = UIStackView(arrangedSubviews: text)
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.setCustomSpacing(10, after: detail)

        let row = UIStackView(arrangedSubviews: [icon, textStack])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
