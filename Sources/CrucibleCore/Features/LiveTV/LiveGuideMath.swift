import Foundation

/// The arithmetic of a TV guide: which airing is on, what comes next, where the grid starts and how wide an airing draws.
package enum LiveGuideMath {
    /// A guide column's span: half an hour, as every TV guide draws it.
    package static let slot: TimeInterval = 30 * 60

    /// The start of the half hour `date` falls in.
    package static func slotStart(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / slot).rounded(.down) * slot)
    }

    /// The window a guide shows from `date`: from the half hour it falls in, `hours` ahead.
    package static func window(from date: Date, hours: Double) -> DateInterval {
        let start = slotStart(date)
        return DateInterval(start: start, duration: hours * 3600)
    }

    /// The airing on at `date`, and the one after it.
    package static func nowAndNext(_ programs: [LiveProgram], at date: Date) -> (now: LiveProgram?, next: LiveProgram?) {
        guard let index = programs.firstIndex(where: { $0.end > date }) else { return (nil, nil) }
        let candidate = programs[index]
        if candidate.isOn(at: date) {
            return (candidate, index + 1 < programs.count ? programs[index + 1] : nil)
        }
        return (nil, candidate)
    }

    /// Airings sorted, without duplicates or overlaps (a later airing that starts inside an earlier one is trimmed to
    /// start where it ends), and only those that overlap `window`.
    package static func normalized(_ programs: [LiveProgram], in window: DateInterval? = nil) -> [LiveProgram] {
        var seen = Set<String>()
        let sorted = programs.sorted { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }.filter { seen.insert($0.id).inserted }
        var result: [LiveProgram] = []
        for program in sorted {
            if let window, program.end <= window.start || program.start >= window.end { continue }
            if let last = result.last, program.start < last.end {
                guard program.end > last.end else { continue }
                result.append(program.starting(at: last.end))
            } else {
                result.append(program)
            }
        }
        return result
    }

    /// Where an airing draws in a guide row that starts at `origin` and is `pointsPerHour` wide an hour: its x and width,
    /// clipped to the row's start.
    package static func span(of program: LiveProgram, origin: Date, pointsPerHour: Double) -> (x: Double, width: Double) {
        let start = max(program.start, origin)
        let x = start.timeIntervalSince(origin) / 3600 * pointsPerHour
        let width = program.end.timeIntervalSince(start) / 3600 * pointsPerHour
        return (x, max(width, 0))
    }

    /// Channel numbers in the order a remote counts them: 2 before 10, 5.1 before 5.2, a channel without a number last.
    package static func numberOrder(_ a: String?, _ b: String?) -> Bool {
        guard let a, !a.isEmpty else { return false }
        guard let b, !b.isEmpty else { return true }
        let left = a.split(separator: ".").map { Int($0) ?? Int.max }
        let right = b.split(separator: ".").map { Int($0) ?? Int.max }
        for (x, y) in zip(left, right) where x != y { return x < y }
        return left.count < right.count
    }

    /// The time left in an airing, as "25 min left" or "1 h 5 min left".
    package static func remaining(_ program: LiveProgram, at date: Date) -> String {
        let minutes = max(Int((program.end.timeIntervalSince(date) / 60).rounded(.up)), 0)
        if minutes < 60 { return String(localized: "\(minutes) min left", comment: "Time left in a TV airing, under an hour, e.g. 25 min left") }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return String(localized: "\(hours) h left", comment: "Time left in a TV airing, whole hours, e.g. 2 h left") }
        return String(localized: "\(hours) h \(rest) min left", comment: "Time left in a TV airing, e.g. 1 h 5 min left")
    }

    /// The airing's time span as the viewer's clock reads it: "13:00–14:30" or "1:00–2:30 PM".
    package static func timeRange(_ program: LiveProgram, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "\(formatter.string(from: program.start))–\(formatter.string(from: program.end))"
    }

    /// The label of a guide column: the half hour's start on the viewer's clock.
    package static func slotLabel(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension LiveProgram {
    /// The same airing beginning at `date` instead.
    func starting(at date: Date) -> LiveProgram {
        LiveProgram(id: id, channelID: channelID, title: title, episodeTitle: episodeTitle, summary: summary, start: date, end: end, image: image,
                    season: season, episode: episode, genres: genres, contentRating: contentRating, isNew: isNew, isLive: isLive,
                    isPremiere: isPremiere, record: record)
    }
}
