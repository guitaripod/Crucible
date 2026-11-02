import Foundation

/// The words of the Up Next card, written once so the visible line, the spoken label and the
/// announcement stay in step.
package enum UpNextText {
    /// "S02E06 · Playing in 7 s" while counting down, "S02E06 · Next episode" otherwise.
    package static func secondary(code: String?, remaining: Int, counting: Bool) -> String {
        [code, counting ? String(localized: "Playing in \(remaining) s") : String(localized: "Next episode")].compactMap { $0 }.joined(separator: " · ")
    }

    /// The same line for VoiceOver, with the unit spelled out.
    package static func spokenSecondary(code: String?, remaining: Int, counting: Bool) -> String {
        [code, counting ? (remaining == 1 ? String(localized: "Playing in 1 second") : String(localized: "Playing in \(remaining) seconds")) : String(localized: "Next episode")]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The eyebrow over the episode title: "UP NEXT", or the question once a run of episodes has played
    /// with nobody at the remote.
    package static func eyebrow(asksStillWatching: Bool) -> String {
        asksStillWatching ? String(localized: "STILL WATCHING?") : String(localized: "UP NEXT")
    }

    /// The card's main button.
    package static func playTitle(asksStillWatching: Bool) -> String {
        asksStillWatching ? String(localized: "Keep Watching") : String(localized: "Play Now")
    }

    /// The card's second button: it lets the credits play on while they still are, and closes the player
    /// once the item has ended.
    package static func leaveTitle(keepsCreditsPlaying: Bool) -> String {
        keepsCreditsPlaying ? String(localized: "Watch Credits") : String(localized: "Close")
    }

    /// What the second button does, for VoiceOver.
    package static func leaveHint(keepsCreditsPlaying: Bool) -> String {
        keepsCreditsPlaying ? String(localized: "Closes this card and keeps the credits playing") : String(localized: "Ends playback")
    }

    /// What VoiceOver is told when the card asks before playing on.
    package static func stillWatchingAnnouncement(code: String?, title: String) -> String {
        let name = [code, title].compactMap { $0 }.joined(separator: " ")
        return String(localized: "Are you still watching? Up next: \(name)")
    }

    /// What VoiceOver is told once when the card appears.
    package static func announcement(code: String?, title: String, seconds: Int?) -> String {
        let name = [code, title].compactMap { $0 }.joined(separator: " ")
        guard let seconds else { return String(localized: "Up next: \(name)") }
        return seconds == 1 ? String(localized: "Next episode in 1 second: \(name)") : String(localized: "Next episode in \(seconds) seconds: \(name)")
    }
}

/// Keeps one Up Next lookup from cancelling another that matters more: a lookup for the end of the
/// item must run to its answer, so nothing else may replace it while it is in flight.
package struct UpNextLookupGate: Sendable {
    package private(set) var running: UpNextOffer.Reason?

    package init() {}

    /// Whether a lookup for `reason` may start now; when it may, it becomes the running one.
    package mutating func begin(_ reason: UpNextOffer.Reason) -> Bool {
        if running == .playbackEnded, reason != .playbackEnded { return false }
        running = reason
        return true
    }

    /// Marks the running lookup finished or cancelled.
    package mutating func end(_ reason: UpNextOffer.Reason) {
        if running == reason { running = nil }
    }
}
