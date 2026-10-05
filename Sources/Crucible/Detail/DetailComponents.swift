@preconcurrency import UIKit

/// Ember primary pill, then a 52pt glass download ring and a 52pt glass watched toggle.
struct DetailActionsConfiguration: UIContentConfiguration {
    var primaryTitle: String = "Play"
    var primarySymbol: String = "play.fill"
    var primaryAccessibilityLabel: String?
    var isPrimaryEnabled = true
    var downloadState: DownloadRingButton.State?
    var downloadAccessibilityLabel: String?
    var downloadMenu: UIMenu?
    var downloadMenuIsPrimary = false
    var isWatched = false
    var watchedMenu: UIMenu?
    var watchedAccessibilityLabel: String?
    var onPrimary: (() -> Void)?
    var onDownload: ((UIView) -> Void)?
    var onToggleWatched: (() -> Void)?

    func makeContentView() -> UIView & UIContentView {
        DetailActionsContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DetailActionsConfiguration {
        self
    }
}

final class DetailActionsContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let primaryButton = ThemeButton.primary(title: "Play", symbol: "play.fill")
    private let downloadWrap = UIView()
    private let downloadBackground = UIButton(configuration: ThemeButton.glassConfiguration())
    private let downloadRing = DownloadRingButton()
    private let watchedButton = ThemeButton.icon(symbol: "checkmark.circle", label: "Mark Watched", size: Theme.Size.primaryButtonHeight)
    private var appliedPrimary: (String, String)?

    init(configuration: DetailActionsConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()

        primaryButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primaryButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primaryButton.addAction(UIAction { [weak self] _ in
            guard let config = self?.configuration as? DetailActionsConfiguration else { return }
            Haptics.light()
            config.onPrimary?()
        }, for: .primaryActionTriggered)

        downloadBackground.isUserInteractionEnabled = false
        downloadBackground.isAccessibilityElement = false
        downloadBackground.translatesAutoresizingMaskIntoConstraints = false
        downloadRing.diameter = 34
        downloadRing.translatesAutoresizingMaskIntoConstraints = false
        downloadRing.addAction(UIAction { [weak self] _ in
            guard let self, let config = self.configuration as? DetailActionsConfiguration else { return }
            config.onDownload?(self.downloadRing)
        }, for: .primaryActionTriggered)
        downloadWrap.addSubview(downloadBackground)
        downloadWrap.addSubview(downloadRing)
        downloadWrap.translatesAutoresizingMaskIntoConstraints = false

        watchedButton.addAction(UIAction { [weak self] _ in
            guard let config = self?.configuration as? DetailActionsConfiguration, config.watchedMenu == nil else { return }
            Haptics.light()
            config.onToggleWatched?()
        }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [primaryButton, downloadWrap, watchedButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let side = Theme.Size.primaryButtonHeight
        NSLayoutConstraint.activate([
            downloadWrap.widthAnchor.constraint(equalToConstant: side),
            downloadWrap.heightAnchor.constraint(equalToConstant: side),
            downloadBackground.topAnchor.constraint(equalTo: downloadWrap.topAnchor),
            downloadBackground.leadingAnchor.constraint(equalTo: downloadWrap.leadingAnchor),
            downloadBackground.trailingAnchor.constraint(equalTo: downloadWrap.trailingAnchor),
            downloadBackground.bottomAnchor.constraint(equalTo: downloadWrap.bottomAnchor),
            downloadRing.topAnchor.constraint(equalTo: downloadWrap.topAnchor),
            downloadRing.leadingAnchor.constraint(equalTo: downloadWrap.leadingAnchor),
            downloadRing.trailingAnchor.constraint(equalTo: downloadWrap.trailingAnchor),
            downloadRing.bottomAnchor.constraint(equalTo: downloadWrap.bottomAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? DetailActionsConfiguration else { return }
        if appliedPrimary?.0 != config.primaryTitle || appliedPrimary?.1 != config.primarySymbol {
            appliedPrimary = (config.primaryTitle, config.primarySymbol)
            var primary = ThemeButton.primaryConfiguration(title: config.primaryTitle, symbol: config.primarySymbol)
            primary.titleLineBreakMode = .byTruncatingTail
            primaryButton.configuration = primary
        }
        primaryButton.isEnabled = config.isPrimaryEnabled
        primaryButton.accessibilityLabel = config.primaryAccessibilityLabel ?? config.primaryTitle

        if let state = config.downloadState {
            downloadWrap.isHidden = false
            downloadRing.set(state)
            downloadRing.menu = config.downloadMenu
            downloadRing.showsMenuAsPrimaryAction = config.downloadMenuIsPrimary
            if let label = config.downloadAccessibilityLabel {
                downloadRing.accessibilityLabel = label
            }
        } else {
            downloadWrap.isHidden = true
        }

        let symbol = config.isWatched ? "eye.slash" : "checkmark.circle"
        var watched = watchedButton.configuration ?? ThemeButton.glassConfiguration()
        watched.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium))
        watchedButton.configuration = watched
        watchedButton.menu = config.watchedMenu
        watchedButton.showsMenuAsPrimaryAction = config.watchedMenu != nil
        watchedButton.accessibilityLabel = config.watchedAccessibilityLabel ?? (config.isWatched ? "Mark Unwatched" : "Mark Watched")
    }
}

/// Ember progress bar with a trailing "1 h 12 m left".
struct DetailProgressConfiguration: UIContentConfiguration {
    var progress: Double = 0
    var text: String = ""
    var accessibilityText: String = ""

    func makeContentView() -> UIView & UIContentView {
        DetailProgressContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DetailProgressConfiguration {
        self
    }
}

final class DetailProgressContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let bar = ProgressBar()
    private let label = UILabel()

    init(configuration: DetailProgressConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        bar.style = .onSurface
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.font = Theme.Font.caption1Regular
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.labelSecondary
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [bar, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 4),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? DetailProgressConfiguration else { return }
        bar.progress = config.progress
        label.text = config.text
        accessibilityLabel = config.accessibilityText
    }
}

/// A leading-aligned row of glass pills, e.g. "Go to Show" and "Next Episode".
struct DetailPillsConfiguration: UIContentConfiguration {
    struct Pill {
        var title: String
        var symbol: String
        var accessibilityLabel: String?
        var action: () -> Void
    }

    var pills: [Pill] = []

    func makeContentView() -> UIView & UIContentView {
        DetailPillsContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DetailPillsConfiguration {
        self
    }
}

final class DetailPillsContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let stack = UIStackView()

    init(configuration: DetailPillsConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? DetailPillsConfiguration else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for pill in config.pills {
            var buttonConfig = ThemeButton.glassConfiguration(title: pill.title, symbol: pill.symbol)
            buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
            buttonConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            buttonConfig.titleLineBreakMode = .byTruncatingTail
            buttonConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = Theme.Font.subheadlineSemibold
                return outgoing
            }
            let button = UIButton(configuration: buttonConfig)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget).isActive = true
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.accessibilityLabel = pill.accessibilityLabel ?? pill.title
            let action = pill.action
            button.addAction(UIAction { _ in
                Haptics.selection()
                action()
            }, for: .primaryActionTriggered)
            stack.addArrangedSubview(button)
        }
    }
}

/// Side-by-side glass "Audio" and "Subtitles" menu buttons.
struct DetailTracksConfiguration: UIContentConfiguration {
    var audioValue: String?
    var audioMenu: UIMenu?
    var subtitleValue: String?
    var subtitleMenu: UIMenu?

    func makeContentView() -> UIView & UIContentView {
        DetailTracksContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DetailTracksConfiguration {
        self
    }
}

final class DetailTracksContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let audioButton = ThemeButton.menuButton(caption: "Audio", value: "")
    private let subtitleButton = ThemeButton.menuButton(caption: "Subtitles", value: "")

    init(configuration: DetailTracksConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        let stack = UIStackView(arrangedSubviews: [audioButton, subtitleButton])
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            audioButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.Size.minTarget),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? DetailTracksConfiguration else { return }
        configure(audioButton, caption: "Audio", value: config.audioValue, menu: config.audioMenu)
        configure(subtitleButton, caption: "Subtitles", value: config.subtitleValue, menu: config.subtitleMenu)
    }

    private func configure(_ button: UIButton, caption: String, value: String?, menu: UIMenu?) {
        guard let value, let menu else {
            button.isHidden = true
            return
        }
        button.isHidden = false
        ThemeButton.configureMenuButton(button, caption: caption, value: value)
        button.configuration?.subtitleLineBreakMode = .byWordWrapping
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
    }
}

/// Overview clamped to a few lines with an ember "more" toggle that expands in place.
struct DetailOverviewConfiguration: UIContentConfiguration {
    var text: String = ""
    var collapsedLines: Int = 4
    var isExpanded = false
    var isTruncatable = false
    var onToggle: (() -> Void)?

    func makeContentView() -> UIView & UIContentView {
        DetailOverviewContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DetailOverviewConfiguration {
        self
    }

    static func attributedText(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        return NSAttributedString(string: text, attributes: [
            .font: Theme.Font.subheadline,
            .foregroundColor: Theme.Color.labelSecondary,
            .paragraphStyle: paragraph,
        ])
    }

    /// Whether `text` needs more than `lines` lines at `width`, so the toggle is only offered when it does something.
    @MainActor
    static func needsTruncation(_ text: String, width: CGFloat, lines: Int) -> Bool {
        guard width > 0, !text.isEmpty else { return false }
        let attributed = attributedText(text)
        let full = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        let lineHeight = Theme.Font.subheadline.lineHeight + 4
        return full > lineHeight * CGFloat(lines) + 1
    }
}

final class DetailOverviewContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let label = UILabel()
    private let toggleButton = UIButton(configuration: .plain())

    init(configuration: DetailOverviewConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byTruncatingTail

        var buttonConfig = UIButton.Configuration.plain()
        buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 12)
        buttonConfig.baseForegroundColor = Theme.Color.accentText
        buttonConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.subheadlineSemibold
            return outgoing
        }
        toggleButton.configuration = buttonConfig
        toggleButton.contentHorizontalAlignment = .leading
        toggleButton.addAction(UIAction { [weak self] _ in
            guard let config = self?.configuration as? DetailOverviewConfiguration else { return }
            Haptics.selection()
            config.onToggle?()
        }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [label, toggleButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.widthAnchor.constraint(equalTo: stack.widthAnchor),
            toggleButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? DetailOverviewConfiguration else { return }
        label.attributedText = DetailOverviewConfiguration.attributedText(config.text)
        label.numberOfLines = config.isExpanded ? 0 : config.collapsedLines
        toggleButton.isHidden = !config.isTruncatable
        toggleButton.configuration?.title = config.isExpanded ? "less" : "more"
        toggleButton.accessibilityLabel = config.isExpanded ? "Show less" : "Show more"
    }
}

/// Plain, non-interactive capsule chips (genres) in a horizontally scrolling row.
struct DetailChipsConfiguration: UIContentConfiguration {
    var chips: [String] = []
    var accessibilityPrefix = "Genres"

    func makeContentView() -> UIView & UIContentView {
        DetailChipsContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DetailChipsConfiguration {
        self
    }
}

final class DetailChipsContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var appliedChips: [String]?

    init(configuration: DetailChipsConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = Theme.Space.xs
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Theme.Space.m),
            scrollView.frameLayoutGuide.heightAnchor.constraint(equalTo: stack.heightAnchor),
        ])
        isAccessibilityElement = true
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? DetailChipsConfiguration else { return }
        accessibilityLabel = "\(config.accessibilityPrefix): \(config.chips.joined(separator: ", "))"
        guard config.chips != appliedChips else { return }
        appliedChips = config.chips
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        config.chips.forEach { stack.addArrangedSubview(Self.makeChip($0)) }
    }

    private static func makeChip(_ text: String) -> UIView {
        let chip = DetailCapsuleChip()
        chip.label.text = text
        return chip
    }
}

/// A 34pt capsule on the raised surface with a hairline edge.
final class DetailCapsuleChip: UIView {
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.surfaceRaised
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.Color.separator.cgColor
        label.font = Theme.Font.chip
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.label
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DetailCapsuleChip, _: UITraitCollection) in
            view.layer.borderColor = Theme.Color.separator.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// One cell of the two-column "Details" grid: hairline top border, uppercase key, value.
struct DetailFactConfiguration: UIContentConfiguration {
    var key: String = ""
    var value: String = ""

    func makeContentView() -> UIView & UIContentView {
        DetailFactContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DetailFactConfiguration {
        self
    }
}

final class DetailFactContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let hairline = UIView()
    private let keyLabel = UILabel()
    private let valueLabel = UILabel()

    init(configuration: DetailFactConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        hairline.backgroundColor = Theme.Color.separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.adjustsFontForContentSizeCategory = true
        keyLabel.numberOfLines = 1
        valueLabel.font = Theme.Font.subheadline
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = Theme.Color.label
        valueLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [keyLabel, valueLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)
        addSubview(stack)
        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            stack.topAnchor.constraint(equalTo: hairline.bottomAnchor, constant: Theme.Space.xs),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        isAccessibilityElement = true
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? DetailFactConfiguration else { return }
        keyLabel.attributedText = DetailFormat.eyebrow(config.key, color: Theme.Color.labelTertiary)
        valueLabel.text = config.value
        accessibilityLabel = "\(config.key), \(config.value)"
    }
}

/// Show season row: a glass "Season 2 ⌄" menu capsule and a "3 of 10 watched" footnote.
struct DetailSeasonBarConfiguration: UIContentConfiguration {
    var seasonTitle: String = ""
    var menu: UIMenu?
    var watchedText: String?

    func makeContentView() -> UIView & UIContentView {
        DetailSeasonBarContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DetailSeasonBarConfiguration {
        self
    }
}

final class DetailSeasonBarContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let seasonButton = UIButton()
    private let watchedLabel = UILabel()

    init(configuration: DetailSeasonBarConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        preferContentHeight()
        seasonButton.showsMenuAsPrimaryAction = true
        seasonButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        seasonButton.setContentHuggingPriority(.required, for: .horizontal)
        watchedLabel.font = Theme.Font.footnote
        watchedLabel.adjustsFontForContentSizeCategory = true
        watchedLabel.textColor = Theme.Color.labelSecondary
        watchedLabel.textAlignment = .right
        watchedLabel.numberOfLines = 2
        watchedLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [seasonButton, watchedLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            seasonButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? DetailSeasonBarConfiguration else { return }
        var buttonConfig = ThemeButton.glassConfiguration(title: config.seasonTitle)
        buttonConfig.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold))
        buttonConfig.imagePlacement = .trailing
        buttonConfig.imagePadding = 8
        buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 14)
        buttonConfig.titleLineBreakMode = .byTruncatingTail
        buttonConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.scaled(.callout, 16, .semibold, maximum: 24)
            return outgoing
        }
        seasonButton.configuration = buttonConfig
        seasonButton.menu = config.menu
        seasonButton.isEnabled = config.menu != nil
        seasonButton.accessibilityLabel = "\(config.seasonTitle), choose season"
        watchedLabel.text = config.watchedText
        watchedLabel.isHidden = config.watchedText == nil
    }
}
