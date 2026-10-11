import CrucibleCore
import UIKit

/// A circle with the initials of a name on a gradient: the account avatar of the You tab and the
/// stand-in for a cast or crew member without a photo. Size, font and border come from the theme
/// tokens by default, so the same view reads right on the phone and on the big screen.
package final class MonogramView: UIView {
    package enum Fill: Equatable, Sendable {
        case brand
        case person
    }

    private static let brandStops: [UInt32] = [0x2B2455, 0xB0483F, 0xF2A057]
    private static let brandLocations: [NSNumber] = [0, 0.62, 1]

    private let gradient = CAGradientLayer()
    private let initialsLabel = UILabel()

    package init(
        diameter: CGFloat = Theme.Metric.monogramDiameter,
        font: UIFont = Theme.Font.monogram,
        borderWidth: CGFloat = Theme.Metric.monogramBorderWidth
    ) {
        super.init(frame: .zero)
        layer.insertSublayer(gradient, at: 0)
        layer.masksToBounds = true
        layer.borderWidth = borderWidth
        layer.borderColor = Theme.Color.artHairline.cgColor
        initialsLabel.font = font
        initialsLabel.textColor = Theme.Color.onArt
        initialsLabel.adjustsFontForContentSizeCategory = true
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(initialsLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
            initialsLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
        layer.cornerRadius = bounds.width / 2
    }

    /// The brand gradient (the account) or the stable per-name gradient of `CastAvatar` (a person).
    package func configure(name: String, fill: Fill = .brand) {
        let initials = DetailFormat.initials(name)
        initialsLabel.text = initials.isEmpty ? "?" : initials
        switch fill {
        case .brand:
            gradient.colors = Self.brandStops.map { UIColor(hex: $0).cgColor }
            gradient.locations = Self.brandLocations
            gradient.startPoint = CGPoint(x: 0.43, y: 0)
            gradient.endPoint = CGPoint(x: 0.57, y: 1)
        case .person:
            let palette = CastAvatar.gradient(for: name)
            gradient.colors = [UIColor(hex: palette.start).cgColor, UIColor(hex: palette.end).cgColor]
            gradient.locations = nil
            gradient.startPoint = CGPoint(x: 0, y: 0)
            gradient.endPoint = CGPoint(x: 1, y: 1)
        }
    }
}
