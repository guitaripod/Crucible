import CrucibleDesign
import UIKit

/// Full-screen gate shown from first frame until the main UI is fully loaded. Mirrors the app
/// icon's crystal so the static launch image, this screen and the icon read as one object.
final class LaunchViewController: UIViewController {
    var onRetry: (() -> Void)?
    var onSwitchServer: (() -> Void)?
    var onOpenDownloads: (() -> Void)?

    private let glyph = CrystalGlyphView()
    private let wordmark = UILabel()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let messageLabel = UILabel()
    private let retryButton = UIButton(configuration: .filled())
    private let switchButton = UIButton(configuration: .plain())
    private let downloadsButton = UIButton(configuration: .plain())
    private let actions = UIStackView()

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

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
        glyph.startBreathing()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        glyph.stopBreathing()
    }

    func showLoading(status: String) {
        statusLabel.text = status
        spinner.startAnimating()
        statusLabel.isHidden = false
        spinner.isHidden = false
        messageLabel.isHidden = true
        actions.isHidden = true
        glyph.setDimmed(false)
    }

    func showFailure(title: String, message: String, canOpenDownloads: Bool) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = title
        statusLabel.isHidden = false
        messageLabel.text = message
        messageLabel.isHidden = false
        downloadsButton.isHidden = !canOpenDownloads
        actions.isHidden = false
        glyph.setDimmed(true)
        UIAccessibility.post(notification: .screenChanged, argument: messageLabel)
    }

    /// Flares the crystal before the crossfade so the handoff reads as "ignited" rather than a cut.
    func playSuccess(completion: @escaping () -> Void) {
        spinner.stopAnimating()
        glyph.flare(completion: completion)
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
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: 168),
            glyph.heightAnchor.constraint(equalToConstant: 168),
        ])

        wordmark.text = "Crucible"
        wordmark.font = UIFont.systemFont(ofSize: 34, weight: .bold).rounded()
        wordmark.textColor = Theme.Color.onArt
        wordmark.textAlignment = .center

        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = Theme.Color.onArtSecondary
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2

        spinner.color = Theme.Color.onArtSecondary
        spinner.hidesWhenStopped = true

        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var retry = Glass.prominentButton {
            var fallback = UIButton.Configuration.filled()
            fallback.baseBackgroundColor = Theme.Color.accent
            fallback.baseForegroundColor = Theme.Color.onAccent
            return fallback
        }
        retry.title = "Try Again"
        retry.image = UIImage(systemName: "arrow.clockwise")
        retry.imagePadding = 8
        retry.cornerStyle = .capsule
        retry.buttonSize = .large
        retryButton.configuration = retry
        retryButton.tintColor = Theme.Color.accent
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        var switchConfig = Glass.glassButton {
            var fallback = UIButton.Configuration.gray()
            fallback.baseForegroundColor = Theme.Color.onArt
            return fallback
        }
        switchConfig.title = "Switch Server"
        switchConfig.image = UIImage(systemName: "arrow.left.arrow.right")
        switchConfig.imagePadding = 8
        switchConfig.cornerStyle = .capsule
        switchConfig.buttonSize = .large
        switchButton.configuration = switchConfig
        switchButton.tintColor = Theme.Color.onArt
        switchButton.addAction(UIAction { [weak self] _ in self?.onSwitchServer?() }, for: .touchUpInside)

        var downloads = UIButton.Configuration.plain()
        downloads.title = "Watch Downloads Offline"
        downloads.image = UIImage(systemName: "arrow.down.circle")
        downloads.imagePadding = 6
        downloads.baseForegroundColor = Theme.Color.onArtSecondary
        downloadsButton.configuration = downloads
        downloadsButton.addAction(UIAction { [weak self] _ in self?.onOpenDownloads?() }, for: .touchUpInside)

        actions.axis = .vertical
        actions.spacing = 12
        actions.alignment = .fill
        actions.addArrangedSubview(retryButton)
        actions.addArrangedSubview(switchButton)
        actions.addArrangedSubview(downloadsButton)
        actions.setCustomSpacing(4, after: switchButton)

        let stack = UIStackView(arrangedSubviews: [glyph, wordmark, statusLabel, spinner, messageLabel, actions])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(28, after: glyph)
        stack.setCustomSpacing(18, after: wordmark)
        stack.setCustomSpacing(24, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            actions.widthAnchor.constraint(equalToConstant: 260),
        ])
    }
}

private extension UIFont {
    func rounded() -> UIFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
