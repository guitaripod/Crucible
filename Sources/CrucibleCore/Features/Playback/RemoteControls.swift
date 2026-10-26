import Foundation

/// How far a click of the remote skips. The system player skips its own ten seconds; Crucible moves that
/// skip to the distance the viewer chose for each direction.
package enum SkipRule {
    package enum Direction: Equatable, Sendable {
        case back
        case forward
    }

    /// The distances Settings offers, in seconds.
    package static let choices = [5, 10, 15, 30, 45, 60]
    package static let defaultSeconds = 10

    /// The skip the system player makes for one click.
    package static let systemSkip = 10.0

    /// The click a user navigation was, when it moved exactly the system's skip; nil for a scrub, a scan or
    /// anything else, which Crucible leaves alone.
    package static func click(from old: Double, to target: Double) -> Direction? {
        let delta = target - old
        guard abs(abs(delta) - systemSkip) < 0.75 else { return nil }
        return delta < 0 ? .back : .forward
    }

    /// Where a click lands on the item's timeline: `seconds` from `absolute`, never before the start and,
    /// when the duration is known, never past the end.
    package static func target(from absolute: Double, direction: Direction, seconds: Int, duration: Double) -> Double {
        let moved = absolute + (direction == .back ? -Double(seconds) : Double(seconds))
        let upper = duration > 0 ? max(0, duration - 1) : .infinity
        return min(max(0, moved), upper)
    }

    package static func label(for seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) Minute" + (seconds == 60 ? "" : "s") : "\(seconds) Seconds"
    }
}

/// What holding the left or right side of the remote's clickpad does. The system's own scan (rewind or
/// fast-forward through the picture) is the default; the others jump straight to a place.
package enum HoldAction: Int, CaseIterable, Sendable {
    case scan = 0
    case jumpOneMinute = 60
    case jumpTwoMinutes = 120
    case jumpFiveMinutes = 300
    case jumpTenMinutes = 600
    case edge = -1

    /// The jump in seconds, or nil for the scan and the edge.
    package var jumpSeconds: Int? {
        switch self {
        case .scan, .edge: return nil
        default: return rawValue
        }
    }

    /// The title for the side it is set on: holding left goes back, holding right goes ahead. The edge is
    /// the start of the item on the left and the next episode on the right.
    package func title(forward: Bool) -> String {
        switch self {
        case .scan: return forward ? "Fast Forward" : "Rewind"
        case .edge: return forward ? "Next Episode" : "Start Over"
        default:
            let minutes = rawValue / 60
            let amount = "\(minutes) Minute" + (minutes == 1 ? "" : "s")
            return forward ? "Jump Ahead \(amount)" : "Jump Back \(amount)"
        }
    }
}

extension Preferences {
    private static let skipBackKey = "skipBackSeconds"
    private static let skipForwardKey = "skipForwardSeconds"
    private static let holdLeftKey = "holdLeftAction"
    private static let holdRightKey = "holdRightAction"

    /// How far a click left skips back, from `SkipRule.choices`.
    package static var skipBackSeconds: Int {
        get { skipSeconds(forKey: skipBackKey) }
        set { setSkipSeconds(newValue, forKey: skipBackKey) }
    }

    /// How far a click right skips ahead, from `SkipRule.choices`.
    package static var skipForwardSeconds: Int {
        get { skipSeconds(forKey: skipForwardKey) }
        set { setSkipSeconds(newValue, forKey: skipForwardKey) }
    }

    /// What holding the left side of the clickpad does.
    package static var holdLeftAction: HoldAction {
        get { HoldAction(rawValue: UserDefaults.standard.integer(forKey: holdLeftKey)) ?? .scan }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: holdLeftKey) }
    }

    /// What holding the right side of the clickpad does.
    package static var holdRightAction: HoldAction {
        get { HoldAction(rawValue: UserDefaults.standard.integer(forKey: holdRightKey)) ?? .scan }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: holdRightKey) }
    }

    private static func skipSeconds(forKey key: String) -> Int {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Int, SkipRule.choices.contains(stored) else {
            return SkipRule.defaultSeconds
        }
        return stored
    }

    private static func setSkipSeconds(_ seconds: Int, forKey key: String) {
        UserDefaults.standard.set(SkipRule.choices.contains(seconds) ? seconds : SkipRule.defaultSeconds, forKey: key)
    }
}
