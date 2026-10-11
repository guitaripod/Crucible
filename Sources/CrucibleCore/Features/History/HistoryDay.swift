import Foundation

package struct HistoryDayGroup: Hashable, Sendable {
    package let day: Date
    package let items: [HistoryItem]
}

package enum HistoryDay {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter
    }()

    private static let dayWithYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMdy")
        return formatter
    }()

    /// The short time of day a play happened, or nil when the server sent no timestamp.
    package static func timeText(_ timestamp: Int?) -> String? {
        guard let timestamp else { return nil }
        return timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    /// The start of the calendar day a play belongs to; plays without a timestamp land on `.distantPast`.
    package static func start(for timestamp: Int?, calendar: Calendar) -> Date {
        guard let timestamp else { return .distantPast }
        return calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    /// Groups items by day in the order the days first appear. The server already sends newest first, so
    /// nothing is sorted here.
    package static func groups(of items: [HistoryItem], calendar: Calendar) -> [HistoryDayGroup] {
        var order = [Date]()
        var grouped = [Date: [HistoryItem]]()
        for item in items {
            let day = start(for: item.viewedAt, calendar: calendar)
            if grouped[day] == nil { order.append(day) }
            grouped[day, default: []].append(item)
        }
        return order.map { HistoryDayGroup(day: $0, items: grouped[$0] ?? []) }
    }

    /// "Today", "Yesterday", "Earlier" for the undated bucket, otherwise the weekday and date, with the
    /// year only when it is not the current one.
    package static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        if day == .distantPast { return "Earlier" }
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.isDate(day, equalTo: now, toGranularity: .year)
        return (sameYear ? dayFormatter : dayWithYearFormatter).string(from: day)
    }
}
