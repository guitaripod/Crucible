import CrucibleCore
import CrucibleDesign
import UIKit

/// The hero: the newest file research matched, or for someone who has none yet, an example of what it does.
struct SportsHeroConfiguration: UIContentConfiguration {
    var label: String
    var file: String
    var title: String
    var meta: String
    var posterPath: String?
    var posterWords: SportsPosterWords?
    var kind: SportsKind = .sports
    var isExample: Bool
    var playsChange: Bool

    func makeContentView() -> UIView & UIContentView { SportsHeroView(configuration: self) }
    func updated(for state: UIConfigurationState) -> SportsHeroConfiguration { self }
}

final class SportsHeroView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private static var played = Set<String>()
    private let card = UIView()
    private let poster = SportsPosterView()
    private let chip = UILabel()
    private let change = SportsTransformView()
    private let metaLabel = UILabel()
    private let posterWidth: CGFloat = 104

    init(configuration: SportsHeroConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        card.backgroundColor = Theme.Color.surface
        card.layer.cornerRadius = Theme.Radius.l
        card.layer.cornerCurve = .continuous
        chip.font = Theme.Font.badge
        chip.adjustsFontForContentSizeCategory = true
        chip.textColor = Theme.Color.accentText
        metaLabel.font = Theme.Font.footnote
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = Theme.Color.labelSecondary
        metaLabel.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [chip, change, metaLabel])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = Theme.Space.xs
        text.setCustomSpacing(Theme.Space.s, after: change)
        let row = UIStackView(arrangedSubviews: [poster, text])
        row.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: SportsHeroView, _: UITraitCollection) in
            row.axis = view.traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .vertical : .horizontal
        }
        row.alignment = .top
        row.spacing = Theme.Space.m
        for view in [card, row] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(card)
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Space.m),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Space.m),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Space.m),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Space.m),
            poster.widthAnchor.constraint(equalToConstant: posterWidth),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: Theme.Size.posterAspect),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let configuration = configuration as? SportsHeroConfiguration else { return }
        chip.text = configuration.label.uppercased(with: .current)
        change.show(file: configuration.file, title: configuration.title, titleFont: Theme.Font.title3)
        metaLabel.text = configuration.meta
        metaLabel.isHidden = configuration.meta.isEmpty
        poster.show(path: configuration.posterPath, width: posterWidth, words: configuration.posterWords, kind: configuration.kind)
        accessibilityElements = [chip, change, metaLabel]
        let key = configuration.isExample ? "example" : configuration.title
        if configuration.playsChange, !Self.played.contains(key) {
            Self.played.insert(key)
            DispatchQueue.main.async { [weak self] in self?.change.play() }
        }
    }
}

/// The status pill: what the server is doing, how far setup is, when it last looked, and the way to show or hide setup.
struct SportsPillConfiguration: UIContentConfiguration {
    var symbol: String
    var tint: UIColor
    var title: String
    var detail: String
    var progress: Double?
    var working: Bool
    var action: String?

    func makeContentView() -> UIView & UIContentView { SportsPillView(configuration: self) }
    func updated(for state: UIConfigurationState) -> SportsPillConfiguration { self }
}

final class SportsPillView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let glass = Glass.effectView(fallback: .systemThinMaterial)
    private let icon = UIImageView()
    private let well = UIView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let bar = ProgressBar()
    private let actionLabel = UILabel()

    init(configuration: SportsPillConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        glass.layer.cornerRadius = Theme.Radius.l
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        well.layer.cornerRadius = 18
        well.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .headline, scale: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(icon)
        titleLabel.font = Theme.Font.headline
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        detailLabel.font = Theme.Font.subheadline
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.labelSecondary
        detailLabel.numberOfLines = 0
        bar.style = .onSurface
        actionLabel.font = Theme.Font.subheadlineSemibold
        actionLabel.adjustsFontForContentSizeCategory = true
        actionLabel.textColor = Theme.Color.accentText
        actionLabel.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel, bar, actionLabel])
        text.axis = .vertical
        text.spacing = Theme.Space.xxs
        text.setCustomSpacing(Theme.Space.xs, after: detailLabel)
        text.setCustomSpacing(Theme.Space.xs, after: bar)
        let row = UIStackView(arrangedSubviews: [well, text])
        row.alignment = .center
        row.spacing = Theme.Space.s
        for view in [glass, row] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(glass)
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: Theme.Space.s),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -Theme.Space.s),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: Theme.Space.m),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -Theme.Space.m),
            well.widthAnchor.constraint(equalToConstant: 36),
            well.heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let configuration = configuration as? SportsPillConfiguration else { return }
        icon.image = UIImage(systemName: configuration.symbol)
        icon.tintColor = configuration.tint
        well.backgroundColor = configuration.tint.withAlphaComponent(0.14)
        titleLabel.text = configuration.title
        detailLabel.text = configuration.detail
        detailLabel.isHidden = configuration.detail.isEmpty
        bar.isHidden = configuration.progress == nil
        bar.progress = configuration.progress ?? 0
        actionLabel.text = configuration.action
        actionLabel.isHidden = configuration.action == nil
        accessibilityLabel = configuration.title
        accessibilityValue = configuration.detail
        accessibilityHint = configuration.action
        accessibilityTraits = configuration.action == nil ? .staticText : .button
        pulse(configuration.working)
    }

    /// A slow breathing of the icon while the server works, never with Reduce Motion; one that already breathes keeps its
    /// rhythm through a refresh.
    private func pulse(_ on: Bool) {
        let breathing = well.layer.animation(forKey: "pulse") != nil
        guard on != breathing || UIAccessibility.isReduceMotionEnabled else { return }
        well.layer.removeAnimation(forKey: "pulse")
        guard on, !UIAccessibility.isReduceMotionEnabled else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.45
        breathe.duration = 0.9
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        well.layer.add(breathe, forKey: "pulse")
    }
}
