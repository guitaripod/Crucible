import Foundation

/// Number and label formatting shared by every statistics surface.
package enum StatsFormat {
    /// Weekday labels indexed by Gregorian weekday (1 == Sunday … 7 == Saturday); out-of-range values clamp.
    package static func weekdayShort(_ gregorianWeekday: Int) -> String {
        let labels = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return labels[max(1, min(7, gregorianWeekday))]
    }

    /// 999, 1K, 1.2K, 10K, 12K, 1M, 1.3M: at most one decimal below ten thousand, whole thousands above.
    package static func abbreviatedCount(_ value: Int) -> String {
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
}
