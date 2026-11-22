import UIKit

/// What an airing's cell in the guide shows.
package struct LiveProgramContentConfiguration: UIContentConfiguration, Hashable {
    package var title: String
    package var detail: String?
    /// How far through the airing the present is, from 0 to 1, while it is on.
    package var progress: Double?
    package var isPast = false
    package var isNew = false
    package var isRecording = false
    /// A row without listings, or one still loading: one quiet cell across the row.
    package var isPlaceholder = false
    package var isHighlighted = false

    package init(title: String, detail: String? = nil, progress: Double? = nil, isPast: Bool = false, isNew: Bool = false, isRecording: Bool = false,
                 isPlaceholder: Bool = false) {
        self.title = title
        self.detail = detail
        self.progress = progress
        self.isPast = isPast
        self.isNew = isNew
        self.isRecording = isRecording
        self.isPlaceholder = isPlaceholder
    }

    package func makeContentView() -> UIView & UIContentView {
        LiveProgramContentView(configuration: self)
    }

    package func updated(for state: UIConfigurationState) -> LiveProgramContentConfiguration {
        var updated = self
        if let cell = state as? UICellConfigurationState {
            updated.isHighlighted = cell.isFocused || cell.isHighlighted || cell.isSelected
        }
        return updated
    }
}

/// The airing's cell: its title, a line with the episode or the time, and a progress bar while it is on.
package final class LiveProgramContentView: UIView, UIContentView {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progress = ProgressBar()
    private let stack = UIStackView()
    private var applied: LiveProgramContentConfiguration

    package var configuration: UIContentConfiguration {
        get { applied }
        set {
            guard let configuration = newValue as? LiveProgramContentConfiguration else { return }
            apply(configuration)
        }
    }

    package init(configuration: LiveProgramContentConfiguration) {
        applied = configuration
        super.init(frame: .zero)
        titleLabel.font = Theme.Font.subheadlineSemibold
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = Theme.Font.caption1Regular
        detailLabel.adjustsFontForContentSizeCategory = true
        stack.axis = .vertical
        stack.spacing = Theme.Space.xxs / 2
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, detailLabel].forEach(stack.addArrangedSubview)
        addSubview(stack)
        progress.style = .onSurface
        progress.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progress)
        let inset = Theme.Space.s
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.Space.xs),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -Theme.Space.xxs / 2),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.xs),
            progress.heightAnchor.constraint(equalToConstant: Theme.Metric.progressBarThickness * 0.75),
        ])
        isAccessibilityElement = true
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply(_ configuration: LiveProgramContentConfiguration) {
        applied = configuration
        let lit = configuration.isHighlighted
        let ink: UIColor = lit ? Theme.Color.onFocusInk : Theme.Color.label
        let inkSecondary: UIColor = lit ? Theme.Color.onFocusInk.withAlphaComponent(0.66) : Theme.Color.labelSecondary
        titleLabel.text = configuration.isRecording ? "● " + configuration.title : configuration.title
        titleLabel.textColor = configuration.isPlaceholder ? inkSecondary : ink
        titleLabel.font = configuration.isPlaceholder ? Theme.Font.footnote : Theme.Font.subheadlineSemibold
        detailLabel.text = configuration.detail
        detailLabel.isHidden = configuration.detail == nil
        detailLabel.textColor = inkSecondary
        progress.isHidden = configuration.progress == nil
        progress.progress = configuration.progress ?? 0
        alpha = configuration.isPast && !lit ? 0.6 : 1
        accessibilityLabel = [configuration.title, configuration.detail].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = configuration.progress != nil ? [.button, .updatesFrequently] : .button
    }
}

/// The guide's colours that only the guide needs.
extension Theme.Color {
    /// Ink on a focused (white) guide cell.
    package static let onFocusInk = UIColor(hex: 0x1A1816)
}

/// The cell of an airing: a rounded surface that turns white under the focus or a touch.
package final class LiveProgramCell: UICollectionViewCell {
    package var program: LiveProgramContentConfiguration? {
        didSet { setNeedsUpdateConfiguration() }
    }

    /// The guide places every cell by its airing's time, so a cell never sizes itself.
    package override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    package override func updateConfiguration(using state: UICellConfigurationState) {
        guard let program else { return }
        contentConfiguration = program.updated(for: state)
        var background = UIBackgroundConfiguration.clear()
        let lit = state.isFocused || state.isHighlighted || state.isSelected
        background.backgroundColor = lit ? .white : (program.progress != nil ? Theme.Color.surfaceRaised : Theme.Color.surface)
        if program.isPlaceholder, !lit { background.backgroundColor = Theme.Color.surface.withAlphaComponent(0.6) }
        background.cornerRadius = Theme.Radius.s
        backgroundConfiguration = background
        #if os(tvOS)
        let grow: CGFloat = state.isFocused ? 1.04 : 1
        transform = CGAffineTransform(scaleX: grow, y: grow)
        layer.shadowOpacity = state.isFocused ? 0.35 : 0
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 10)
        #endif
    }
}

/// A channel in the guide's pinned column: its logo, its number and its name, with a star for a favourite.
package final class LiveChannelHeaderView: UICollectionReusableView {
    package override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    private let logo = UIImageView()
    private let number = UILabel()
    private let name = UILabel()
    private let star = UIImageView(image: UIImage(systemName: "star.fill"))
    private let texts = UIStackView()
    private let row = UIStackView()
    private var logoTask: Task<Void, Never>?
    private var logoURL: URL?

    package override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.surface
        layer.cornerRadius = Theme.Radius.s
        layer.cornerCurve = .continuous
        logo.contentMode = .scaleAspectFit
        logo.backgroundColor = Theme.Color.surfaceRaised
        logo.layer.cornerRadius = Theme.Radius.xs
        logo.clipsToBounds = true
        number.font = Theme.Font.caption2
        number.textColor = Theme.Color.accentText
        name.font = Theme.Font.footnoteSemibold
        name.textColor = Theme.Color.label
        name.numberOfLines = 2
        star.tintColor = Theme.Color.accent
        star.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Theme.Font.caption2)
        star.setContentHuggingPriority(.required, for: .horizontal)
        texts.axis = .vertical
        texts.spacing = 0
        [number, name].forEach(texts.addArrangedSubview)
        row.axis = .horizontal
        row.spacing = Theme.Space.xs
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        [logo, texts, star].forEach(row.addArrangedSubview)
        addSubview(row)
        let inset = Theme.Space.xs
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            logo.heightAnchor.constraint(equalTo: row.heightAnchor),
            logo.widthAnchor.constraint(equalTo: logo.heightAnchor, multiplier: 1.4),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    package override func prepareForReuse() {
        super.prepareForReuse()
        logoTask?.cancel()
        logo.image = nil
        logoURL = nil
    }

    package func configure(number: String?, title: String, logoURL: URL?, isFavorite: Bool) {
        self.number.text = number
        self.number.isHidden = number == nil
        name.text = title
        name.numberOfLines = number == nil ? 2 : 1
        #if os(iOS)
        name.isHidden = logoURL != nil && number != nil
        #endif
        star.isHidden = !isFavorite
        accessibilityLabel = [number, title].compactMap { $0 }.joined(separator: " ")
        guard logoURL != self.logoURL else { return }
        self.logoURL = logoURL
        logo.image = nil
        logoTask?.cancel()
        guard let logoURL else { return }
        logoTask = Task { [weak self] in
            let image = await RemoteImageLoader.shared.image(at: logoURL)
            guard !Task.isCancelled, let self, self.logoURL == logoURL else { return }
            self.logo.image = image
        }
    }
}

/// A half hour's label in the guide's pinned time ruler.
package final class LiveTimeHeaderView: UICollectionReusableView {
    package override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    private let label = UILabel()
    private let tick = UIView()

    package override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.canvas
        label.font = Theme.Font.caption1
        label.textColor = Theme.Color.labelSecondary
        label.translatesAutoresizingMaskIntoConstraints = false
        tick.backgroundColor = Theme.Color.separator
        tick.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tick)
        addSubview(label)
        NSLayoutConstraint.activate([
            tick.leadingAnchor.constraint(equalTo: leadingAnchor),
            tick.widthAnchor.constraint(equalToConstant: Theme.Metric.badgeBorderWidth * 2),
            tick.centerYAnchor.constraint(equalTo: centerYAnchor),
            tick.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.45),
            label.leadingAnchor.constraint(equalTo: tick.trailingAnchor, constant: Theme.Space.xs),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    package func configure(_ text: String) {
        label.text = text
    }
}

/// The ruler's corner above the channel column, which covers what scrolls beneath both.
package final class LiveCornerView: UICollectionReusableView {
    package override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    package override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.canvas
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// The line at the present moment.
package final class LiveNowLineView: UICollectionReusableView {
    package override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    package override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.accent
        layer.cornerRadius = Theme.LiveGuide.nowLineWidth / 2
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A small accent capsule reading BETA that explains the feature when pressed.
package enum BetaTag {
    package static func button(title: String, action: UIAction) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = Theme.Color.accentTint
        configuration.baseForegroundColor = Theme.Color.accentText
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: Theme.Space.xxs / 2, leading: Theme.Space.xs, bottom: Theme.Space.xxs / 2, trailing: Theme.Space.xs)
        var attributes = AttributeContainer()
        attributes.font = Theme.Font.badge
        attributes.kern = 1.2
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        configuration.background.strokeColor = Theme.Color.accent.withAlphaComponent(0.7)
        configuration.background.strokeWidth = Theme.Metric.badgeBorderWidth
        let button = UIButton(configuration: configuration, primaryAction: action)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        #if os(iOS)
        button.isPointerInteractionEnabled = true
        #endif
        return button
    }
}
