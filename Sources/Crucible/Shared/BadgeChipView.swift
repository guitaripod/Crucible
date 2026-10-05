import UIKit

/// Small outlined capsule for technical facts such as 4K, HDR10 or Dolby Atmos.
final class BadgeChipView: UIView {
    private let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        layer.cornerRadius = Theme.Radius.xs
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Theme.Color.labelTertiary.cgColor

        label.text = text
        label.font = Theme.Font.scaled(.caption2, 11, .bold, maximum: 15)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.labelSecondary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: BadgeChipView, _: UITraitCollection) in
            view.layer.borderColor = Theme.Color.labelTertiary.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A horizontal row of badges that never stretches them.
    static func row(_ texts: [String]) -> UIStackView {
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
