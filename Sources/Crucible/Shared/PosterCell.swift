import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// A card of artwork, a 2:3 poster unless its grid gives it another shape, with its caption underneath.
/// Overlay chrome is limited to state badges (unwatched dot or count, progress, downloaded) so the artwork
/// stays legible.
struct PosterContentConfiguration: UIContentConfiguration, Hashable {
    var posterPath: String?
    /// The card's height over its width, which its grid sets to the shape most of its artwork has. Artwork
    /// of another shape is shown whole inside it instead of being cropped to it.
    var artworkAspect: CGFloat = Theme.Size.posterAspect
    var title: String = ""
    var subtitle: String?
    var progress: Double?
    var placeholderIcon: String = "film"
    var isUnwatched: Bool = false
    var unwatchedCount: Int?
    /// A word for the corner pill when there is no count to show ("New", "New Season").
    var badgeText: String?
    var isDownloaded: Bool = false
    var showPlayButton: Bool = false
    var onQuickPlay: (() -> Void)?

    static func == (lhs: PosterContentConfiguration, rhs: PosterContentConfiguration) -> Bool {
        lhs.posterPath == rhs.posterPath && lhs.artworkAspect == rhs.artworkAspect && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && lhs.progress == rhs.progress && lhs.isUnwatched == rhs.isUnwatched
            && lhs.unwatchedCount == rhs.unwatchedCount && lhs.badgeText == rhs.badgeText && lhs.isDownloaded == rhs.isDownloaded
            && lhs.showPlayButton == rhs.showPlayButton
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(posterPath)
        hasher.combine(artworkAspect)
        hasher.combine(title)
        hasher.combine(subtitle)
        hasher.combine(progress)
        hasher.combine(isUnwatched)
        hasher.combine(unwatchedCount)
        hasher.combine(badgeText)
        hasher.combine(isDownloaded)
        hasher.combine(showPlayButton)
    }

    func makeContentView() -> UIView & UIContentView {
        PosterContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> PosterContentConfiguration {
        self
    }
}

final class PosterContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let cardView = UIView()
    private let imageView = UIImageView()
    private let placeholderView = UIImageView()
    private let progressBar = ProgressBar()
    private let unwatchedDot = UIView()
    private let countPill = UIView()
    private let countLabel = UILabel()
    private let downloadChip = Glass.effectView(fallback: .systemThinMaterialDark)
    private let playChip = UIButton()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let captionStack = UIStackView()
    private var captionHeightConstraint: NSLayoutConstraint?
    private var artworkAspectConstraint: NSLayoutConstraint?
    private var imageTask: Task<Void, Never>?
    private var onQuickPlay: (() -> Void)?
    private var currentPosterPath: String? = "__unset__"

    init(configuration: PosterContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        setupViews()
        apply()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: PosterContentView, _: UITraitCollection) in
            view.updateLineLimits()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        ringsFocus(around: cardView, cornerRadius: Theme.Radius.s)
    }

    private func setupViews() {
        cardView.liftsOnHover(cornerRadius: Theme.Radius.s)
        cardView.layer.cornerRadius = Theme.Radius.s
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = Theme.Color.artHairline.cgColor
        cardView.clipsToBounds = true
        cardView.backgroundColor = Theme.Color.surfaceRaised

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true

        placeholderView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .light)
        placeholderView.tintColor = Theme.Color.labelTertiary
        placeholderView.contentMode = .scaleAspectFit

        unwatchedDot.backgroundColor = Theme.Color.accent
        unwatchedDot.layer.cornerRadius = 5.5
        unwatchedDot.layer.borderWidth = 2
        unwatchedDot.layer.borderColor = UIColor.black.withAlphaComponent(0.45).cgColor

        countPill.backgroundColor = Theme.Color.accent
        countPill.layer.cornerRadius = 10
        countPill.layer.cornerCurve = .continuous
        countLabel.font = Theme.Font.scaled(.caption2, 11, .heavy, maximum: 14)
        countLabel.textColor = Theme.Color.onAccent
        countLabel.textAlignment = .center

        configureChip(downloadChip, symbol: "arrow.down", pointSize: 11, weight: .bold)
        configurePlayChip()

        titleLabel.font = Theme.Font.caption1
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.lineBreakMode = .byTruncatingTail

        subtitleLabel.font = Theme.Font.caption2Regular
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = Theme.Color.labelSecondary
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let captionSpacer = UIView()
        captionSpacer.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
        [titleLabel, subtitleLabel, captionSpacer].forEach { captionStack.addArrangedSubview($0) }
        captionStack.axis = .vertical
        captionStack.spacing = 1
        let captionHeight = captionStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        captionHeight.isActive = true
        captionHeightConstraint = captionHeight

        let mainStack = UIStackView(arrangedSubviews: [cardView, captionStack])
        mainStack.axis = .vertical
        mainStack.spacing = 7
        mainStack.alignment = .fill
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        [imageView, placeholderView, progressBar, unwatchedDot, countPill, downloadChip, playChip].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            cardView.addSubview($0)
        }
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countPill.addSubview(countLabel)
        cardView.translatesAutoresizingMaskIntoConstraints = false

        let bottomPin = mainStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomPin.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomPin,

            imageView.topAnchor.constraint(equalTo: cardView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            placeholderView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            placeholderView.widthAnchor.constraint(equalToConstant: 32),
            placeholderView.heightAnchor.constraint(equalToConstant: 32),

            progressBar.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 4),

            unwatchedDot.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 7),
            unwatchedDot.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -7),
            unwatchedDot.widthAnchor.constraint(equalToConstant: 11),
            unwatchedDot.heightAnchor.constraint(equalToConstant: 11),

            countPill.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 6),
            countPill.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -6),
            countPill.heightAnchor.constraint(equalToConstant: 20),
            countPill.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            countLabel.leadingAnchor.constraint(equalTo: countPill.leadingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: countPill.trailingAnchor, constant: -6),
            countLabel.centerYAnchor.constraint(equalTo: countPill.centerYAnchor),

            downloadChip.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 6),
            downloadChip.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),
            downloadChip.widthAnchor.constraint(equalToConstant: 22),
            downloadChip.heightAnchor.constraint(equalToConstant: 22),

            playChip.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -6),
            playChip.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),
            playChip.widthAnchor.constraint(equalToConstant: 28),
            playChip.heightAnchor.constraint(equalToConstant: 28),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        updateLineLimits()
    }

    private func configureChip(_ chip: UIVisualEffectView, symbol: String, pointSize: CGFloat, weight: UIImage.SymbolWeight) {
        chip.layer.cornerRadius = 11
        chip.layer.cornerCurve = .continuous
        chip.clipsToBounds = true
        let glyph = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)))
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        chip.contentView.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: chip.contentView.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: chip.contentView.centerYAnchor),
        ])
    }

    private func configurePlayChip() {
        var config = Glass.glassButton {
            var fallback = UIButton.Configuration.filled()
            fallback.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
            return fallback
        }
        config.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        playChip.configuration = config
        playChip.accessibilityLabel = String(localized: "Play")
        playChip.isPointerInteractionEnabled = true
        playChip.addAction(UIAction { [weak self] _ in self?.onQuickPlay?() }, for: .primaryActionTriggered)
    }

    /// Titles wrap to a second line before they truncate, and the caption always reserves the room
    /// for it, so a rail or grid row never changes height as artwork and titles load.
    private func updateLineLimits() {
        let accessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        titleLabel.numberOfLines = accessibilitySize ? 3 : 2
        subtitleLabel.numberOfLines = accessibilitySize ? 2 : 1
        let titleHeight = titleLabel.font.lineHeight * CGFloat(titleLabel.numberOfLines)
        let subtitleHeight = subtitleLabel.font.lineHeight * CGFloat(subtitleLabel.numberOfLines)
        captionHeightConstraint?.constant = ceil(titleHeight + captionStack.spacing + subtitleHeight)
    }

    private func apply() {
        guard let config = configuration as? PosterContentConfiguration else { return }
        onQuickPlay = config.onQuickPlay
        shapeCard(config.artworkAspect)

        titleLabel.text = config.title
        subtitleLabel.text = config.subtitle
        subtitleLabel.isHidden = (config.subtitle ?? "").isEmpty

        let hasProgress = (config.progress ?? 0) > 0
        progressBar.isHidden = !hasProgress
        if let progress = config.progress, hasProgress { progressBar.progress = progress }

        let showsCount = (config.unwatchedCount ?? 0) > 0
        let pillText = showsCount ? config.unwatchedCount.map(String.init) : config.badgeText?.localizedUppercase
        countPill.isHidden = (pillText ?? "").isEmpty
        countLabel.text = pillText
        unwatchedDot.isHidden = !(config.isUnwatched && countPill.isHidden && !hasProgress)
        downloadChip.isHidden = !config.isDownloaded
        playChip.isHidden = !config.showPlayButton

        accessibilityLabel = Self.spokenDescription(for: config)

        let newPath = config.posterPath
        guard newPath != currentPosterPath else { return }
        imageTask?.cancel()
        imageTask = nil
        currentPosterPath = newPath
        imageView.image = nil
        placeholderView.isHidden = false
        placeholderView.image = UIImage(systemName: config.placeholderIcon)

        guard let posterPath = newPath else { return }
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: posterPath, width: 360)
            guard !Task.isCancelled, let self, let image else { return }
            self.show(image)
        }
    }

    /// Gives the card `aspect`, keeping the constraint when the shape is unchanged, and refits any artwork already shown.
    private func shapeCard(_ aspect: CGFloat) {
        if artworkAspectConstraint?.multiplier != aspect {
            artworkAspectConstraint?.isActive = false
            let constraint = cardView.heightAnchor.constraint(equalTo: cardView.widthAnchor, multiplier: aspect)
            constraint.priority = UILayoutPriority(999)
            constraint.isActive = true
            artworkAspectConstraint = constraint
        }
        if let image = imageView.image { fit(image, aspect: aspect) }
    }

    /// Fills the card with artwork close to its shape and shows any other artwork whole, centred on the card's surface.
    private func fit(_ image: UIImage, aspect: CGFloat) {
        guard image.size.width > 0 else { return }
        let fills = ArtworkAspect.fills(image.size.height / image.size.width, card: aspect)
        imageView.contentMode = fills ? .scaleAspectFill : .scaleAspectFit
    }

    private func show(_ image: UIImage) {
        placeholderView.isHidden = true
        fit(image, aspect: (configuration as? PosterContentConfiguration)?.artworkAspect ?? Theme.Size.posterAspect)
        guard !UIAccessibility.isReduceMotionEnabled, imageView.image == nil else {
            imageView.image = image
            return
        }
        UIView.transition(with: imageView, duration: 0.2, options: .transitionCrossDissolve) {
            self.imageView.image = image
        }
    }

    private static func spokenDescription(for config: PosterContentConfiguration) -> String {
        var parts = [config.title]
        if let subtitle = config.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        if let badge = config.badgeText, !badge.isEmpty { parts.append(badge) }
        if let count = config.unwatchedCount, count > 0 {
            parts.append(String(localized: "\(count) unwatched"))
        } else if config.isUnwatched {
            parts.append(String(localized: "unwatched"))
        }
        if let progress = config.progress, progress > 0 { parts.append(String(localized: "\(Int(progress * 100)) percent watched")) }
        if config.isDownloaded { parts.append(String(localized: "downloaded")) }
        return parts.joined(separator: ", ")
    }
}
