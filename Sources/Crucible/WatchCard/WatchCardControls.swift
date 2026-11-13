import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// The four looks as round swatches, each painted in its own ground and accent, the chosen one ringed.
final class WatchCardStyleRow: UIView {
    var onSelect: (WatchCardStyle) -> Void = { _ in }

    private let stack = UIStackView()
    private var buttons: [WatchCardStyle: UIButton] = [:]
    private var selected: WatchCardStyle = .artwork
    private var tone: ArtworkTone?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = Theme.Space.xs
        stack.pin(to: self, insets: .zero)
        for style in WatchCardStyle.allCases {
            let button = UIButton(configuration: .plain())
            button.isPointerInteractionEnabled = true
            button.accessibilityIdentifier = "watchCard.style.\(style.rawValue)"
            button.addAction(UIAction { [weak self] _ in
                guard let self, selected != style else { return }
                Haptics.selection()
                select(style)
                onSelect(style)
            }, for: .primaryActionTriggered)
            buttons[style] = button
            stack.addArrangedSubview(button)
        }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func select(_ style: WatchCardStyle) {
        selected = style
        render()
    }

    /// Repaints the Artwork swatch in the colours of the title on the card.
    func adopt(_ tone: ArtworkTone?) {
        self.tone = tone
        render()
    }

    private func render() {
        for (style, button) in buttons {
            let isSelected = style == selected
            var config = UIButton.Configuration.plain()
            config.image = Self.swatch(WatchCardPalette.make(style, tone: tone), selected: isSelected)
            config.imagePlacement = .top
            config.imagePadding = 6
            config.title = style.title
            config.baseForegroundColor = isSelected ? Theme.Color.label : Theme.Color.labelSecondary
            config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
            config.titleLineBreakMode = .byTruncatingTail
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = isSelected ? Theme.Font.caption1 : Theme.Font.caption1Regular
                return outgoing
            }
            button.configuration = config
            button.accessibilityLabel = style.title
            button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
    }

    /// A disc split between the look's ground and its accent, ringed in the app's accent when chosen.
    private static func swatch(_ palette: WatchCardPalette, selected: Bool) -> UIImage {
        let side: CGFloat = 40
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let disc = rect.insetBy(dx: 5, dy: 5)
            context.cgContext.saveGState()
            UIBezierPath(ovalIn: disc).addClip()
            palette.ground.setFill()
            context.fill(disc)
            palette.accent.setFill()
            let accent = UIBezierPath()
            accent.move(to: CGPoint(x: disc.maxX, y: disc.minY))
            accent.addLine(to: CGPoint(x: disc.maxX, y: disc.maxY))
            accent.addLine(to: CGPoint(x: disc.minX, y: disc.maxY))
            accent.close()
            accent.fill()
            context.cgContext.restoreGState()
            let edge = UIBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5))
            edge.lineWidth = 1
            UIColor.gray.withAlphaComponent(0.35).setStroke()
            edge.stroke()
            guard selected else { return }
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 3
            Theme.Color.accent.setStroke()
            ring.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// What the card shows, as chips that turn on and off: the viewer's rating, the scores, the details and when it was watched.
final class WatchCardOptionChips: UIView {
    enum Option: CaseIterable {
        case rating, scores, details, watched

        var title: String {
            switch self {
            case .rating: return String(localized: "Rating")
            case .scores: return String(localized: "Scores", comment: "Chip on the watch card screen that shows or hides IMDb, Rotten Tomatoes and other scores on the card")
            case .details: return String(localized: "Details")
            case .watched: return String(localized: "When Watched", comment: "Chip on the watch card screen that shows or hides when the title was watched and how much of it")
            }
        }

        var symbol: String {
            switch self {
            case .rating: return "star.fill"
            case .scores: return "chart.bar.fill"
            case .details: return "text.alignleft"
            case .watched: return "calendar"
            }
        }
    }

    var onChange: (Option, Bool) -> Void = { _, _ in }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var buttons: [Option: UIButton] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            heightAnchor.constraint(equalTo: stack.heightAnchor),
        ])
        for option in Option.allCases {
            let button = UIButton(configuration: .plain())
            button.changesSelectionAsPrimaryAction = true
            button.isPointerInteractionEnabled = true
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.accessibilityIdentifier = "watchCard.option.\(option)"
            button.configurationUpdateHandler = { button in
                button.configuration = Self.configuration(for: option, isOn: button.isSelected)
            }
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let button else { return }
                Haptics.selection()
                self?.onChange(option, button.isSelected)
            }, for: .primaryActionTriggered)
            buttons[option] = button
            stack.addArrangedSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(_ option: Option, isOn: Bool) {
        buttons[option]?.isSelected = isOn
    }

    private static func configuration(for option: Option, isOn: Bool) -> UIButton.Configuration {
        var config = isOn ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        config.title = option.title
        config.image = UIImage(systemName: isOn ? "checkmark" : option.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        config.imagePadding = 4
        config.cornerStyle = .capsule
        config.baseBackgroundColor = isOn ? Theme.Color.accentTint : Theme.Color.surfaceRaised
        config.baseForegroundColor = isOn ? Theme.Color.accentText : Theme.Color.labelSecondary
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.scaled(.footnote, 13, .semibold, maximum: 19)
            return outgoing
        }
        return config
    }
}
