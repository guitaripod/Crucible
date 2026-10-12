import CrucibleCore
import CrucibleDesign
import UIKit

/// One tour step as a read-only line: its symbol in a well, its name and what it shows. The intro uses it for "things to try".
final class DemoStepRowView: UIView {
    init(step: DemoTourStep) {
        super.init(frame: .zero)

        let well = UIView()
        well.backgroundColor = Theme.Color.surfaceRaised
        well.layer.cornerRadius = 10
        well.layer.cornerCurve = .continuous
        well.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: step.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)))
        icon.tintColor = Theme.Color.accentText
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
        title.text = step.title
        title.font = Theme.Font.headline
        title.textColor = Theme.Color.label
        let detail = UILabel()
        detail.text = step.detail
        detail.font = Theme.Font.subheadline
        detail.textColor = Theme.Color.labelSecondary
        for label in [title, detail] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let text = UIStackView(arrangedSubviews: [title, detail])
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

        isAccessibilityElement = true
        accessibilityLabel = step.title
        accessibilityValue = step.detail
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
