import CrucibleCore
import CrucibleDesign
import UIKit

/// Where a person gives Crucible read access to their Tailscale device list, or takes it back. The
/// token is checked against Tailscale before it is kept, so a mistyped one fails here, in words,
/// and not later as a search that quietly finds nothing.
final class TailnetAccessSheetViewController: UIViewController {
    var onChange: (() -> Void)?

    private static let keysPage = URL(string: "https://login.tailscale.com/admin/settings/keys")!

    private let field = UITextField()
    private let fieldBox = UIView()
    private let errorLabel = UILabel()
    private let saveButton = UIButton(configuration: ThemeButton.primaryConfiguration(title: "Search My Tailnet"))
    private var checkTask: Task<Void, Never>?

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { checkTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        configureField()
        layoutContent()
    }

    private func layoutContent() {
        let title = label("Search Your Tailnet", font: Theme.Font.title2, color: Theme.Color.label)
        title.accessibilityTraits = .header
        let intro = label(
            "Crucible can ask each online computer on your Tailscale network whether it's your Plex server. It needs read access to your device list.",
            font: Theme.Font.subheadline,
            color: Theme.Color.labelSecondary
        )
        let steps = UIStackView(arrangedSubviews: [
            step("1", "Open the Tailscale keys page and choose Generate access token."),
            step("2", "Copy the token. It starts with tskey-api-."),
            step("3", "Paste it below."),
        ])
        steps.axis = .vertical
        steps.spacing = Theme.Space.xs

        var keysConfig = UIButton.Configuration.plain()
        keysConfig.title = "Open the Keys Page"
        keysConfig.image = UIImage(systemName: "arrow.up.right.square")
        keysConfig.imagePadding = 6
        keysConfig.baseForegroundColor = Theme.Color.accentText
        keysConfig.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 8)
        let keysButton = UIButton(configuration: keysConfig)
        keysButton.contentHorizontalAlignment = .leading
        keysButton.addAction(UIAction { _ in UIApplication.shared.open(Self.keysPage) }, for: .touchUpInside)

        let note = label(
            "The token stays in this iPhone's Keychain and is only sent to Tailscale, to read your device list. Tailscale tokens last at most 90 days; Crucible tells you when this one needs replacing.",
            font: Theme.Font.caption1Regular,
            color: Theme.Color.labelTertiary
        )

        errorLabel.font = Theme.Font.footnote
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = Theme.Color.destructive
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.primaryButtonHeight).isActive = true
        saveButton.addAction(UIAction { [weak self] _ in self?.check() }, for: .primaryActionTriggered)

        var arranged: [UIView] = [title, intro, steps, keysButton, fieldBox, errorLabel, saveButton]
        if TailnetAccess.state != .none {
            var removeConfig = UIButton.Configuration.plain()
            removeConfig.title = "Remove Saved Token"
            removeConfig.baseForegroundColor = Theme.Color.destructive
            let remove = UIButton(configuration: removeConfig)
            remove.addAction(UIAction { [weak self] _ in self?.removeToken() }, for: .touchUpInside)
            arranged.append(remove)
        }
        arranged.append(note)

        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        stack.setCustomSpacing(Theme.Space.xxs, after: title)
        stack.setCustomSpacing(Theme.Space.m, after: intro)
        stack.setCustomSpacing(Theme.Space.xxs, after: steps)
        stack.setCustomSpacing(Theme.Space.xs, after: errorLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = false
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Space.l),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Space.l),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Space.l),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Space.l),
        ])
    }

    private func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    private func step(_ number: String, _ text: String) -> UIView {
        let badge = label(number, font: Theme.Font.footnoteSemibold, color: Theme.Color.accentText)
        badge.textAlignment = .center
        badge.widthAnchor.constraint(equalToConstant: 20).isActive = true
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [badge, label(text, font: Theme.Font.footnote, color: Theme.Color.label)])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Theme.Space.xs
        return row
    }

    private func configureField() {
        field.placeholder = "tskey-api-…"
        field.font = Theme.Font.body
        field.adjustsFontForContentSizeCategory = true
        field.textColor = Theme.Color.label
        field.isSecureTextEntry = true
        field.textContentType = .password
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = "Tailscale access token"
        field.addAction(UIAction { [weak self] _ in self?.clearError() }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.check() }, for: .editingDidEndOnExit)

        fieldBox.backgroundColor = Theme.Color.surface
        fieldBox.layer.cornerRadius = Theme.Radius.s
        fieldBox.layer.cornerCurve = .continuous
        fieldBox.layer.borderWidth = 1
        fieldBox.layer.borderColor = Theme.Color.separator.cgColor
        field.translatesAutoresizingMaskIntoConstraints = false
        fieldBox.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: fieldBox.topAnchor, constant: 12),
            field.bottomAnchor.constraint(equalTo: fieldBox.bottomAnchor, constant: -12),
            field.leadingAnchor.constraint(equalTo: fieldBox.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: fieldBox.trailingAnchor, constant: -14),
            fieldBox.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget + 4),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: TailnetAccessSheetViewController, _: UITraitCollection) in
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

    private func setChecking(_ checking: Bool) {
        var config = ThemeButton.primaryConfiguration(title: checking ? "Checking…" : "Search My Tailnet")
        config.showsActivityIndicator = checking
        saveButton.configuration = config
        saveButton.isEnabled = !checking
        field.isEnabled = !checking
        isModalInPresentation = checking
    }

    private func check() {
        guard checkTask == nil else { return }
        let token = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            showError("Paste the token you generated on the Tailscale keys page.")
            return
        }
        clearError()
        field.resignFirstResponder()
        setChecking(true)
        checkTask = Task { [weak self] in
            do {
                _ = try await TailscaleAPI.devices(token: token)
                guard !Task.isCancelled, let self else { return }
                TailnetAccess.save(token)
                Haptics.success()
                dismiss(animated: true) { [onChange] in onChange?() }
            } catch TailscaleAPIError.tokenRejected {
                self?.finishFailed("Tailscale didn't accept that token. Check that you copied all of it and that it hasn't expired.")
            } catch {
                self?.finishFailed("Couldn't reach Tailscale. Check your connection and try again.")
            }
        }
    }

    private func finishFailed(_ message: String) {
        checkTask = nil
        setChecking(false)
        showError(message)
    }

    private func removeToken() {
        TailnetAccess.clear()
        Haptics.soft()
        dismiss(animated: true) { [onChange] in onChange?() }
    }
}
