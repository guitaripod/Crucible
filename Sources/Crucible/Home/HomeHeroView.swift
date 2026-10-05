@preconcurrency import UIKit

/// The artwork source of a hero card: server backdrop, or a poster saved beside a download.
enum HomeHeroArtwork: Hashable {
    case none
    case backdrop(String)
    case offlinePoster(String)
}

/// The 28pt-radius resume card at the top of Home (and the downloaded hero on offline Home).
struct HomeHeroConfiguration: UIContentConfiguration, Hashable {
    var artwork: HomeHeroArtwork = .none
    var eyebrow: String = ""
    var title: String = ""
    var subtitle: String?
    var actionTitle: String = "Resume"
    var trailingText: String?
    var progress: Double?
    var showsInfoButton: Bool = true
    var minimumHeight: CGFloat = Theme.Size.heroCardHeight
    var spokenLabel: String = ""
    var onPrimary: (() -> Void)?
    var onDetails: (() -> Void)?

    static func == (lhs: HomeHeroConfiguration, rhs: HomeHeroConfiguration) -> Bool {
        lhs.artwork == rhs.artwork && lhs.eyebrow == rhs.eyebrow && lhs.title == rhs.title
            && lhs.subtitle == rhs.subtitle && lhs.actionTitle == rhs.actionTitle
            && lhs.trailingText == rhs.trailingText && lhs.progress == rhs.progress
            && lhs.showsInfoButton == rhs.showsInfoButton && lhs.minimumHeight == rhs.minimumHeight
            && lhs.spokenLabel == rhs.spokenLabel
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(artwork)
        hasher.combine(title)
        hasher.combine(subtitle)
        hasher.combine(progress)
    }

    func makeContentView() -> UIView & UIContentView {
        HomeHeroContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> HomeHeroConfiguration {
        self
    }
}

final class HomeHeroContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let cardView = UIView()
    private let imageView = UIImageView()
    private let placeholderView = UIImageView()
    private let scrimView = ScrimView()
    private let eyebrowLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let primaryButton = UIButton()
    private let trailingLabel = UILabel()
    private let infoButton = UIButton()
    private let actionRow = UIStackView()
    private let progressBar = ProgressBar()
    private var minimumHeightConstraint: NSLayoutConstraint?
    private var imageTask: Task<Void, Never>?
    private var currentArtwork: HomeHeroArtwork?
    private var onPrimary: (() -> Void)?
    private var onDetails: (() -> Void)?

    init(configuration: HomeHeroConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: HomeHeroContentView, _: UITraitCollection) in
            view.updateForContentSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func setupViews() {
        cardView.backgroundColor = Theme.Color.surfaceRaised
        cardView.layer.cornerRadius = Theme.Radius.hero
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = Theme.Color.artHairline.cgColor
        cardView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true

        placeholderView.image = UIImage(systemName: "play.rectangle")
        placeholderView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .light)
        placeholderView.tintColor = Theme.Color.labelTertiary
        placeholderView.contentMode = .center

        scrimView.strength = 0.82
        (scrimView.layer as? CAGradientLayer)?.locations = [0.3, 1.0]

        eyebrowLabel.font = Theme.Font.scaled(.caption2, 11, .bold, maximum: 16)
        eyebrowLabel.adjustsFontForContentSizeCategory = true
        eyebrowLabel.textColor = Theme.Color.accent

        titleLabel.font = Theme.Font.title1
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.onArt
        titleLabel.numberOfLines = 2

        subtitleLabel.font = Theme.Font.subheadline
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = Theme.Color.onArtSecondary

        trailingLabel.font = Theme.Font.scaled(.subheadline, 14, .regular, maximum: 22)
        trailingLabel.adjustsFontForContentSizeCategory = true
        trailingLabel.textColor = Theme.Color.onArtSecondary
        trailingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        primaryButton.addAction(UIAction { [weak self] _ in self?.onPrimary?() }, for: .primaryActionTriggered)
        primaryButton.setContentHuggingPriority(.required, for: .horizontal)
        primaryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        primaryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

        var info = Glass.glassButton {
            var fallback = UIButton.Configuration.filled()
            fallback.baseBackgroundColor = UIColor.black.withAlphaComponent(0.35)
            return fallback
        }
        info.image = UIImage(systemName: "info.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        info.baseForegroundColor = Theme.Color.onArt
        info.cornerStyle = .capsule
        info.contentInsets = .zero
        infoButton.configuration = info
        infoButton.accessibilityLabel = "Details"
        infoButton.addAction(UIAction { [weak self] _ in self?.onDetails?() }, for: .primaryActionTriggered)
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            infoButton.widthAnchor.constraint(equalToConstant: Theme.Size.iconButton),
            infoButton.heightAnchor.constraint(equalToConstant: Theme.Size.iconButton),
        ])

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionRow.addArrangedSubview(primaryButton)
        actionRow.addArrangedSubview(trailingLabel)
        actionRow.addArrangedSubview(spacer)
        actionRow.addArrangedSubview(infoButton)
        actionRow.spacing = Theme.Space.s

        let textStack = UIStackView(arrangedSubviews: [eyebrowLabel, titleLabel, subtitleLabel, actionRow, progressBar])
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 0
        textStack.setCustomSpacing(4, after: eyebrowLabel)
        textStack.setCustomSpacing(14, after: subtitleLabel)
        textStack.setCustomSpacing(14, after: actionRow)

        [cardView, imageView, placeholderView, scrimView, textStack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(cardView)
        [imageView, placeholderView, scrimView, textStack].forEach { cardView.addSubview($0) }

        let minimumHeight = cardView.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.heroCardHeight)
        minimumHeightConstraint = minimumHeight
        let preferredHeight = cardView.heightAnchor.constraint(equalToConstant: Theme.Size.heroCardHeight)
        preferredHeight.priority = .defaultLow
        preferredHeight.isActive = true

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            minimumHeight,

            imageView.topAnchor.constraint(equalTo: cardView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            placeholderView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            placeholderView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: Theme.Space.xl),

            scrimView.topAnchor.constraint(equalTo: cardView.topAnchor),
            scrimView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            scrimView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            scrimView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            textStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            textStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            textStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: cardView.topAnchor, constant: 20),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        updateForContentSize()
    }

    private func updateForContentSize() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        actionRow.axis = large ? .vertical : .horizontal
        actionRow.alignment = large ? .leading : .center
        titleLabel.numberOfLines = large ? 4 : 2
        subtitleLabel.numberOfLines = large ? 3 : 1
    }

    private func apply() {
        guard let config = configuration as? HomeHeroConfiguration else { return }
        onPrimary = config.onPrimary
        onDetails = config.onDetails
        minimumHeightConstraint?.constant = config.minimumHeight

        eyebrowLabel.attributedText = NSAttributedString(string: config.eyebrow.uppercased(), attributes: [.kern: 1.0])
        titleLabel.text = config.title
        subtitleLabel.text = config.subtitle
        subtitleLabel.isHidden = (config.subtitle ?? "").isEmpty
        trailingLabel.text = config.trailingText
        trailingLabel.isHidden = (config.trailingText ?? "").isEmpty
        infoButton.isHidden = !config.showsInfoButton

        var primary = ThemeButton.primaryConfiguration(title: config.actionTitle, symbol: "play.fill")
        primary.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
        primaryButton.configuration = primary
        primaryButton.isAccessibilityElement = false

        let hasProgress = (config.progress ?? 0) > 0
        progressBar.isHidden = !hasProgress
        progressBar.progress = config.progress ?? 0

        accessibilityLabel = config.spokenLabel
        var custom = [UIAccessibilityCustomAction]()
        if config.showsInfoButton {
            custom.append(UIAccessibilityCustomAction(name: "View Details") { [weak self] _ in
                self?.onDetails?()
                return true
            })
        }
        accessibilityCustomActions = custom

        loadArtwork(config.artwork)
    }

    override func accessibilityActivate() -> Bool {
        guard let onPrimary else { return false }
        onPrimary()
        return true
    }

    private func loadArtwork(_ artwork: HomeHeroArtwork) {
        guard artwork != currentArtwork else { return }
        currentArtwork = artwork
        imageTask?.cancel()
        imageTask = nil
        imageView.image = nil
        placeholderView.isHidden = false

        let width = 1080
        switch artwork {
        case .none:
            return
        case .backdrop(let path):
            imageTask = Task { [weak self] in
                let image = await ImageLoader.shared.loadBackdrop(path: path, width: width)
                guard !Task.isCancelled, let self, let image else { return }
                self.show(image)
            }
        case .offlinePoster(let ratingKey):
            imageTask = Task { [weak self] in
                let image = await OfflinePoster.image(ratingKey: ratingKey)
                guard !Task.isCancelled, let self, let image else { return }
                self.show(image)
            }
        }
    }

    private func show(_ image: UIImage) {
        placeholderView.isHidden = true
        guard !UIAccessibility.isReduceMotionEnabled else {
            imageView.image = image
            return
        }
        UIView.transition(with: imageView, duration: 0.25, options: .transitionCrossDissolve) {
            self.imageView.image = image
        }
    }
}
