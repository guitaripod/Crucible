@preconcurrency import UIKit

/// A 16:9 backdrop card with its caption underneath, used for Continue Watching and episode rails.
struct LandscapeContentConfiguration: UIContentConfiguration, Hashable {
    var imagePath: String?
    var title: String = ""
    var subtitle: String?
    var progress: Double?
    var trailingText: String?
    var badgeText: String?
    var showsPlayChip: Bool = true
    var placeholderIcon: String = "tv"

    func makeContentView() -> UIView & UIContentView {
        LandscapeContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> LandscapeContentConfiguration {
        self
    }
}

final class LandscapeContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let cardView = UIView()
    private let imageView = UIImageView()
    private let placeholderView = UIImageView()
    private let scrimView = ScrimView()
    private let playChip = Glass.effectView(fallback: .systemThinMaterialDark)
    private let trailingLabel = UILabel()
    private let badgeChip = Glass.effectView(fallback: .systemThinMaterialDark)
    private let badgeLabel = UILabel()
    private let progressBar = ProgressBar()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var imageTask: Task<Void, Never>?
    private var currentImagePath: String? = "__unset__"

    init(configuration: LandscapeContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        setupViews()
        apply()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: LandscapeContentView, _: UITraitCollection) in
            view.updateLineLimits()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func setupViews() {
        cardView.layer.cornerRadius = 12
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = Theme.Color.artHairline.cgColor
        cardView.clipsToBounds = true
        cardView.backgroundColor = Theme.Color.surfaceRaised

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true

        placeholderView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .light)
        placeholderView.tintColor = Theme.Color.labelTertiary
        placeholderView.contentMode = .scaleAspectFit

        playChip.layer.cornerRadius = 17
        playChip.layer.cornerCurve = .continuous
        playChip.clipsToBounds = true
        let playGlyph = UIImageView(image: UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)))
        playGlyph.tintColor = .white
        playGlyph.contentMode = .center
        playGlyph.translatesAutoresizingMaskIntoConstraints = false
        playChip.contentView.addSubview(playGlyph)

        trailingLabel.font = Theme.Font.scaled(.caption1, 12, .bold, maximum: 15)
        trailingLabel.textColor = Theme.Color.onArt
        trailingLabel.textAlignment = .right

        badgeChip.layer.cornerRadius = 12
        badgeChip.layer.cornerCurve = .continuous
        badgeChip.clipsToBounds = true
        badgeLabel.font = Theme.Font.scaled(.caption2, 11, .bold, maximum: 14)
        badgeLabel.textColor = Theme.Color.onArt
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeChip.contentView.addSubview(badgeLabel)

        titleLabel.font = Theme.Font.subheadlineSemibold
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        subtitleLabel.font = Theme.Font.footnote
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = Theme.Color.labelSecondary

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 1

        let mainStack = UIStackView(arrangedSubviews: [cardView, textStack])
        mainStack.axis = .vertical
        mainStack.spacing = 8
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        [imageView, placeholderView, scrimView, playChip, trailingLabel, badgeChip, progressBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            cardView.addSubview($0)
        }

        let aspect = cardView.heightAnchor.constraint(equalTo: cardView.widthAnchor, multiplier: 9.0 / 16.0)
        aspect.priority = UILayoutPriority(999)

        let bottomPin = mainStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomPin.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomPin,
            aspect,

            imageView.topAnchor.constraint(equalTo: cardView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            scrimView.topAnchor.constraint(equalTo: cardView.topAnchor),
            scrimView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            scrimView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            placeholderView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            placeholderView.widthAnchor.constraint(equalToConstant: 34),
            placeholderView.heightAnchor.constraint(equalToConstant: 34),

            playChip.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 10),
            playChip.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),
            playChip.widthAnchor.constraint(equalToConstant: 34),
            playChip.heightAnchor.constraint(equalToConstant: 34),
            playGlyph.centerXAnchor.constraint(equalTo: playChip.contentView.centerXAnchor),
            playGlyph.centerYAnchor.constraint(equalTo: playChip.contentView.centerYAnchor),

            trailingLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -10),
            trailingLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -16),
            trailingLabel.leadingAnchor.constraint(greaterThanOrEqualTo: playChip.trailingAnchor, constant: 8),

            badgeChip.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 10),
            badgeChip.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            badgeChip.heightAnchor.constraint(equalToConstant: 24),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeChip.contentView.leadingAnchor, constant: 10),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeChip.contentView.trailingAnchor, constant: -10),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeChip.contentView.centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 4),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        updateLineLimits()
    }

    private func updateLineLimits() {
        let accessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        titleLabel.numberOfLines = accessibilitySize ? 3 : 1
        subtitleLabel.numberOfLines = accessibilitySize ? 2 : 1
    }

    private func apply() {
        guard let config = configuration as? LandscapeContentConfiguration else { return }
        titleLabel.text = config.title
        subtitleLabel.text = config.subtitle
        subtitleLabel.isHidden = (config.subtitle ?? "").isEmpty
        trailingLabel.text = config.trailingText
        trailingLabel.isHidden = (config.trailingText ?? "").isEmpty
        playChip.isHidden = !config.showsPlayChip
        badgeLabel.text = config.badgeText
        badgeChip.isHidden = (config.badgeText ?? "").isEmpty

        let hasProgress = (config.progress ?? 0) > 0
        progressBar.isHidden = !hasProgress
        if let progress = config.progress, hasProgress { progressBar.progress = progress }
        scrimView.isHidden = !(config.showsPlayChip || !(config.trailingText ?? "").isEmpty)

        accessibilityLabel = [config.title, config.subtitle, config.trailingText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        let newPath = config.imagePath
        guard newPath != currentImagePath else { return }
        imageTask?.cancel()
        imageTask = nil
        currentImagePath = newPath
        imageView.image = nil
        placeholderView.isHidden = false
        placeholderView.image = UIImage(systemName: config.placeholderIcon)

        guard let path = newPath else { return }
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadBackdrop(path: path, width: 640)
            guard !Task.isCancelled, let self, let image else { return }
            self.show(image)
        }
    }

    private func show(_ image: UIImage) {
        placeholderView.isHidden = true
        guard !UIAccessibility.isReduceMotionEnabled, imageView.image == nil else {
            imageView.image = image
            return
        }
        UIView.transition(with: imageView, duration: 0.2, options: .transitionCrossDissolve) {
            self.imageView.image = image
        }
    }
}

/// Bottom-weighted black gradient that keeps white text legible over any artwork.
final class ScrimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    var strength: CGFloat = 0.62 {
        didSet { applyColors() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.locations = [0.45, 1.0]
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        (layer as? CAGradientLayer)?.colors = [
            UIColor.black.withAlphaComponent(0).cgColor,
            UIColor.black.withAlphaComponent(strength).cgColor,
        ]
    }
}
