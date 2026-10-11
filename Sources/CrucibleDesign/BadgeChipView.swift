import UIKit

/// Small outlined capsule for technical facts such as 4K, HDR10 or Dolby Atmos.
package final class BadgeChipView: UIView {
    private let label = UILabel()

    package init(text: String) {
        super.init(frame: .zero)
        layer.cornerRadius = Theme.Radius.xs
        layer.cornerCurve = .continuous
        layer.borderWidth = Theme.Metric.badgeBorderWidth
        layer.borderColor = Theme.Color.labelTertiary.cgColor

        label.text = text
        label.font = Theme.Font.badge
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.labelSecondary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metric.badgeInsetHorizontal),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Metric.badgeInsetHorizontal),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Metric.badgeInsetVertical),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Metric.badgeInsetVertical),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: BadgeChipView, _: UITraitCollection) in
            view.layer.borderColor = Theme.Color.labelTertiary.cgColor
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    /// A horizontal row of badges that never stretches them.
    package static func row(_ texts: [String]) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: texts.map { BadgeChipView(text: $0) })
        stack.axis = .horizontal
        stack.spacing = Theme.Space.xs
        stack.alignment = .center
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(spacer)
        return stack
    }
}
