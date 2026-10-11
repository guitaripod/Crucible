import CrucibleDesign
import UIKit

package enum StatsStyle {
    package static let accent = Theme.Color.accent
    package static let accentBright = UIColor(hex: 0xFFB340)

    package static let cardBackground = Theme.Color.surface
    package static let insetBackground = Theme.Color.surfaceRaised
    package static let trackBackground = Theme.Color.surfaceHigh
    package static let hairline = Theme.Color.separator

    package static let cornerRadius: CGFloat = Theme.Radius.m
    package static let tileCornerRadius: CGFloat = Theme.Radius.m
    package static let heroCornerRadius: CGFloat = Theme.Radius.l

    /// Six-stop heat ramp (index 0 == empty). Semantic colours so the ramp reads in both appearances.
    package static func heatColor(level: Int) -> UIColor {
        switch max(0, min(5, level)) {
        case 0: return Theme.Color.surfaceHigh
        case 1: return accent.withAlphaComponent(0.28)
        case 2: return accent.withAlphaComponent(0.46)
        case 3: return accent.withAlphaComponent(0.66)
        case 4: return accent.withAlphaComponent(0.86)
        default: return accentBright
        }
    }

    /// Distinct orange-family tints for donut slices / categorical series.
    package static func categoricalColor(_ index: Int) -> UIColor {
        let palette: [UIColor] = [
            accent,
            UIColor(red: 1.0, green: 0.72, blue: 0.20, alpha: 1.0),
            UIColor(red: 0.95, green: 0.44, blue: 0.13, alpha: 1.0),
            UIColor(red: 1.0, green: 0.85, blue: 0.35, alpha: 1.0),
            UIColor(red: 0.83, green: 0.33, blue: 0.20, alpha: 1.0),
            UIColor(red: 0.99, green: 0.58, blue: 0.36, alpha: 1.0),
            UIColor(red: 0.72, green: 0.45, blue: 0.20, alpha: 1.0),
            UIColor(red: 1.0, green: 0.67, blue: 0.50, alpha: 1.0),
        ]
        return palette[index % palette.count]
    }
}
