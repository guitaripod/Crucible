import Foundation

/// Platform-neutral display data for the This Week card: total, change against last week and seven
/// daily bars normalised against the busiest day.
package struct HomeWeekCardModel: Hashable, Sendable {
    package struct Bar: Hashable, Sendable {
        package let ratio: Double
        package let isToday: Bool
        package let initial: String
    }

    /// The week runs Monday to Sunday, the same order as `HomeWeekSummary.dailySeconds`.
    package static let dayInitials = ["M", "T", "W", "T", "F", "S", "S"]

    package static let barCount = 7

    package let total: String
    package let delta: String?
    package let bars: [Bar]
    package let accessibilityLabel: String

    package init(dailySeconds: [Int], todayIndex: Int, thisWeekSeconds: Int, deltaPercent: Int?) {
        total = HomeFormat.weekTotal(thisWeekSeconds)
        delta = Self.deltaText(deltaPercent)
        let peak = max(dailySeconds.max() ?? 0, 1)
        bars = (0..<Self.barCount).map { index in
            let seconds = dailySeconds.indices.contains(index) ? dailySeconds[index] : 0
            return Bar(ratio: Double(seconds) / Double(peak), isToday: index == todayIndex, initial: Self.dayInitials[index])
        }
        accessibilityLabel = HomeFormat.joined([
            "This week",
            "\(HomeFormat.spoken(Double(thisWeekSeconds))) watched",
            delta,
        ]) ?? ""
    }

    package static func deltaText(_ percent: Int?) -> String? {
        guard let percent else { return nil }
        if percent > 0 { return "\(percent)% more than last week" }
        if percent < 0 { return "\(-percent)% less than last week" }
        return "Same as last week"
    }
}
