@preconcurrency import UIKit

/// The ember Play Now pill with a darker sweep over its trailing edge that tracks the countdown.
@MainActor
private final class CountdownPlayButton: UIButton {
    let sweep = UIView()
    var sweepFraction: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        sweep.backgroundColor = UIColor.black.withAlphaComponent(0.14)
        sweep.isUserInteractionEnabled = false
        addSubview(sweep)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width * sweepFraction
        sweep.frame = CGRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        bringSubviewToFront(sweep)
    }
}

@MainActor
final class UpNextOverlayView: UIView {
    struct Content {
        let seasonNumber: Int?
        let episodeNumber: Int?
        let episodeTitle: String
        let thumbPath: String?
        let autoplays: Bool
    }

    private static let cardWidth: CGFloat = 372
    private static let cornerRadius: CGFloat = 30
    private static let padding: CGFloat = 16
    private static let buttonHeight: CGFloat = 48
    private static let maxSweepFraction: CGFloat = 0.42

    private let content: Content
    private let countdownLabel = UILabel()
    private let thumbView = UIImageView()
    private let placeholderIcon = UIImageView()
    private let playButton = CountdownPlayButton()
    private let countdownSeconds: Int
    private let onPlayNext: () -> Void
    private let onDismiss: () -> Void
    private var countdownTask: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?
    private var didFinish = false
    private var remaining: Int
    private var landscapeConstraints: [NSLayoutConstraint] = []
    private var portraitConstraints: [NSLayoutConstraint] = []
    private var isLandscapeLayout: Bool?

    init(
        content: Content,
        countdownSeconds: Int = 10,
        onPlayNext: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.content = content
        self.countdownSeconds = countdownSeconds
        self.remaining = countdownSeconds
        self.onPlayNext = onPlayNext
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        build()
        updateSecondaryText()
        loadThumb()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        countdownTask?.cancel()
        thumbTask?.cancel()
    }

    func startCountdown() {
        guard content.autoplays, countdownTask == nil else { return }
        countdownTask = Task { [weak self] in
            guard let self else { return }
            while self.remaining > 0 {
                self.updateSecondaryText()
                self.updateSweep(animatedTo: self.remaining - 1)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                self.remaining -= 1
            }
            self.finish(play: true)
        }
    }

    /// Anchors the card bottom-right in landscape and bottom-center in portrait, following the
    /// host's shape as the device rotates.
    func present(in host: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self)
        let guide = host.safeAreaLayoutGuide
        let preferredWidth = widthAnchor.constraint(equalToConstant: Self.cardWidth)
        preferredWidth.priority = .defaultHigh
        landscapeConstraints = [
            trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -44),
            bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -44),
        ]
        portraitConstraints = [
            centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -96),
        ]
        NSLayoutConstraint.activate([
            preferredWidth,
            leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
            trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),
        ])
        applyHostShape()
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        alpha = 0
        UIView.animate(withDuration: 0.25) { self.alpha = 1 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyHostShape()
    }

    private func applyHostShape() {
        guard let host = superview, !landscapeConstraints.isEmpty else { return }
        let landscape = host.bounds.width > host.bounds.height
        guard landscape != isLandscapeLayout else { return }
        isLandscapeLayout = landscape
        NSLayoutConstraint.deactivate(landscape ? portraitConstraints : landscapeConstraints)
        NSLayoutConstraint.activate(landscape ? landscapeConstraints : portraitConstraints)
    }

    private func build() {
        let glass = Glass.effectView(fallback: .systemThinMaterialDark, interactive: false)
        glass.clipsToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 26.0, tvOS 26.0, *) {
            glass.cornerConfiguration = .corners(radius: .fixed(Self.cornerRadius))
        } else {
            glass.layer.cornerRadius = Self.cornerRadius
            glass.layer.cornerCurve = .continuous
        }

        let header = UILabel()
        header.text = "UP NEXT"
        header.font = Theme.Font.caption2
        header.textColor = Theme.Color.accent
        header.adjustsFontForContentSizeCategory = true

        let titleLabel = UILabel()
        titleLabel.text = content.episodeTitle
        titleLabel.font = Theme.Font.headline
        titleLabel.textColor = Theme.Color.onArt
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true

        countdownLabel.font = Theme.Font.footnote
        countdownLabel.textColor = Theme.Color.onArtSecondary
        countdownLabel.numberOfLines = 2
        countdownLabel.adjustsFontForContentSizeCategory = true
        countdownLabel.accessibilityTraits = .updatesFrequently

        let texts = UIStackView(arrangedSubviews: [header, titleLabel, countdownLabel])
        texts.axis = .vertical
        texts.spacing = 2
        texts.setCustomSpacing(4, after: header)

        let topRow = UIStackView(arrangedSubviews: [makeThumb(), texts])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 14

        let dismissButton = makeDismissButton()
        configurePlayButton()
        let buttons = UIStackView(arrangedSubviews: [dismissButton, playButton])
        buttons.axis = .horizontal
        buttons.spacing = 10
        playButton.widthAnchor.constraint(equalTo: dismissButton.widthAnchor, multiplier: 1.3).isActive = true

        let stack = UIStackView(arrangedSubviews: [topRow, buttons])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glass)
        glass.contentView.addSubview(stack)
        let pad = Self.padding
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -pad),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -pad),
        ])

        accessibilityElements = [titleLabel, countdownLabel, dismissButton, playButton]
        titleLabel.accessibilityLabel = "Up next, \(content.episodeTitle)"
    }

    /// The 128 by 72 episode thumb with a hairline and a film placeholder until artwork arrives.
    private func makeThumb() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = Theme.Color.surfaceHigh
        container.layer.cornerRadius = 12
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.layer.borderWidth = 1
        container.layer.borderColor = Theme.Color.artHairline.cgColor
        container.isAccessibilityElement = false

        placeholderIcon.image = UIImage(
            systemName: "film",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        )
        placeholderIcon.tintColor = Theme.Color.onArtSecondary
        placeholderIcon.contentMode = .center
        placeholderIcon.translatesAutoresizingMaskIntoConstraints = false

        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(placeholderIcon)
        container.addSubview(thumbView)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 128),
            container.heightAnchor.constraint(equalToConstant: 72),
            placeholderIcon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderIcon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            thumbView.topAnchor.constraint(equalTo: container.topAnchor),
            thumbView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            thumbView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func loadThumb() {
        guard let path = content.thumbPath else { return }
        thumbTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadBackdrop(path: path, width: 256)
            guard !Task.isCancelled, let self, let image else { return }
            self.thumbView.image = image
            self.placeholderIcon.isHidden = true
        }
    }

    private func makeDismissButton() -> UIButton {
        var config = Glass.glassButton {
            var fallback = UIButton.Configuration.filled()
            fallback.baseBackgroundColor = UIColor.white.withAlphaComponent(0.18)
            return fallback
        }
        config.title = "Dismiss"
        config.baseForegroundColor = Theme.Color.onArt
        config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.buttonLabel
            return outgoing
        }
        let button = UIButton(configuration: config)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonHeight).isActive = true
        button.addAction(UIAction { [weak self] _ in self?.finish(play: false) }, for: .primaryActionTriggered)
        return button
    }

    private func configurePlayButton() {
        var config = UIButton.Configuration.filled()
        config.title = "Play Now"
        config.image = UIImage(
            systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        config.imagePadding = 8
        config.baseBackgroundColor = Theme.Color.accent
        config.baseForegroundColor = Theme.Color.onAccent
        config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.buttonLabel
            return outgoing
        }
        playButton.configuration = config
        playButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.buttonHeight).isActive = true
        playButton.addAction(UIAction { [weak self] _ in
            Haptics.light()
            self?.finish(play: true)
        }, for: .primaryActionTriggered)
        playButton.accessibilityLabel = "Play now"

        playButton.sweep.isHidden = !content.autoplays
        playButton.sweepFraction = Self.maxSweepFraction
    }

    private func episodeCode() -> String? {
        guard let season = content.seasonNumber, let episode = content.episodeNumber else { return nil }
        return "S\(season) · E\(episode)"
    }

    private func updateSecondaryText() {
        var parts = [String]()
        if let code = episodeCode() { parts.append(code) }
        parts.append(content.autoplays ? "Playing in \(remaining) s" : "Next episode")
        countdownLabel.text = parts.joined(separator: " · ")
    }

    /// The darker sweep covers the right of the Play Now pill and shrinks to nothing as the
    /// countdown reaches zero; it glides unless Reduce Motion is on.
    private func updateSweep(animatedTo secondsLeft: Int) {
        let fraction = Self.maxSweepFraction * CGFloat(max(secondsLeft, 0)) / CGFloat(max(countdownSeconds, 1))
        guard !UIAccessibility.isReduceMotionEnabled, window != nil else {
            playButton.sweepFraction = fraction
            return
        }
        UIView.animate(withDuration: 1, delay: 0, options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]) {
            self.playButton.sweepFraction = fraction
            self.playButton.layoutIfNeeded()
        }
    }

    private func finish(play: Bool) {
        guard !didFinish else { return }
        didFinish = true
        countdownTask?.cancel()
        countdownTask = nil
        if play { onPlayNext() } else { onDismiss() }
    }
}
