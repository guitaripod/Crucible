import UIKit

enum StatsStyle {
    static let accent = UIColor.systemOrange
    static let accentBright = UIColor(red: 1.0, green: 0.62, blue: 0.15, alpha: 1.0)

    static let cardBackground = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.06)
            : UIColor.black.withAlphaComponent(0.04)
    }

    static let cornerRadius: CGFloat = 16
    static let tileCornerRadius: CGFloat = 18

    /// Six-stop heat ramp (index 0 == empty). Semantic colours so the ramp reads in both appearances.
    static func heatColor(level: Int) -> UIColor {
        switch max(0, min(5, level)) {
        case 0:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.06)
                    : UIColor.black.withAlphaComponent(0.05)
            }
        case 1: return accent.withAlphaComponent(0.28)
        case 2: return accent.withAlphaComponent(0.45)
        case 3: return accent.withAlphaComponent(0.64)
        case 4: return accent.withAlphaComponent(0.84)
        default: return accentBright
        }
    }

    /// Distinct orange-family tints for donut slices / categorical series.
    static func categoricalColor(_ index: Int) -> UIColor {
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

    static let monthSymbols = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Weekday labels indexed by Gregorian weekday (1 == Sunday … 7 == Saturday).
    static func weekdayShort(_ gregorianWeekday: Int) -> String {
        let labels = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return labels[max(1, min(7, gregorianWeekday))]
    }

    static func isWeekend(_ gregorianWeekday: Int) -> Bool {
        gregorianWeekday == 1 || gregorianWeekday == 7
    }

    static func abbreviatedCount(_ value: Int) -> String {
        let n = Double(value)
        switch abs(value) {
        case 1_000_000...:
            return trim(n / 1_000_000) + "M"
        case 10_000...:
            return String(Int((n / 1000).rounded())) + "K"
        case 1_000...:
            return trim(n / 1000) + "K"
        default:
            return "\(value)"
        }
    }

    private static func trim(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    static func hoursLabel(_ hours: Double) -> String {
        if hours >= 1000 {
            return abbreviatedCount(Int(hours.rounded()))
        }
        if hours >= 10 {
            return "\(Int(hours.rounded()))"
        }
        return String(format: "%.1f", hours)
    }
}
