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
        wordmark.textColor = .white
        wordmark.textAlignment = .center

        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2

        spinner.color = UIColor.white.withAlphaComponent(0.7)
        spinner.hidesWhenStopped = true

        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var retry = Glass.prominentButton {
            var fallback = UIButton.Configuration.filled()
            fallback.baseBackgroundColor = .systemOrange
            fallback.baseForegroundColor = .white
            return fallback
        }
        retry.title = "Try Again"
        retry.image = UIImage(systemName: "arrow.clockwise")
        retry.imagePadding = 8
        retry.cornerStyle = .capsule
        retry.buttonSize = .large
        retryButton.configuration = retry
        retryButton.tintColor = .systemOrange
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        var switchConfig = Glass.glassButton {
            var fallback = UIButton.Configuration.gray()
            fallback.baseForegroundColor = .white
            return fallback
        }
        switchConfig.title = "Switch Server"
        switchConfig.image = UIImage(systemName: "arrow.left.arrow.right")
        switchConfig.imagePadding = 8
        switchConfig.cornerStyle = .capsule
        switchConfig.buttonSize = .large
        switchButton.configuration = switchConfig
        switchButton.tintColor = .white
        switchButton.addAction(UIAction { [weak self] _ in self?.onSwitchServer?() }, for: .touchUpInside)

        var downloads = UIButton.Configuration.plain()
        downloads.title = "Watch Downloads Offline"
        downloads.image = UIImage(systemName: "arrow.down.circle")
        downloads.imagePadding = 6
        downloads.baseForegroundColor = UIColor.white.withAlphaComponent(0.7)
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

private final class GradientHostView: UIView {
    private let hosted: CALayer

    init(layer: CALayer) {
        hosted = layer
        super.init(frame: .zero)
        self.layer.addSublayer(layer)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
    }
}

/// The hexagonal crystal from the app icon: gradient body, luminous edges, X-and-spine facets and
/// a hot core, with a soft ambient glow behind it.
final class CrystalGlyphView: UIView {
    static let canvas = UIColor(red: 0.094, green: 0.094, blue: 0.094, alpha: 1)

    private let ambient = CAGradientLayer()
    private let body = CAGradientLayer()
    private let bodyMask = CAShapeLayer()
    private let facets = CAShapeLayer()
    private let edges = CAShapeLayer()
    private let core = CAGradientLayer()
    private let coreMask = CAShapeLayer()

    private static let outline: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.14), CGPoint(x: 0.707, y: 0.41), CGPoint(x: 0.707, y: 0.59),
        CGPoint(x: 0.5, y: 0.86), CGPoint(x: 0.293, y: 0.59), CGPoint(x: 0.293, y: 0.41),
    ]
    private static let center = CGPoint(x: 0.5, y: 0.5)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Crucible"

        ambient.type = .radial
        ambient.colors = [
            UIColor(red: 1, green: 0.45, blue: 0.05, alpha: 0.55).cgColor,
            UIColor(red: 1, green: 0.45, blue: 0.05, alpha: 0.12).cgColor,
            UIColor.clear.cgColor,
        ]
        ambient.locations = [0, 0.45, 1]
        ambient.startPoint = CGPoint(x: 0.5, y: 0.5)
        ambient.endPoint = CGPoint(x: 1, y: 1)

        body.colors = [
            UIColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 1).cgColor,
            UIColor(red: 0.93, green: 0.45, blue: 0.10, alpha: 1).cgColor,
            UIColor(red: 0.55, green: 0.24, blue: 0.06, alpha: 1).cgColor,
        ]
        body.locations = [0, 0.5, 1]
        body.startPoint = CGPoint(x: 0.15, y: 0.1)
        body.endPoint = CGPoint(x: 0.85, y: 0.95)
        body.mask = bodyMask

        facets.fillColor = nil
        facets.strokeColor = UIColor(red: 1, green: 0.85, blue: 0.62, alpha: 0.55).cgColor
        facets.lineWidth = 1
        facets.lineCap = .round

        edges.fillColor = nil
        edges.strokeColor = UIColor(red: 1, green: 0.78, blue: 0.48, alpha: 1).cgColor
        edges.lineWidth = 2
        edges.lineJoin = .round
        edges.shadowColor = UIColor(red: 1, green: 0.6, blue: 0.2, alpha: 1).cgColor
        edges.shadowOpacity = 0.9
        edges.shadowRadius = 6
        edges.shadowOffset = .zero

        core.type = .radial
        core.colors = [
            UIColor.white.cgColor,
            UIColor(red: 1, green: 0.78, blue: 0.35, alpha: 1).cgColor,
            UIColor(red: 1, green: 0.4, blue: 0.0, alpha: 0.85).cgColor,
            UIColor(red: 1, green: 0.4, blue: 0.0, alpha: 0).cgColor,
        ]
        core.locations = [0, 0.12, 0.45, 1]
        core.startPoint = CGPoint(x: 0.5, y: 0.5)
        core.endPoint = CGPoint(x: 1, y: 1)
        core.mask = coreMask

        for sub in [ambient, body, facets, edges, core] {
            layer.addSublayer(sub)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let box = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let scaled = Self.outline.map { CGPoint(x: box.minX + $0.x * side, y: box.minY + $0.y * side) }
        let mid = CGPoint(x: box.minX + Self.center.x * side, y: box.minY + Self.center.y * side)

        let hex = UIBezierPath()
        hex.move(to: scaled[0])
        scaled.dropFirst().forEach { hex.addLine(to: $0) }
        hex.close()

        let ambientBox = box.insetBy(dx: -side * 0.35, dy: -side * 0.35)
        ambient.frame = ambientBox
        body.frame = box
        bodyMask.frame = body.bounds
        bodyMask.path = UIBezierPath(cgPath: hex.cgPath).offset(by: CGPoint(x: -box.minX, y: -box.minY)).cgPath
        edges.frame = bounds
        edges.path = hex.cgPath

        let lines = UIBezierPath()
        lines.move(to: scaled[0]); lines.addLine(to: scaled[3])
        lines.move(to: scaled[5]); lines.addLine(to: scaled[2])
        lines.move(to: scaled[1]); lines.addLine(to: scaled[4])
        facets.frame = bounds
        facets.path = lines.cgPath

        let coreSide = side * 0.34
        core.frame = CGRect(x: mid.x - coreSide / 2, y: mid.y - coreSide / 2, width: coreSide, height: coreSide)
        coreMask.frame = core.bounds
        coreMask.path = UIBezierPath(ovalIn: core.bounds).cgPath
        CATransaction.commit()
    }

    func startBreathing() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.55
        pulse.toValue = 1.0
        pulse.duration = 1.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ambient.add(pulse, forKey: "breathe")

        let swell = CABasicAnimation(keyPath: "transform.scale")
        swell.fromValue = 0.92
        swell.toValue = 1.08
        swell.duration = 1.8
        swell.autoreverses = true
        swell.repeatCount = .infinity
        swell.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        core.add(swell, forKey: "swell")
    }

    func stopBreathing() {
        ambient.removeAnimation(forKey: "breathe")
        core.removeAnimation(forKey: "swell")
    }

    func setDimmed(_ dimmed: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        ambient.opacity = dimmed ? 0.25 : 1
        core.opacity = dimmed ? 0.5 : 1
        body.opacity = dimmed ? 0.7 : 1
        CATransaction.commit()
        if dimmed { stopBreathing() } else if window != nil { startBreathing() }
    }

    func flare(completion: @escaping () -> Void) {
        stopBreathing()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock(completion)
        ambient.opacity = 1
        ambient.transform = CATransform3DMakeScale(1.35, 1.35, 1)
        core.transform = CATransform3DMakeScale(1.6, 1.6, 1)
        edges.shadowRadius = 14
        CATransaction.commit()
    }
}

private extension UIFont {
    func rounded() -> UIFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

private extension UIBezierPath {
    func offset(by delta: CGPoint) -> UIBezierPath {
        apply(CGAffineTransform(translationX: delta.x, y: delta.y))
        return self
    }
}
