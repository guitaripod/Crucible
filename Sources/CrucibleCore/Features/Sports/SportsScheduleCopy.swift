import Foundation

/// The words of Library Research's schedule on every client.
extension SportsCopy {
    package static var schedule: String { String(localized: "Schedule", comment: "Library Research: the row and screen where the owner chooses the hours research may run") }
    package static var anyTime: String { String(localized: "Any time", comment: "Library Research schedule: research may run at every hour") }
    package static var custom: String { String(localized: "Custom", comment: "Library Research schedule: hours the owner chose themselves") }
    package static var allDay: String { String(localized: "All day", comment: "Library Research schedule: every hour of a day") }
    package static var noHours: String { String(localized: "No hours", comment: "Library Research schedule: a day research does not run at all") }
    package static var sameHoursEveryDay: String { String(localized: "Same hours every day", comment: "Library Research schedule button: give every day the hours of the day being edited") }
    package static var sameHoursWeekdays: String { String(localized: "Same hours Monday to Friday", comment: "Library Research schedule button: give every weekday the hours of the day being edited") }
    package static var hoursHeader: String { String(localized: "Hours", comment: "Library Research schedule: heading above the grid of the week's hours") }
    package static var readyMade: String { String(localized: "Ready-made", comment: "Library Research schedule: heading above the ready-made schedules") }

    package static func preset(_ preset: SportsSchedule.Preset) -> String {
        switch preset {
        case .anyTime: anyTime
        case .overnight: String(localized: "Overnight", comment: "Library Research ready-made schedule: every night from 1 to 7")
        case .workday: String(localized: "While I'm at work", comment: "Library Research ready-made schedule: weekdays from 9 to 5")
        case .nightsAndWeekends: String(localized: "Nights and weekends", comment: "Library Research ready-made schedule: weeknights and all weekend")
        case .weekends: String(localized: "Weekends", comment: "Library Research ready-made schedule: Saturday and Sunday")
        }
    }

    package static var scheduleExplanation: String {
        String(localized: "Research runs only in the hours you choose, so the computer's graphics are free for games, films or other models the rest of the time. A file still being researched when the hours end is researched again in the next ones.", comment: "Library Research schedule: what choosing hours does")
    }

    package static var gridHint: String {
        String(localized: "Tap an hour to choose it, or drag across hours to choose many. Tap a day or an hour's heading to choose all of it.", comment: "Library Research schedule: how to use the grid of hours")
    }

    package static var gridHintPointer: String {
        String(localized: "Click an hour to choose it, or drag across hours to choose many. Click a day or an hour's heading to choose all of it.", comment: "Library Research schedule on Linux: how to use the grid of hours with a mouse")
    }

    package static var chooseAnHour: String {
        String(localized: "Choose at least one hour, or choose Any time.", comment: "Library Research schedule: the owner cleared every hour")
    }

    package static func dayHint(_ day: String) -> String {
        String(localized: "The hours research may run on \(day).", comment: "Library Research schedule on Apple TV and Linux: explains the list of a day's hours; the argument is a weekday name")
    }

    package static func hoursAWeek(_ count: Int) -> String {
        String(localized: "Hours a week: \(count)", comment: "Library Research schedule: how many hours a week research may run, e.g. Hours a week: 42")
    }

    package static func serverClock(_ zone: String) -> String {
        String(localized: "Times are on the server's clock (\(zone)).", comment: "Library Research schedule: the hours are the Crucible Server's local time; the argument is a time zone such as Europe/Helsinki or UTC+2")
    }

    package static func choose(_ hour: String) -> String {
        String(localized: "Choose \(hour)", comment: "Library Research schedule, VoiceOver action: let research run in the hour starting at this time")
    }

    package static func leaveOut(_ hour: String) -> String {
        String(localized: "Leave out \(hour)", comment: "Library Research schedule, VoiceOver action: keep research from running in the hour starting at this time")
    }

    package static var waitingForHours: String { String(localized: "Waiting for its hours", comment: "Library Research server phase: outside the hours the owner's schedule gives it") }
    package static var lookingOutsideHours: String { String(localized: "Looking now, outside its hours", comment: "Library Research: the owner asked for a look outside the schedule's hours") }

    package static func startsAgain(_ at: Int, now: Date = Date()) -> String {
        String(localized: "Research starts again \(moment(at, now: now)).", comment: "Library Research: when the schedule's next hours begin; the argument is a day and time such as 'today at 01:00' or 'Monday at 01:00'")
    }

    package static func runsUntil(_ at: Int, now: Date = Date()) -> String {
        String(localized: "Runs until \(moment(at, now: now)).", comment: "Library Research: when the schedule's hours end; the argument is a day and time such as 'today at 07:00'")
    }

    package static var lookNowOutsideHours: String {
        String(localized: "Looks once now, outside the schedule's hours.", comment: "Library Research: what Look for new files now does outside the schedule")
    }

    /// A moment on this device's clock with its day: "today at 01:00", "tomorrow at 01:00", "Monday at 01:00".
    package static func moment(_ seconds: Int, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Formatters.displayLocale))
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "today at \(time)", comment: "Library Research schedule: a time later today, e.g. today at 01:00")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "tomorrow at \(time)", comment: "Library Research schedule: a time tomorrow, e.g. tomorrow at 01:00")
        }
        let day = date.formatted(Date.FormatStyle().weekday(.wide).locale(Formatters.displayLocale))
        return String(localized: "\(day) at \(time)", comment: "Library Research schedule: a weekday and time, e.g. Monday at 01:00")
    }

    /// A weekday's name, Monday 0: "Monday", or "Mon" short.
    package static func weekday(_ day: Int, short: Bool = false) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Formatters.displayLocale
        let symbols = short ? calendar.shortStandaloneWeekdaySymbols : calendar.standaloneWeekdaySymbols
        return symbols[(day + 1) % 7]
    }

    /// The days in the order this device's calendar starts its week with, Monday 0.
    package static var weekOrder: [Int] {
        let first = (Calendar.current.firstWeekday + 5) % 7
        return (0..<7).map { (first + $0) % 7 }
    }

    /// An hour of the day as a time, 24 for midnight at the end: "01:00" or "1 AM".
    package static func hour(_ hour: Int, short: Bool = false) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval((hour % 24) * 3600))
        var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(Formatters.displayLocale)
        style.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard short else { return date.formatted(style) }
        var compact = Date.FormatStyle().hour(.defaultDigits(amPM: .narrow)).locale(Formatters.displayLocale)
        compact.timeZone = style.timeZone
        return date.formatted(compact)
    }

    /// A run of hours: "01:00–07:00", or All day.
    package static func hours(_ range: Range<Int>) -> String {
        range == 0..<24 ? allDay : "\(hour(range.lowerBound))–\(hour(range.upperBound))"
    }

    /// A day's hours in words: "01:00–07:00, 22:00–00:00", All day or No hours.
    package static func dayHours(_ schedule: SportsSchedule, day: Int) -> String {
        let ranges = schedule.ranges(day: day)
        return ranges.isEmpty ? noHours : ranges.map(hours).joined(separator: ", ")
    }

    /// The days of a group: "Monday", "Mon–Fri", or every day.
    package static func days(_ days: ClosedRange<Int>) -> String {
        if days.count == 7 { return String(localized: "Every day", comment: "Library Research schedule: all seven days have these hours") }
        if days.count == 1 { return weekday(days.lowerBound) }
        return "\(weekday(days.lowerBound, short: true))–\(weekday(days.upperBound, short: true))"
    }

    /// The whole week in one line: "Mon–Fri 09:00–17:00 · Sat–Sun All day".
    package static func summary(_ schedule: SportsSchedule?) -> String {
        guard let schedule, !schedule.isAlways else { return anyTime }
        if schedule.isEmpty { return noHours }
        return schedule.dayGroups.map { group in
            let ranges = SportsSchedule(days: Array(repeating: group.mask, count: 7)).ranges(day: 0)
            return "\(days(group.days)) \(ranges.map(hours).joined(separator: ", "))"
        }.joined(separator: " · ")
    }

    /// What the Schedule row says: the ready-made schedule's name or the hours, and how many a week.
    package static func scheduleValue(_ schedule: SportsSchedule?) -> String {
        guard let schedule, !schedule.isAlways else { return anyTime }
        return schedule.preset.map(preset) ?? custom
    }

    /// The server's zone as people know it: Europe/Helsinki, or UTC+2 when its machine names none.
    package static func zone(_ settings: SportsSettings) -> String? {
        if let name = settings.timeZone, !name.isEmpty { return name }
        guard let offset = settings.utcOffset else { return nil }
        let hours = offset / 3600
        let minutes = abs(offset % 3600) / 60
        let sign = offset < 0 ? "-" : "+"
        return minutes == 0 ? "UTC\(sign)\(abs(hours))" : "UTC\(sign)\(abs(hours)):\(String(format: "%02d", minutes))"
    }

    /// The clock note shown under the hours, only when the server's clock differs from this device's.
    package static func clockNote(_ settings: SportsSettings) -> String? {
        guard let difference = settings.clockDifference(), difference != 0, let zone = zone(settings) else { return nil }
        return serverClock(zone)
    }
}
