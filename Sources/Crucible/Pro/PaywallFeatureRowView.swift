import CrucibleCore
import CrucibleDesign
import UIKit

/// One line of "what Pro unlocks": a symbol well, the feature's name and what it does. The row for the feature that opened the
/// paywall is tinted so the reason for the sheet is visible at a glance.
final class PaywallFeatureRowView: UIView {
    init(feature: ProFeature, isHighlighted: Bool) {
        super.init(frame: .zero)

        let well = UIView()
        well.backgroundColor = isHighlighted ? Theme.Color.accent : Theme.Color.surfaceRaised
        well.layer.cornerRadius = 10
        well.layer.cornerCurve = .continuous
        well.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: feature.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)))
        icon.tintColor = isHighlighted ? Theme.Color.onAccent : Theme.Color.accentText
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(icon)
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: 40),
            well.heightAnchor.constraint(equalToConstant: 40),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])

        let title = UILabel()
        title.text = feature.title
        title.font = Theme.Font.headline
        title.textColor = Theme.Color.label
        let summary = UILabel()
        summary.text = feature.summary
        summary.font = Theme.Font.subheadline
        summary.textColor = Theme.Color.labelSecondary
        for label in [title, summary] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let text = UIStackView(arrangedSubviews: [title, summary])
        text.axis = .vertical
        text.spacing = 2

        let row = UIStackView(arrangedSubviews: [well, text])
        row.alignment = .top
        row.spacing = 14
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        backgroundColor = isHighlighted ? Theme.Color.accentTint : .clear
        layer.cornerRadius = Theme.Radius.m
        layer.cornerCurve = .continuous

        isAccessibilityElement = true
        accessibilityLabel = feature.title
        accessibilityValue = feature.summary
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
