import CrucibleCore
import CrucibleDesign
import UIKit

/// One way to buy Pro on the paywall: a focusable plate with the plan, its price line, what it means and, when the user can
/// still have it, the free trial. Select chooses the plan; buying is the separate button below, so the price is always read
/// before anything is bought. The chosen plan shows an ember rim and a filled check, which survive losing focus.
final class TVPaywallOfferCard: TVFocusableSurface {
    private static let indicatorSide: CGFloat = 52

    private let indicator = UIImageView()
    private let titleLabel = UILabel()
    private let badge = TVPaywallTrialBadge()
    private let priceLabel = UILabel()
    private let detailLabel = UILabel()
    private let selectionRim = UIView()

    init() {
        super.init(cornerRadius: Theme.Radius.l)
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(offer: ProOffer, isSelected: Bool, isDimmed: Bool) {
        titleLabel.text = offer.title
        priceLabel.text = offer.priceLine
        detailLabel.text = offer.detail
        badge.setText(offer.trial.map { "Free for \($0.days) days" })
        selectionRim.alpha = isSelected ? 1 : 0
        indicator.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        indicator.tintColor = isSelected ? Theme.Color.accent : Theme.Color.labelTertiary
        alpha = isDimmed ? 0.5 : 1
        accessibilityLabel = [offer.title, offer.priceLine, offer.detail].joined(separator: ". ")
        accessibilityValue = isSelected ? "Selected" : nil
        accessibilityHint = isSelected ? nil : "Select to choose this plan"
        accessibilityTraits = Self.traits(isSelected: isSelected, isDimmed: isDimmed)
    }

    private static func traits(isSelected: Bool, isDimmed: Bool) -> UIAccessibilityTraits {
        var traits = UIAccessibilityTraits.button
        if isSelected { traits.insert(.selected) }
        if isDimmed { traits.insert(.notEnabled) }
        return traits
    }

    private func buildHierarchy() {
        indicator.contentMode = .center
        indicator.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: TVMetrics.Symbol.tile, weight: .regular)
        indicator.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Font.headline
        titleLabel.textColor = Theme.Color.label
        priceLabel.font = TVFont.control
        priceLabel.textColor = Theme.Color.label
        priceLabel.numberOfLines = 0
        detailLabel.font = TVFont.cardSubtitle
        detailLabel.textColor = Theme.Color.labelSecondary
        detailLabel.numberOfLines = 0

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, badge, UIView()])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = Theme.Space.s

        let text = UIStackView(arrangedSubviews: [titleRow, priceLabel, detailLabel])
        text.axis = .vertical
        text.spacing = Theme.Space.xxs

        let row = UIStackView(arrangedSubviews: [indicator, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.m
        row.translatesAutoresizingMaskIntoConstraints = false

        selectionRim.layer.borderWidth = 5
        selectionRim.layer.borderColor = Theme.Color.accent.cgColor
        selectionRim.layer.cornerRadius = Theme.Radius.l
        selectionRim.layer.cornerCurve = .continuous
        selectionRim.isUserInteractionEnabled = false
        selectionRim.translatesAutoresizingMaskIntoConstraints = false

        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.m, leading: Theme.Space.l, bottom: Theme.Space.m, trailing: Theme.Space.l)
        contentView.addSubview(row)
        contentView.addSubview(selectionRim)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: Self.indicatorSide),
            row.topAnchor.constraint(equalTo: margins.topAnchor),
            row.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            selectionRim.topAnchor.constraint(equalTo: contentView.topAnchor),
            selectionRim.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            selectionRim.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            selectionRim.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }
}

/// The "Free for 14 days" capsule next to a plan's name: ember with dark text in both appearances.
final class TVPaywallTrialBadge: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.accent
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
        label.font = Theme.Font.caption1
        label.textColor = Theme.Color.onAccent
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.s),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.xxs),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.xxs),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `text`, or hides the badge for nil.
    func setText(_ text: String?) {
        label.text = text
        isHidden = text == nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
