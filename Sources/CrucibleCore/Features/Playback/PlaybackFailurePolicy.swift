import Foundation

/// Decides what a playback failure turns into: one retry through the transcoder when a direct-play
/// file will not play, otherwise a single reported failure. Later failures are ignored so a second
/// notification for the same breakage never stacks another alert.
package struct PlaybackFailurePolicy: Sendable {
    package enum Decision: Equatable, Sendable {
        case fallBackToTranscode
        case restartTranscode
        case fail
        case ignore
    }

    private var hasFallenBack = false
    private var hasFailed = false
    private var hasRestartedAfterReturn = false

    /// How long after the app came back a transcode failure still counts as the server having reaped it.
    package static let returnWindow: TimeInterval = 60

    package init() {}

    /// The app is back after being away: one transcode failure soon after is answered by restarting it.
    package mutating func noteReturn() {
        hasRestartedAfterReturn = false
    }

    package mutating func decide(wasDirectPlay: Bool, isOffline: Bool, justReturned: Bool = false) -> Decision {
        guard !hasFailed else { return .ignore }
        if justReturned, !wasDirectPlay, !isOffline, !hasRestartedAfterReturn {
            hasRestartedAfterReturn = true
            return .restartTranscode
        }
        if wasDirectPlay, !isOffline, hasFallenBack { return .ignore }
        guard wasDirectPlay, !isOffline else {
            hasFailed = true
            return .fail
        }
        hasFallenBack = true
        return .fallBackToTranscode
    }

    /// Marks the failure as reported when it was raised outside `decide`, such as a failed fallback.
    package mutating func recordFailure() {
        hasFailed = true
    }

    /// Where the transcode picks up after a direct-play failure: the playhead when playback had
    /// started, otherwise the resume position.
    package static func fallbackStart(lastAbsolute: Double, resumePosition: Double) -> Double {
        lastAbsolute > 0 ? lastAbsolute : resumePosition
    }

    /// The `domain#code: description` line used in logs and error messages.
    package static func describe(domain: String?, code: Int?, description: String?, unknown: String) -> String {
        "\(domain ?? "?")#\(code ?? 0): \(description ?? unknown)"
    }
}
