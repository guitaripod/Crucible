import Foundation

/// A kind of notification the iPhone app sends, each with its own switch in Settings › Notifications.
package enum NotificationKind: String, CaseIterable, Sendable {
    case ratingReminders
    case newEpisodes
    case watchlistArrivals
    case weeklyRecap
    case yearInReview
    case downloads

    package var title: String {
        switch self {
        case .ratingReminders: return String(localized: "Rating Reminders", comment: "Notification setting: reminders to rate what the viewer just finished")
        case .newEpisodes: return String(localized: "New Episodes", comment: "Notification setting: new episodes of shows the viewer watches")
        case .watchlistArrivals: return String(localized: "Watchlist Arrivals", comment: "Notification setting: a watchlisted title arrived on the server")
        case .weeklyRecap: return String(localized: "Weekly Recap", comment: "Notification setting: a Sunday summary of the week's watching")
        case .yearInReview: return String(localized: "Year in Review", comment: "Notification setting: the yearly Year in Review is ready")
        case .downloads: return String(localized: "Downloads", comment: "Notification setting: a download finished or failed")
        }
    }

    package var symbol: String {
        switch self {
        case .ratingReminders: return "star.bubble"
        case .newEpisodes: return "sparkles.tv"
        case .watchlistArrivals: return "bookmark"
        case .weeklyRecap: return "chart.bar.xaxis"
        case .yearInReview: return "calendar"
        case .downloads: return "arrow.down.circle"
        }
    }

    package var explanation: String {
        switch self {
        case .ratingReminders:
            return String(localized: "After you finish a movie, a season or a run of episodes, one reminder asks how it all was. Tap it to rate everything in one place.")
        case .newEpisodes:
            return String(localized: "When a new episode of a show you are watching arrives on your server.")
        case .watchlistArrivals:
            return String(localized: "When something on your Plex watchlist arrives on your server.")
        case .weeklyRecap:
            return String(localized: "Sunday evening: how much you watched this week, quietly, without a sound.")
        case .yearInReview:
            return String(localized: "On December 1, when your Year in Review is ready.")
        case .downloads:
            return String(localized: "When a download finishes or fails.")
        }
    }

    /// Kinds that Crucible finds by checking your server now and then in the background.
    package var needsBackgroundChecks: Bool {
        self == .newEpisodes || self == .watchlistArrivals
    }
}

/// When a rating reminder arrives after the viewer finished something.
package enum RatingReminderTiming: Int, CaseIterable, Sendable {
    case anHourLater = 0
    case thisEvening = 1
    case nextMorning = 2

    package var title: String {
        switch self {
        case .anHourLater: return String(localized: "An Hour Later", comment: "Rating reminder timing option")
        case .thisEvening: return String(localized: "In the Evening", comment: "Rating reminder timing option: at 7 PM")
        case .nextMorning: return String(localized: "The Next Morning", comment: "Rating reminder timing option: at 9 AM the next day")
        }
    }
}

extension Preferences {
    private static func notificationKey(_ kind: NotificationKind) -> String { "notify.\(kind.rawValue)" }
    private static let ratingReminderTimingKey = "notify.ratingReminderTiming"
    private static let quietHoursKey = "notify.quietHours"

    package static func notifies(_ kind: NotificationKind, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: notificationKey(kind)) as? Bool ?? true
    }

    package static func setNotifies(_ kind: NotificationKind, _ isOn: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isOn, forKey: notificationKey(kind))
    }

    package static var ratingReminderTiming: RatingReminderTiming {
        get { RatingReminderTiming(rawValue: UserDefaults.standard.integer(forKey: ratingReminderTimingKey)) ?? .anHourLater }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ratingReminderTimingKey) }
    }

    /// Reminders and the recap wait until morning instead of arriving between 22:00 and 9:00.
    package static var quietHours: Bool {
        get { UserDefaults.standard.object(forKey: quietHoursKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: quietHoursKey) }
    }
}

/// When a scheduled notification should arrive. Everything is local time on the device's calendar.
package enum ReminderSchedule {
    package static let quietStartHour = 22
    package static let quietEndHour = 9
    package static let eveningHour = 19
    package static let recapWeekday = 1
    package static let recapHour = 18
    package static let yearInReviewMonth = 12
    package static let yearInReviewHour = 10

    /// When to remind the viewer to rate something they finished at `finishedAt`.
    package static func ratingReminder(
        finishedAt: Date,
        timing: RatingReminderTiming,
        quietHours: Bool,
        calendar: Calendar = .current
    ) -> Date {
        let proposed: Date
        switch timing {
        case .anHourLater:
            proposed = finishedAt.addingTimeInterval(3_600)
        case .thisEvening:
            let evening = at(hour: eveningHour, on: finishedAt, calendar: calendar)
            proposed = evening > finishedAt.addingTimeInterval(15 * 60) ? evening : at(hour: eveningHour, on: day(after: finishedAt, calendar: calendar), calendar: calendar)
        case .nextMorning:
            proposed = at(hour: quietEndHour, on: day(after: finishedAt, calendar: calendar), calendar: calendar)
        }
        guard quietHours, isQuiet(proposed, calendar: calendar) else { return proposed }
        return endOfQuiet(after: proposed, calendar: calendar)
    }

    /// When the one reminder for `asks` should arrive: when the last of them would have been reminded on its own, so titles
    /// finished one after another gather into a single reminder. Nil when there is nothing to remind about.
    package static func ratingReminder(
        for asks: [RatingAsk],
        timing: RatingReminderTiming,
        quietHours: Bool,
        calendar: Calendar = .current
    ) -> Date? {
        asks.map { ratingReminder(finishedAt: $0.finishedAt, timing: timing, quietHours: quietHours, calendar: calendar) }.max()
    }

    package static func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= quietStartHour || hour < quietEndHour
    }

    /// 9:00 on the morning that ends the quiet stretch `date` falls in.
    package static func endOfQuiet(after date: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: date)
        let morningDay = hour >= quietStartHour ? day(after: date, calendar: calendar) : date
        return at(hour: quietEndHour, on: morningDay, calendar: calendar)
    }

    /// The first Sunday 18:00 strictly after `now`.
    package static func nextRecap(after now: Date, calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.weekday = recapWeekday
        components.hour = recapHour
        components.minute = 0
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? now.addingTimeInterval(7 * 86_400)
    }

    /// December 1 at 10:00 of `now`'s year, or nil once that moment has passed.
    package static func yearInReview(after now: Date, calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.year], from: now)
        components.month = yearInReviewMonth
        components.day = 1
        components.hour = yearInReviewHour
        guard let date = calendar.date(from: components), date > now else { return nil }
        return date
    }

    private static func day(after date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
    }

    private static func at(hour: Int, on date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
    }
}
