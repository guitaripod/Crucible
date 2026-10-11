import Foundation

package enum HistorySummary {
    /// "14 plays this week · 7 h 20 m". The time is left out unless every play in the week has a
    /// known duration, so a partial total never reads as a real one.
    package static func text(for items: [HistoryItem], now: Date) -> String? {
        let weekAgo = Int(now.addingTimeInterval(-7 * 24 * 3600).timeIntervalSince1970)
        let week = items.filter { ($0.viewedAt ?? 0) >= weekAgo }
        guard !week.isEmpty else { return nil }
        var text = "\(week.count) \(week.count == 1 ? "play" : "plays") this week"
        let durations = week.compactMap(\.duration)
        if durations.count == week.count {
            let minutes = durations.reduce(0, +) / 60_000
            if minutes > 0 {
                text += " · " + (minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m")
            }
        }
        return text
    }
}
