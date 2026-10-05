@preconcurrency import UIKit

enum SearchDownloadState: Hashable {
    case hidden, idle, active, completed

    @MainActor init(item: PlexMetadata) {
        guard item.mediaType != "show" else {
            self = .hidden
            return
        }
        switch DownloadManager.shared.item(for: item.id)?.state {
        case .none, .some(.failed): self = .idle
        case .some(.completed): self = .completed
        case .some: self = .active
        }
    }

    var symbol: String {
        switch self {
        case .hidden, .idle: return "arrow.down.circle"
        case .active: return "arrow.down.circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .hidden, .idle: return "Download"
        case .active: return "Downloading"
        case .completed: return "Downloaded"
        }
    }
}

enum SearchCellEffects {
    /// Scales a cell down slightly while it is pressed, unless Reduce Motion is on.
    @MainActor static func installPressEffect(on cell: UICollectionViewCell) {
        cell.configurationUpdateHandler = { cell, state in
            let pressed = state.isHighlighted && !UIAccessibility.isReduceMotionEnabled
            UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                cell.contentView.transform = pressed ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
            }
        }
    }
}

private final class PaddedHitButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let verticalSlop = max(0, (Theme.Size.minTarget - bounds.height) / 2)
        let horizontalSlop = max(0, (Theme.Size.minTarget - bounds.width) / 2)
        return bounds.insetBy(dx: -horizontalSlop, dy: -verticalSlop).contains(point)
    }
}

struct TopResultConfiguration: UIContentConfiguration, Hashable {
    var posterPath: String?
    var title: String = ""
    var meta: String = ""
    var query: String?
    var canPlay: Bool = false
    var downloadState: SearchDownloadState = .hidden
    var placeholderIcon: String = "film"
    var onPlay: (() -> Void)?
    var onDownload: (() -> Void)?
    var downloadMenu: UIMenu?

    static func == (lhs: TopResultConfiguration, rhs: TopResultConfiguration) -> Bool {
        lhs.posterPath == rhs.posterPath && lhs.title == rhs.title && lhs.meta == rhs.meta
            && lhs.query == rhs.query && lhs.canPlay == rhs.canPlay && lhs.downloadState == rhs.downloadState
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(posterPath)
        hasher.combine(title)
        hasher.combine(meta)
        hasher.combine(query)
        hasher.combine(canPlay)
        hasher.combine(downloadState)
    }

    func makeContentView() -> UIView & UIContentView {
        TopResultContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> TopResultConfiguration {
        self
    }
}

final class TopResultContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let posterView = UIImageView()
    private let placeholderView = UIImageView()
    private let captionLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let playButton = PaddedHitButton()
    private let downloadButton = PaddedHitButton()
    private let buttonRow = UIStackView()
    private var imageTask: Task<Void, Never>?
    private var currentPosterPath: String? = "__unset__"
    private var onPlay: (() -> Void)?
    private var onDownload: (() -> Void)?

    init(configuration: TopResultConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func setupViews() {
        let card = UIView()
        card.backgroundColor = Theme.Color.surface
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Theme.Color.separator.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        posterView.contentMode = .scaleAspectFill
        posterView.clipsToBounds = true
        posterView.backgroundColor = Theme.Color.surfaceRaised
        posterView.layer.cornerRadius = Theme.Radius.s
        posterView.layer.cornerCurve = .continuous
        posterView.layer.borderWidth = 1
        posterView.layer.borderColor = Theme.Color.artHairline.cgColor
        posterView.translatesAutoresizingMaskIntoConstraints = false

        placeholderView.tintColor = Theme.Color.labelTertiary
        placeholderView.contentMode = .scaleAspectFit
        placeholderView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .light)
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        posterView.addSubview(placeholderView)

        captionLabel.attributedText = NSAttributedString(
            string: "TOP RESULT",
            attributes: [.font: Theme.Font.caption2, .foregroundColor: Theme.Color.accentText, .kern: 1.0]
        )
        captionLabel.adjustsFontForContentSizeCategory = true

        titleLabel.numberOfLines = 3
        titleLabel.adjustsFontForContentSizeCategory = true

        metaLabel.font = Theme.Font.footnote
        metaLabel.textColor = Theme.Color.labelSecondary
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.numberOfLines = 2

        configurePlayButton()
        configureDownloadButton()

        buttonRow.axis = .horizontal
        buttonRow.spacing = Theme.Space.xs
        buttonRow.alignment = .center
        buttonRow.addArrangedSubview(playButton)
        buttonRow.addArrangedSubview(downloadButton)
        let rowSpacer = UIView()
        rowSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addArrangedSubview(rowSpacer)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Space.xs).isActive = true

        let textStack = UIStackView(arrangedSubviews: [captionLabel, titleLabel, metaLabel, spacer, buttonRow])
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.setCustomSpacing(Theme.Space.xs, after: metaLabel)

        let mainStack = UIStackView(arrangedSubviews: [posterView, textStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 14
        mainStack.alignment = .fill
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(mainStack)

        let posterHeight = posterView.heightAnchor.constraint(equalTo: posterView.widthAnchor, multiplier: Theme.Size.posterAspect)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),

            mainStack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Space.s),
            mainStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Space.s),
            mainStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Space.s),
            mainStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Space.s),

            posterView.widthAnchor.constraint(equalToConstant: 76),
            posterHeight,
            posterView.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            posterView.centerYAnchor.constraint(equalTo: placeholderView.centerYAnchor),
            placeholderView.widthAnchor.constraint(equalToConstant: 28),
            placeholderView.heightAnchor.constraint(equalToConstant: 28),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    private func configurePlayButton() {
        var config = ThemeButton.primaryConfiguration(title: "Play", symbol: "play.fill")
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
        config.imagePadding = 6
        config.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.scaled(.subheadline, 15, .semibold, maximum: 22)
            return outgoing
        }
        playButton.configuration = config
        playButton.accessibilityLabel = "Play"
        playButton.setContentHuggingPriority(.required, for: .horizontal)
        playButton.addAction(UIAction { [weak self] _ in self?.onPlay?() }, for: .primaryActionTriggered)
    }

    private func configureDownloadButton() {
        var config = ThemeButton.glassConfiguration(symbol: SearchDownloadState.idle.symbol)
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        config.image = UIImage(systemName: SearchDownloadState.idle.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        downloadButton.configuration = config
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            downloadButton.widthAnchor.constraint(equalToConstant: 40),
            downloadButton.heightAnchor.constraint(equalToConstant: 40),
        ])
        downloadButton.addAction(UIAction { [weak self] _ in self?.onDownload?() }, for: .primaryActionTriggered)
    }

    private func apply() {
        guard let config = configuration as? TopResultConfiguration else { return }
        onPlay = config.onPlay
        onDownload = config.onDownload

        titleLabel.attributedText = SearchHighlight.attributed(
            config.title, query: config.query, font: Theme.Font.title3, color: Theme.Color.label
        )
        metaLabel.text = config.meta

        playButton.isHidden = !config.canPlay
        let showsDownload = config.downloadState != .hidden
        downloadButton.isHidden = !showsDownload
        buttonRow.isHidden = !config.canPlay && !showsDownload

        downloadButton.configuration?.image = UIImage(
            systemName: config.downloadState.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        )
        downloadButton.accessibilityLabel = config.downloadState.label
        if let menu = config.downloadMenu, config.downloadState != .idle {
            downloadButton.menu = menu
            downloadButton.showsMenuAsPrimaryAction = true
        } else {
            downloadButton.menu = nil
            downloadButton.showsMenuAsPrimaryAction = false
        }

        updateAccessibility(for: config)
        loadPoster(for: config)
    }

    private func updateAccessibility(for config: TopResultConfiguration) {
        accessibilityLabel = "Top result, \(config.title), \(config.meta)"
        var actions = [UIAccessibilityCustomAction]()
        if config.canPlay {
            actions.append(UIAccessibilityCustomAction(name: "Play") { [weak self] _ in
                self?.onPlay?()
                return true
            })
        }
        if config.downloadState == .idle {
            actions.append(UIAccessibilityCustomAction(name: "Download") { [weak self] _ in
                self?.onDownload?()
                return true
            })
        }
        accessibilityCustomActions = actions
    }

    private func loadPoster(for config: TopResultConfiguration) {
        placeholderView.image = UIImage(systemName: config.placeholderIcon)
        guard config.posterPath != currentPosterPath else { return }
        imageTask?.cancel()
        currentPosterPath = config.posterPath
        posterView.image = nil
        placeholderView.isHidden = false
        guard let path = config.posterPath else { return }
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadImage(path: path, width: 228)
            guard !Task.isCancelled, let self, let image else { return }
            self.posterView.image = image
            self.placeholderView.isHidden = true
        }
    }
}

struct SearchEpisodeConfiguration: UIContentConfiguration, Hashable {
    var thumbPath: String?
    var title: String = ""
    var subtitle: String = ""
    var query: String?
    var progress: Double?

    func makeContentView() -> UIView & UIContentView {
        SearchEpisodeContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> SearchEpisodeConfiguration {
        self
    }
}

final class SearchEpisodeContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let thumbView = UIImageView()
    private let placeholderView = UIImageView(image: UIImage(systemName: "tv"))
    private let progressBar = ProgressBar()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var imageTask: Task<Void, Never>?
    private var currentThumbPath: String? = "__unset__"

    init(configuration: SearchEpisodeConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func setupViews() {
        thumbView.contentMode = .scaleAspectFill
        thumbView.clipsToBounds = true
        thumbView.backgroundColor = Theme.Color.surfaceRaised
        thumbView.layer.cornerRadius = 8
        thumbView.layer.cornerCurve = .continuous
        thumbView.layer.borderWidth = 1
        thumbView.layer.borderColor = Theme.Color.artHairline.cgColor
        thumbView.translatesAutoresizingMaskIntoConstraints = false

        placeholderView.tintColor = Theme.Color.labelTertiary
        placeholderView.contentMode = .scaleAspectFit
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        thumbView.addSubview(placeholderView)
        thumbView.addSubview(progressBar)

        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.numberOfLines = 2
        subtitleLabel.adjustsFontForContentSizeCategory = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 1

        let mainStack = UIStackView(arrangedSubviews: [thumbView, textStack])
        mainStack.axis = .horizontal
        mainStack.spacing = Theme.Space.s
        mainStack.alignment = .center
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            thumbView.widthAnchor.constraint(equalToConstant: 104),
            thumbView.heightAnchor.constraint(equalToConstant: 58),
            placeholderView.centerXAnchor.constraint(equalTo: thumbView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: thumbView.centerYAnchor),
            placeholderView.widthAnchor.constraint(equalToConstant: 22),
            placeholderView.heightAnchor.constraint(equalToConstant: 22),
            progressBar.leadingAnchor.constraint(equalTo: thumbView.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: thumbView.trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: thumbView.bottomAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 3),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    private func apply() {
        guard let config = configuration as? SearchEpisodeConfiguration else { return }
        titleLabel.attributedText = SearchHighlight.attributed(
            config.title, query: config.query, font: Theme.Font.subheadlineSemibold, color: Theme.Color.label
        )
        subtitleLabel.attributedText = SearchHighlight.attributed(
            config.subtitle, query: config.query, font: Theme.Font.footnote, color: Theme.Color.labelSecondary
        )
        subtitleLabel.isHidden = config.subtitle.isEmpty

        let hasProgress = (config.progress ?? 0) > 0
        progressBar.isHidden = !hasProgress
        if let progress = config.progress, hasProgress { progressBar.progress = progress }

        accessibilityLabel = [config.title, config.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        loadThumb(for: config)
    }

    private func loadThumb(for config: SearchEpisodeConfiguration) {
        guard config.thumbPath != currentThumbPath else { return }
        imageTask?.cancel()
        currentThumbPath = config.thumbPath
        thumbView.image = nil
        placeholderView.isHidden = false
        guard let path = config.thumbPath else { return }
        imageTask = Task { [weak self] in
            let image = await ImageLoader.shared.loadBackdrop(path: path, width: 312)
            guard !Task.isCancelled, let self, let image else { return }
            self.thumbView.image = image
            self.placeholderView.isHidden = true
        }
    }
}

struct SearchGenreConfiguration: UIContentConfiguration, Hashable {
    var title: String = ""

    func makeContentView() -> UIView & UIContentView {
        SearchGenreContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> SearchGenreConfiguration {
        self
    }
}

final class SearchGenreContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let gradientLayer = CAGradientLayer()
    private let scrimLayer = CAGradientLayer()
    private let titleLabel = UILabel()

    init(configuration: SearchGenreConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        layer.cornerRadius = Theme.Radius.m
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = Theme.Color.artHairline.cgColor

        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(gradientLayer)

        scrimLayer.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.5).cgColor]
        scrimLayer.locations = [0.3, 1]
        layer.addSublayer(scrimLayer)

        titleLabel.font = Theme.Font.headline
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.onArt
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 76),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        scrimLayer.frame = bounds
        CATransaction.commit()
    }

    private func apply() {
        guard let config = configuration as? SearchGenreConfiguration else { return }
        titleLabel.text = config.title
        let pair = GenrePalette.pair(for: config.title)
        gradientLayer.colors = [UIColor(hex: pair.start).cgColor, UIColor(hex: pair.end).cgColor]
        accessibilityLabel = "\(config.title), browse genre"
    }
}

struct SearchChipConfiguration: UIContentConfiguration, Hashable {
    var title: String = ""

    func makeContentView() -> UIView & UIContentView {
        SearchChipContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> SearchChipConfiguration {
        self
    }
}

final class SearchChipContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let titleLabel = UILabel()

    init(configuration: SearchChipConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        backgroundColor = Theme.Color.surfaceRaised
        layer.cornerRadius = FilterChipsView.height / 2
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.Color.separator.cgColor

        let icon = UIImageView(image: UIImage(
            systemName: "clock",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        ))
        icon.tintColor = Theme.Color.labelTertiary
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Font.scaled(.subheadline, 14, .semibold, maximum: 20)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: FilterChipsView.height),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    private func apply() {
        guard let config = configuration as? SearchChipConfiguration else { return }
        titleLabel.text = config.title
        accessibilityLabel = "Recent search, \(config.title)"
    }
}

struct SearchHeaderConfiguration: UIContentConfiguration, Hashable {
    var title: String = ""
    var actionTitle: String?
    var onAction: (() -> Void)?

    static func == (lhs: SearchHeaderConfiguration, rhs: SearchHeaderConfiguration) -> Bool {
        lhs.title == rhs.title && lhs.actionTitle == rhs.actionTitle
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(actionTitle)
    }

    func makeContentView() -> UIView & UIContentView {
        SearchHeaderContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> SearchHeaderConfiguration {
        self
    }
}

final class SearchHeaderContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let titleLabel = UILabel()
    private let actionButton = PaddedHitButton()
    private var onAction: (() -> Void)?

    init(configuration: SearchHeaderConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        titleLabel.font = Theme.Font.title3
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.addAction(UIAction { [weak self] _ in self?.onAction?() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [titleLabel, actionButton])
        stack.axis = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? SearchHeaderConfiguration else { return }
        titleLabel.text = config.title
        onAction = config.onAction

        guard let actionTitle = config.actionTitle else {
            actionButton.isHidden = true
            return
        }
        actionButton.isHidden = false
        var button = UIButton.Configuration.plain()
        button.title = actionTitle
        button.baseForegroundColor = Theme.Color.accentText
        button.contentInsets = .zero
        button.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.subheadline
            return outgoing
        }
        actionButton.configuration = button
        actionButton.accessibilityLabel = "\(actionTitle) \(config.title)"
    }
}
