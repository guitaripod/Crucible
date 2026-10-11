import Foundation

/// The words of the Up Next card, written once so the visible line, the spoken label and the
/// announcement stay in step.
package enum UpNextText {
    /// "S02E06 · Playing in 7 s" while counting down, "S02E06 · Next episode" otherwise.
    package static func secondary(code: String?, remaining: Int, counting: Bool) -> String {
        [code, counting ? "Playing in \(remaining) s" : "Next episode"].compactMap { $0 }.joined(separator: " · ")
    }

    /// The same line for VoiceOver, with the unit spelled out.
    package static func spokenSecondary(code: String?, remaining: Int, counting: Bool) -> String {
        [code, counting ? "Playing in \(remaining) \(remaining == 1 ? "second" : "seconds")" : "Next episode"]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// What VoiceOver is told once when the card appears.
    package static func announcement(code: String?, title: String, seconds: Int?) -> String {
        let name = [code, title].compactMap { $0 }.joined(separator: " ")
        guard let seconds else { return "Up next: \(name)" }
        return "Next episode in \(seconds) \(seconds == 1 ? "second" : "seconds"): \(name)"
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

/// What to do about a transcode when the app comes back to the foreground.
package enum PlaybackLifecyclePolicy {
    /// A paused transcode is restarted at the playhead when the app returns: the server may have
    /// reaped it while the app was suspended, and a restart before the viewer presses play spares them
    /// an error. A playing stream, a direct-play file or a restart already under way need nothing.
    package static func restartsTranscodeOnForeground(isDirectPlay: Bool, isPaused: Bool, isRestarting: Bool) -> Bool {
        !isDirectPlay && isPaused && !isRestarting
    }
}
