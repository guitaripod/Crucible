import Foundation

/// The hours of the week Library Research may run on the Crucible Server's clock, as `GET /sports` reports them and
/// `PUT /sports` takes them: one 24-bit mask per day, Monday first, bit `h` being the hour from `h`:00.
package struct SportsSchedule: Equatable, Hashable, Sendable {
    package static let wholeDay: UInt32 = (1 << 24) - 1

    package private(set) var days: [UInt32]

    /// A schedule from seven masks, Monday first; anything else reads as any time.
    package init(days: [UInt32]) {
        self.days = days.count == 7 ? days.map { $0 & Self.wholeDay } : Array(repeating: Self.wholeDay, count: 7)
    }

    package static let always = SportsSchedule(days: Array(repeating: wholeDay, count: 7))

    /// Monday is 0, Sunday 6.
    package func allows(day: Int, hour: Int) -> Bool {
        guard (0..<7).contains(day), (0..<24).contains(hour) else { return false }
        return days[day] & (1 << UInt32(hour)) != 0
    }

    package mutating func set(day: Int, hour: Int, to on: Bool) {
        guard (0..<7).contains(day), (0..<24).contains(hour) else { return }
        if on { days[day] |= 1 << UInt32(hour) } else { days[day] &= ~(1 << UInt32(hour)) }
    }

    package mutating func set(day: Int, to mask: UInt32) {
        guard (0..<7).contains(day) else { return }
        days[day] = mask & Self.wholeDay
    }

    /// Gives every day in `targets` the hours of `day`.
    package mutating func copy(day: Int, to targets: some Sequence<Int>) {
        guard (0..<7).contains(day) else { return }
        for target in targets { set(day: target, to: days[day]) }
    }

    /// Whether `hour` is chosen on every day, which a tap on the hour's heading turns off rather than on.
    package func allDays(hour: Int) -> Bool {
        (0..<7).allSatisfy { allows(day: $0, hour: hour) }
    }

    package mutating func set(hour: Int, to on: Bool) {
        for day in 0..<7 { set(day: day, hour: hour, to: on) }
    }

    /// How many hours a week research may run.
    package var hours: Int { days.reduce(0) { $0 + $1.nonzeroBitCount } }
    package var isAlways: Bool { days.allSatisfy { $0 == Self.wholeDay } }
    package var isEmpty: Bool { days.allSatisfy { $0 == 0 } }

    /// The runs of chosen hours in a day, as hours from the first to the one after the last: 1..<7 is 1:00 to 7:00.
    package func ranges(day: Int) -> [Range<Int>] {
        guard (0..<7).contains(day) else { return [] }
        var found: [Range<Int>] = []
        var hour = 0
        while hour < 24 {
            guard allows(day: day, hour: hour) else {
                hour += 1
                continue
            }
            let start = hour
            while hour < 24, allows(day: day, hour: hour) { hour += 1 }
            found.append(start..<hour)
        }
        return found
    }

    /// Runs of days with the same hours, in week order, leaving out days with none: Monday to Friday, then the weekend.
    package var dayGroups: [(days: ClosedRange<Int>, mask: UInt32)] {
        var groups: [(days: ClosedRange<Int>, mask: UInt32)] = []
        var day = 0
        while day < 7 {
            var last = day
            while last + 1 < 7, days[last + 1] == days[day] { last += 1 }
            if days[day] != 0 { groups.append((day...last, days[day])) }
            day = last + 1
        }
        return groups
    }

    /// The ready-made schedules, from the one that keeps the computer's graphics free the most to the least.
    package enum Preset: String, CaseIterable, Sendable {
        case anyTime
        case overnight
        case workday
        case nightsAndWeekends
        case weekends

        package var schedule: SportsSchedule {
            func hours(_ range: Range<Int>) -> UInt32 { range.reduce(0) { $0 | (1 << UInt32($1)) } }
            switch self {
            case .anyTime:
                return .always
            case .overnight:
                return SportsSchedule(days: Array(repeating: hours(1..<7), count: 7))
            case .workday:
                return SportsSchedule(days: Array(repeating: hours(9..<17), count: 5) + [0, 0])
            case .nightsAndWeekends:
                return SportsSchedule(days: Array(repeating: hours(0..<8) | hours(23..<24), count: 5) + [wholeDay, wholeDay])
            case .weekends:
                return SportsSchedule(days: [0, 0, 0, 0, 0, wholeDay, wholeDay])
            }
        }

        package var symbol: String {
            switch self {
            case .anyTime: "clock.arrow.circlepath"
            case .overnight: "moon.stars.fill"
            case .workday: "desktopcomputer"
            case .nightsAndWeekends: "moon.zzz"
            case .weekends: "leaf"
            }
        }
    }

    /// The ready-made schedule this one is, when it is one.
    package var preset: Preset? { Preset.allCases.first { $0.schedule == self } }
}

extension SportsSettings {
    /// When research may run: nil for any time.
    package var schedule: SportsSchedule? { scheduleMasks.map(SportsSchedule.init(days:)) }

    /// Whether the server runs research on a schedule; one from before schedules sends no clock.
    package var schedules: Bool { utcOffset != nil }

    /// How far the server's clock is ahead of this device's, in seconds, so the screen says when the two differ.
    package func clockDifference(from zone: TimeZone = .current, at date: Date = Date()) -> Int? {
        utcOffset.map { $0 - zone.secondsFromGMT(for: date) }
    }
}

extension SportsReport {
    /// The report as it reads once the server takes a new schedule, shown while it does.
    package func expecting(schedule: SportsSchedule?) -> SportsReport {
        var report = self
        report.settings.scheduleMasks = schedule.flatMap { $0.isAlways ? nil : $0.days }
        return report
    }
}
