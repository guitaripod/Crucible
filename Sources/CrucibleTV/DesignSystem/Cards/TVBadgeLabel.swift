import CrucibleDesign
import UIKit

/// A short caption on a dark capsule for the corner of artwork (NEW, 4K, a runtime).
final class TVBadgeLabel: UIView {
    private let label = UILabel()

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false
        label.font = Theme.Font.badge
        label.textColor = Theme.Color.onArt
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metric.badgeInsetHorizontal),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Metric.badgeInsetHorizontal),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Metric.badgeInsetVertical),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Metric.badgeInsetVertical),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
