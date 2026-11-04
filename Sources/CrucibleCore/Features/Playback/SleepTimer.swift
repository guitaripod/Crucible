import Foundation

/// When playback stops on its own: after a number of minutes, or at the end of what is playing instead of going on to the
/// next episode.
package enum SleepTimerChoice: Hashable, Sendable {
    case minutes(Int)
    case endOfItem

    package static let all: [SleepTimerChoice] = [.minutes(15), .minutes(30), .minutes(45), .minutes(60), .minutes(90), .endOfItem]

    package func title(isEpisode: Bool) -> String {
        switch self {
        case .minutes(let minutes):
            return String(localized: "\(minutes) Minutes", comment: "Sleep timer option, e.g. 30 Minutes")
        case .endOfItem:
            return isEpisode
                ? String(localized: "End of Episode", comment: "Sleep timer option that stops when the episode ends")
                : String(localized: "End of Movie", comment: "Sleep timer option that stops when the movie ends")
        }
    }
}

/// A running sleep timer. Minutes count on the wall clock, so time the device spent asleep or away counts too; at the end
/// the sound fades for a few seconds before playback pauses.
package struct SleepTimer: Equatable, Sendable {
    package static let fadeSeconds: TimeInterval = 8

    package let choice: SleepTimerChoice
    package let deadline: Date?

    package init(choice: SleepTimerChoice, now: Date = Date()) {
        self.choice = choice
        switch choice {
        case .minutes(let minutes): deadline = now.addingTimeInterval(TimeInterval(minutes * 60))
        case .endOfItem: deadline = nil
        }
    }

    package var stopsAtEndOfItem: Bool { choice == .endOfItem }

    package func remaining(now: Date = Date()) -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Whether the fade should begin: the last `fadeSeconds` before the deadline.
    package func startsFading(now: Date = Date()) -> Bool {
        guard let remaining = remaining(now: now) else { return false }
        return remaining <= Self.fadeSeconds
    }

    package func isDue(now: Date = Date()) -> Bool {
        remaining(now: now) == 0
    }

    /// The label of the sleep timer menu: what is set and how long is left, rounded up to a minute.
    package func menuTitle(isEpisode: Bool, now: Date = Date()) -> String {
        if let remaining = remaining(now: now) {
            let minutes = Int((remaining / 60).rounded(.up))
            return String(localized: "Sleep Timer · \(minutes) min left", comment: "Sleep timer menu title while a timer runs, e.g. Sleep Timer · 23 min left")
        }
        return String(localized: "Sleep Timer · \(choice.title(isEpisode: isEpisode))", comment: "Sleep timer menu title for a timer that stops at the end, e.g. Sleep Timer · End of Episode")
    }

    package static let title = String(localized: "Sleep Timer", comment: "Player menu that stops playback after a while")
    package static let off = String(localized: "Off", comment: "Sleep timer option that cancels the timer")
}
