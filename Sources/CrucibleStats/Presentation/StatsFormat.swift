import Foundation

/// Number and label formatting shared by every statistics surface.
package enum StatsFormat {
    /// Weekday labels indexed by Gregorian weekday (1 == Sunday … 7 == Saturday); out-of-range values clamp.
    package static func weekdayShort(_ gregorianWeekday: Int) -> String {
        let labels = ["", String(localized: "Sun"), String(localized: "Mon"), String(localized: "Tue"), String(localized: "Wed"), String(localized: "Thu"), String(localized: "Fri"), String(localized: "Sat")]
        return labels[max(1, min(7, gregorianWeekday))]
    }

    /// An hour of the day (0 to 23) as the reader's clock writes it: "8 PM" with a 12-hour clock, "20" or "20 Uhr" with a 24-hour one.
    package static func hour(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j")
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(hour: hour % 24)) ?? Date()
        return formatter.string(from: date)
    }

    /// 999, 1K, 1.2K, 10K, 12K, 1M, 1.3M: at most one decimal below ten thousand, whole thousands above.
    package static func abbreviatedCount(_ value: Int) -> String {
        let n = Double(value)
        switch abs(value) {
        case 1_000_000...:
            return String(localized: "\(trim(n / 1_000_000))M")
        case 10_000...:
            return String(localized: "\(Int((n / 1000).rounded()))K")
        case 1_000...:
            return String(localized: "\(trim(n / 1000))K")
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
}
