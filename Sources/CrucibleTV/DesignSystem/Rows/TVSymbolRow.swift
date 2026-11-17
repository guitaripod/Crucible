import CrucibleDesign
import UIKit

/// A read-only line of a full-screen message: a tinted symbol well, a name and one or two lines about it, as the demo's things to try
/// and the welcome's lists are laid out. It never takes focus.
@MainActor
enum TVSymbolRow {
    static func make(symbol: String, title: String, detail: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.contentMode = .center
        icon.tintColor = Theme.Color.accentText
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: TVMetrics.Symbol.row, weight: .semibold)
        let well = UIView()
        well.backgroundColor = Theme.Color.accentTint
        well.layer.cornerRadius = Theme.Radius.s
        well.layer.cornerCurve = .continuous
        icon.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(icon)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = TVFont.cardTitle
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = TVFont.cardSubtitle
        detailLabel.textColor = Theme.Color.labelSecondary
        detailLabel.numberOfLines = 0
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = Theme.Space.xxs

        let row = UIStackView(arrangedSubviews: [well, text])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Theme.Space.s
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: TVMetrics.Row.iconWell),
            well.heightAnchor.constraint(equalToConstant: TVMetrics.Row.iconWell),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
        return row
    }
}
