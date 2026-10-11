import CrucibleDesign
import UIKit

/// Full-screen gate shown from the first frame until the main UI is fully loaded: the crystal
/// glyph and a status line while the launch pipeline runs, a failure panel with Try Again and
/// Switch Server when it cannot reach the server.
final class TVLaunchViewController: UIViewController {
    var onRetry: (() -> Void)?
    var onSwitchServer: (() -> Void)?

    private static let glyphSide: CGFloat = 300
    private static let messageWidth: CGFloat = 900

    private let glyph = CrystalGlyphView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let statusRow = UIStackView()
    private let failureTitleLabel = UILabel()
    private let failureMessageLabel = UILabel()
    private let retryButton = UIButton(configuration: .plain())
    private let switchButton = UIButton(configuration: .plain())
    private let failurePanel = UIStackView()
    private var isShowingFailure = false

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        isShowingFailure ? [retryButton] : []
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = CrystalGlyphView.canvas
        installBackdrop()
        installContent()
        showLoading(status: "Connecting…")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyAmbientAnimation()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        glyph.stopBreathing()
    }

    func showLoading(status: String) {
        isShowingFailure = false
        statusLabel.text = status
        spinner.startAnimating()
        statusRow.isHidden = false
        failurePanel.isHidden = true
        glyph.setDimmed(false)
        applyAmbientAnimation()
    }

    func showFailure(title: String, message: String) {
        isShowingFailure = true
        spinner.stopAnimating()
        statusRow.isHidden = true
        failureTitleLabel.text = title
        failureMessageLabel.text = message
        failurePanel.isHidden = false
        glyph.setDimmed(true)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        UIAccessibility.post(notification: .screenChanged, argument: failureMessageLabel)
    }

    /// Flares the crystal before the cross-dissolve so the hand-off reads as ignition rather than a
    /// cut; with Reduce Motion the hand-off is immediate.
    func playSuccess(completion: @escaping () -> Void) {
        spinner.stopAnimating()
        guard !UIAccessibility.isReduceMotionEnabled else {
            completion()
            return
        }
        glyph.flare(completion: completion)
    }

    /// The glyph's breathing is decoration: it stays off under Reduce Motion and in UI tests, where
    /// an endless animation would keep the test runner from ever seeing the app idle.
    private func applyAmbientAnimation() {
        let allowed = !UIAccessibility.isReduceMotionEnabled && !TVDebugSession.disablesAmbientAnimation
        if allowed && !isShowingFailure && glyph.window != nil {
            glyph.startBreathing()
        } else {
            glyph.stopBreathing()
        }
    }

    private func installBackdrop() {
        let vignette = CAGradientLayer()
        vignette.type = .radial
        vignette.colors = [UIColor(red: 0.16, green: 0.10, blue: 0.05, alpha: 1).cgColor, CrystalGlyphView.canvas.cgColor]
        vignette.locations = [0, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.42)
        vignette.endPoint = CGPoint(x: 1.1, y: 1.1)
        let backdrop = GradientHostView(layer: vignette)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func installContent() {
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.isAccessibilityElement = true
        glyph.accessibilityLabel = "Crucible"
        glyph.accessibilityTraits = .image

        statusLabel.font = Theme.Font.callout
        statusLabel.textColor = Theme.Color.onArtSecondary
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        spinner.color = Theme.Color.onArtSecondary
        spinner.hidesWhenStopped = true
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = Theme.Space.m
        statusRow.addArrangedSubview(spinner)
        statusRow.addArrangedSubview(statusLabel)

        failureTitleLabel.font = Theme.Font.title2
        failureTitleLabel.textColor = Theme.Color.onArt
        failureTitleLabel.textAlignment = .center
        failureTitleLabel.numberOfLines = 2
        failureTitleLabel.accessibilityTraits = .header
        failureMessageLabel.font = Theme.Font.callout
        failureMessageLabel.textColor = Theme.Color.onArtSecondary
        failureMessageLabel.textAlignment = .center
        failureMessageLabel.numberOfLines = 0

        retryButton.configuration = Self.buttonConfiguration(title: "Try Again", symbol: "arrow.clockwise", isPrimary: true)
        retryButton.accessibilityIdentifier = "launch.retry"
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)
        switchButton.configuration = Self.buttonConfiguration(title: "Switch Server", symbol: "arrow.left.arrow.right", isPrimary: false)
        switchButton.accessibilityIdentifier = "launch.switchServer"
        switchButton.addAction(UIAction { [weak self] _ in self?.onSwitchServer?() }, for: .primaryActionTriggered)

        let buttons = UIStackView(arrangedSubviews: [retryButton, switchButton])
        buttons.axis = .horizontal
        buttons.spacing = Theme.Space.m

        failurePanel.axis = .vertical
        failurePanel.alignment = .center
        failurePanel.spacing = Theme.Space.m
        failurePanel.addArrangedSubview(failureTitleLabel)
        failurePanel.addArrangedSubview(failureMessageLabel)
        failurePanel.addArrangedSubview(buttons)
        failurePanel.setCustomSpacing(Theme.Space.l, after: failureMessageLabel)

        let stack = UIStackView(arrangedSubviews: [glyph, statusRow, failurePanel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Space.l
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: Self.glyphSide),
            glyph.heightAnchor.constraint(equalToConstant: Self.glyphSide),
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor),
            failureMessageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.messageWidth),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.messageWidth),
        ])
    }

    /// Glass for both buttons, because the focused prominent glass style is unreadable on tvOS 26;
    /// without glass the primary action is filled with the ember accent.
    private static func buttonConfiguration(title: String, symbol: String, isPrimary: Bool) -> UIButton.Configuration {
        var configuration = Glass.glassButton {
            var fallback = isPrimary ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            fallback.baseBackgroundColor = isPrimary ? Theme.Color.accent : nil
            fallback.baseForegroundColor = isPrimary ? Theme.Color.onAccent : Theme.Color.onArt
            return fallback
        }
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = Theme.Space.xs
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .large
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Theme.Font.buttonLabel
            return attributes
        }
        return configuration
    }
}
