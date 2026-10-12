import CrucibleCore
import CrucibleDesign
import UIKit

/// A selectable offer: radio mark, name, the free-trial badge when there is a trial, the price line and the plan's terms.
/// The chosen card is outlined in ember and filled with the ember tint, and says so to VoiceOver.
final class PaywallOfferCardView: UIControl {
    let offer: ProOffer
    private let radio = UIImageView()

    init(offer: ProOffer) {
        self.offer = offer
        super.init(frame: .zero)

        layer.cornerRadius = Theme.Radius.m
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5

        radio.contentMode = .center
        radio.setContentHuggingPriority(.required, for: .horizontal)
        radio.setContentCompressionResistancePriority(.required, for: .horizontal)

        let title = UILabel()
        title.text = offer.title
        title.font = Theme.Font.headline
        title.textColor = Theme.Color.label
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true

        let titleRow = UIStackView(arrangedSubviews: [title])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .center
        if let trial = offer.trial {
            titleRow.addArrangedSubview(Self.trialBadge(days: trial.days))
        }
        titleRow.addArrangedSubview(UIView())

        let price = UILabel()
        price.text = offer.priceLine
        price.font = Theme.Font.scaled(.title3, 18, .semibold)
        price.textColor = Theme.Color.label
        let detail = UILabel()
        detail.text = offer.detail
        detail.font = Theme.Font.footnote
        detail.textColor = Theme.Color.labelSecondary
        for label in [price, detail] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }

        let text = UIStackView(arrangedSubviews: [titleRow, price, detail])
        text.axis = .vertical
        text.spacing = 3
        text.setCustomSpacing(6, after: price)

        let row = UIStackView(arrangedSubviews: [radio, text])
        row.alignment = .center
        row.spacing = 14
        row.isUserInteractionEnabled = false
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            radio.widthAnchor.constraint(equalToConstant: 26),
        ])

        isAccessibilityElement = true
        accessibilityLabel = Self.spokenLabel(for: offer)
        applyAppearance()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (card: PaywallOfferCardView, _: UITraitCollection) in
            card.applyAppearance()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool {
        didSet { applyAppearance() }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.6 }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.85 : (isEnabled ? 1 : 0.6) }
    }

    private func applyAppearance() {
        backgroundColor = isSelected ? Theme.Color.accentTint : Theme.Color.surface
        layer.borderColor = (isSelected ? Theme.Color.accent : Theme.Color.separator).resolvedColor(with: traitCollection).cgColor
        let symbol = isSelected ? "checkmark.circle.fill" : "circle"
        radio.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .regular))
        radio.tintColor = isSelected ? Theme.Color.accent : Theme.Color.labelTertiary
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        accessibilityValue = isSelected ? "Selected" : "Not selected"
    }

    private static func trialBadge(days: Int) -> UIView {
        let label = UILabel()
        label.text = "Free for \(days) days"
        label.font = Theme.Font.badge
        label.textColor = Theme.Color.onAccent
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        let capsule = UIView()
        capsule.backgroundColor = Theme.Color.accent
        capsule.layer.cornerRadius = 9
        capsule.layer.cornerCurve = .continuous
        capsule.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -8),
        ])
        capsule.setContentHuggingPriority(.required, for: .horizontal)
        capsule.setContentCompressionResistancePriority(.required, for: .horizontal)
        return capsule
    }

    private static func spokenLabel(for offer: ProOffer) -> String {
        var parts = [offer.title, offer.priceLine, offer.detail]
        if let trial = offer.trial { parts.insert("Free for \(trial.days) days", at: 1) }
        return parts.joined(separator: ", ")
    }
}
