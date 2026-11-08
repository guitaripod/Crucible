import CrucibleCore
import CrucibleDesign
import MidgarCore
import SafariServices
@preconcurrency import UIKit

/// Connects a Trakt account with a device code: the code large, Open Trakt (which copies it and opens the activation page
/// inside the app), and the screen carries on by itself the moment the viewer approves.
final class TraktConnectViewController: UIViewController {
    private let onConnected: @MainActor () -> Void
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let codeStack = UIStackView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private lazy var openButton = UIButton(configuration: Self.primary(TraktCopy.openTrakt), primaryAction: UIAction { [weak self] _ in self?.openTrakt() })
    private lazy var copyButton = UIButton(configuration: Self.secondary(TraktCopy.copyCode), primaryAction: UIAction { [weak self] _ in self?.copyCode() })
    private lazy var retryButton = UIButton(configuration: Self.primary(TraktCopy.newCode), primaryAction: UIAction { [weak self] _ in self?.start() })
    private var session: Task<Void, Never>?
    private var code: TraktLinkCode?
    private weak var safari: SFSafariViewController?

    init(onConnected: @escaping @MainActor () -> Void) {
        self.onConnected = onConnected
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.surface
        title = TraktCopy.connect
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        build()
        start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            session?.cancel()
            session = nil
        }
    }

    private func build() {
        titleLabel.text = TraktCopy.approveTitle
        titleLabel.font = Theme.Font.title2
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        messageLabel.text = TraktCopy.approveMessage
        messageLabel.font = Theme.Font.subheadline
        messageLabel.textColor = Theme.Color.labelSecondary
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.adjustsFontForContentSizeCategory = true

        codeStack.axis = .horizontal
        codeStack.spacing = Theme.Space.xs
        codeStack.alignment = .center
        codeStack.isAccessibilityElement = true
        codeStack.accessibilityIdentifier = "trakt.code"
        setCode(nil)

        statusLabel.font = Theme.Font.footnote
        statusLabel.textColor = Theme.Color.labelSecondary
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.accessibilityIdentifier = "trakt.status"
        spinner.color = Theme.Color.accent
        let statusRow = UIStackView(arrangedSubviews: [spinner, statusLabel])
        statusRow.spacing = Theme.Space.xs
        statusRow.alignment = .center

        openButton.accessibilityIdentifier = "trakt.open"
        retryButton.isHidden = true
        let buttons = UIStackView(arrangedSubviews: [openButton, copyButton, retryButton])
        buttons.axis = .vertical
        buttons.spacing = Theme.Space.s

        let consent = Self.consentCard()

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, codeStack, statusRow, buttons, consent])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Space.m
        stack.setCustomSpacing(Theme.Space.xs, after: titleLabel)
        stack.setCustomSpacing(Theme.Space.l, after: messageLabel)
        stack.setCustomSpacing(Theme.Space.l, after: statusRow)
        stack.setCustomSpacing(Theme.Space.l, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        let guide = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: Theme.Space.l),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Theme.Space.xl),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * Theme.Space.l),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            consent.widthAnchor.constraint(equalTo: stack.widthAnchor),
            openButton.heightAnchor.constraint(equalToConstant: Theme.Size.primaryButtonHeight),
            retryButton.heightAnchor.constraint(equalToConstant: Theme.Size.primaryButtonHeight),
        ])
    }

    private static func consentCard() -> UIView {
        let heading = UILabel()
        heading.text = TraktCopy.consentTitle.uppercased()
        heading.font = Theme.Font.badge
        heading.textColor = Theme.Color.labelTertiary
        let lines = [("play.fill", TraktCopy.consentPlays), ("star", TraktCopy.consentRatings)].map { symbol, text -> UIView in
            let icon = UIImageView(image: UIImage(systemName: symbol))
            icon.tintColor = Theme.Color.accent
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let label = UILabel()
            label.text = text
            label.font = Theme.Font.subheadline
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            let row = UIStackView(arrangedSubviews: [icon, label])
            row.spacing = Theme.Space.s
            row.alignment = .firstBaseline
            return row
        }
        let promise = UILabel()
        promise.text = TraktCopy.consentNever
        promise.font = Theme.Font.footnote
        promise.textColor = Theme.Color.labelTertiary
        promise.numberOfLines = 0
        promise.adjustsFontForContentSizeCategory = true
        let stack = UIStackView(arrangedSubviews: [heading] + lines + [promise])
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        let card = UIView()
        card.backgroundColor = Theme.Color.surfaceRaised
        card.layer.cornerRadius = Theme.Radius.m
        card.layer.cornerCurve = .continuous
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Space.m),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Space.m),
        ])
        return card
    }

    private func start() {
        session?.cancel()
        code = nil
        setCode(nil)
        show(TraktCopy.requestingCode, busy: true, failed: false)
        session = Task { [weak self] in
            for await state in TraktLinkSession().states() {
                guard let self, !Task.isCancelled else { return }
                await handle(state)
            }
        }
    }

    private func handle(_ state: TraktLinkState) async {
        switch state {
        case .requesting:
            show(TraktCopy.requestingCode, busy: true, failed: false)
        case .waiting(let code):
            self.code = code
            setCode(code)
            show(TraktCopy.waiting, busy: true, failed: false)
            UIAccessibility.post(notification: .announcement, argument: "\(TraktCopy.waiting) \(code.userCode.map(String.init).joined(separator: " "))")
        case .approved(let token):
            show(TraktCopy.waiting, busy: true, failed: false)
            await TraktAccount.shared.connect(with: token)
            Haptics.success()
            safari?.dismiss(animated: true)
            dismiss(animated: true) { [onConnected] in onConnected() }
        case .expired:
            show(TraktCopy.expired, busy: false, failed: true)
        case .denied:
            show(TraktCopy.denied, busy: false, failed: true)
        case .notAllowed:
            show(TraktCopy.notAllowed, busy: false, failed: true)
        case .failed(let message):
            guard !message.isEmpty else { return }
            show(message, busy: false, failed: true)
        }
    }

    private func show(_ status: String, busy: Bool, failed: Bool) {
        statusLabel.text = status
        statusLabel.textColor = failed ? Theme.Color.destructive : Theme.Color.labelSecondary
        busy ? spinner.startAnimating() : spinner.stopAnimating()
        openButton.isHidden = failed
        copyButton.isHidden = failed
        retryButton.isHidden = !failed
        openButton.isEnabled = code != nil
        copyButton.isEnabled = code != nil
        codeStack.alpha = failed ? 0.35 : 1
    }

    private func setCode(_ code: TraktLinkCode?) {
        codeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let groups = code?.displayGroups ?? ["––––", "––––"]
        for (index, group) in groups.enumerated() {
            if index > 0 {
                let gap = UIView()
                gap.widthAnchor.constraint(equalToConstant: Theme.Space.s).isActive = true
                codeStack.addArrangedSubview(gap)
            }
            for character in group { codeStack.addArrangedSubview(Self.tile(String(character), placeholder: code == nil)) }
        }
        codeStack.accessibilityLabel = code.map { $0.userCode.map(String.init).joined(separator: " ") } ?? TraktCopy.requestingCode
    }

    private static func tile(_ character: String, placeholder: Bool) -> UIView {
        let label = UILabel()
        label.text = character
        label.font = .monospacedSystemFont(ofSize: 26, weight: .bold)
        label.textAlignment = .center
        label.textColor = placeholder ? Theme.Color.labelTertiary : Theme.Color.label
        label.backgroundColor = Theme.Color.surfaceRaised
        label.layer.cornerRadius = 9
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([label.widthAnchor.constraint(equalToConstant: 34), label.heightAnchor.constraint(equalToConstant: 46)])
        return label
    }

    private func openTrakt() {
        guard let code else { return }
        UIPasteboard.general.string = code.userCode
        let safari = SFSafariViewController(url: code.verificationURL)
        safari.preferredControlTintColor = Theme.Color.accent
        safari.dismissButtonStyle = .done
        self.safari = safari
        present(safari, animated: true)
    }

    private func copyCode() {
        guard let code else { return }
        UIPasteboard.general.string = code.userCode
        Haptics.selection()
        var configuration = copyButton.configuration
        configuration?.title = TraktCopy.codeCopied
        copyButton.configuration = configuration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.copyButton.configuration = Self.secondary(TraktCopy.copyCode)
        }
    }

    private static func primary(_ title: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = Theme.Color.accent
        configuration.baseForegroundColor = Theme.Color.onAccent
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.Font.buttonLabel
            return attributes
        }
        return configuration
    }

    private static func secondary(_ title: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = Theme.Color.label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        return configuration
    }
}

/// Asked once after connecting when Trakt's own Plex link already records plays from this server: one of the two records
/// them, so nothing counts twice.
final class TraktDoublePlayViewController: UIViewController {
    private let server: String
    private var choosesCrucible = true
    private let crucibleOption = UIButton()
    private let traktOption = UIButton()

    init(server: String) {
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.surface
        let icon = UIImageView(image: UIImage(systemName: "arrow.triangle.2.circlepath", withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)))
        icon.tintColor = Theme.Color.accent
        let title = UILabel()
        title.text = TraktCopy.doublePlayTitle
        title.font = Theme.Font.title3
        title.numberOfLines = 0
        title.textAlignment = .center
        let message = UILabel()
        message.text = TraktCopy.doublePlayMessage
        message.font = Theme.Font.subheadline
        message.textColor = Theme.Color.labelSecondary
        message.numberOfLines = 0
        message.textAlignment = .center
        crucibleOption.addAction(UIAction { [weak self] _ in self?.pick(crucible: true) }, for: .touchUpInside)
        traktOption.addAction(UIAction { [weak self] _ in self?.pick(crucible: false) }, for: .touchUpInside)
        let proceed = UIButton(configuration: {
            var configuration = UIButton.Configuration.filled()
            configuration.title = String(localized: "Continue")
            configuration.cornerStyle = .capsule
            configuration.baseBackgroundColor = Theme.Color.accent
            configuration.baseForegroundColor = Theme.Color.onAccent
            return configuration
        }(), primaryAction: UIAction { [weak self] _ in self?.apply() })
        let stack = UIStackView(arrangedSubviews: [icon, title, message, crucibleOption, traktOption, proceed])
        stack.axis = .vertical
        stack.spacing = Theme.Space.m
        stack.setCustomSpacing(Theme.Space.l, after: message)
        stack.setCustomSpacing(Theme.Space.l, after: traktOption)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Space.xl),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            proceed.heightAnchor.constraint(equalToConstant: Theme.Size.primaryButtonHeight),
        ])
        render()
    }

    private func pick(crucible: Bool) {
        choosesCrucible = crucible
        Haptics.selection()
        render()
    }

    private func render() {
        crucibleOption.configuration = Self.option(TraktCopy.crucibleRecords, TraktCopy.crucibleRecordsDetail, selected: choosesCrucible)
        traktOption.configuration = Self.option(TraktCopy.traktRecords, TraktCopy.traktRecordsDetail, selected: !choosesCrucible)
        crucibleOption.accessibilityTraits = choosesCrucible ? [.button, .selected] : .button
        traktOption.accessibilityTraits = choosesCrucible ? .button : [.button, .selected]
    }

    private static func option(_ title: String, _ detail: String, selected: Bool) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.subtitle = detail
        configuration.image = UIImage(systemName: selected ? "largecircle.fill.circle" : "circle")
        configuration.imagePlacement = .leading
        configuration.imagePadding = Theme.Space.s
        configuration.titleAlignment = .leading
        configuration.cornerStyle = .large
        configuration.baseForegroundColor = Theme.Color.label
        configuration.baseBackgroundColor = selected ? Theme.Color.accentTint : Theme.Color.surfaceRaised
        configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in selected ? Theme.Color.accent : Theme.Color.labelTertiary }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.Font.headline
            return attributes
        }
        configuration.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.Font.footnote
            attributes.foregroundColor = Theme.Color.labelSecondary
            return attributes
        }
        return configuration
    }

    private func apply() {
        let server = server
        if choosesCrucible {
            Task { [weak self] in
                do {
                    try await TraktAccount.shared.letCrucibleRecordPlays(server: server)
                    self?.dismiss(animated: true)
                } catch {
                    self?.presentTraktMessage(error.localizedDescription)
                }
            }
        } else {
            TraktAccount.shared.letTraktRecordPlays(server: server)
            dismiss(animated: true)
        }
    }
}
