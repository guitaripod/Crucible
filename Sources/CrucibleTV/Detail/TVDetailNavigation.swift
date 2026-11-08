import CrucibleCore
import UIKit

/// How the detail screens start playback.
@MainActor
enum TVDetailNavigation {
    /// Starts playback through the player seam. DEBUG builds started with `CRUCIBLE_DETAIL_SPY=1`
    /// show what would have been requested instead, so UI tests can check button wiring without a player.
    static func play(_ request: TVPlaybackRequest, env: TVAppEnvironment, from presenter: UIViewController) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CRUCIBLE_DETAIL_SPY"] == "1" {
            presentSpy(request, on: presenter)
            return
        }
        #endif
        TVScreens.play(env, request: request, from: presenter)
    }

    #if DEBUG
    private static func presentSpy(_ request: TVPlaybackRequest, on presenter: UIViewController) {
        let audio = request.selectedAudioStreamID.map(String.init) ?? "-"
        let subtitle = request.selectedSubtitleStreamID.map(String.init) ?? "-"
        let message = "resume=\(Int(request.resumeSeconds)) audio=\(audio) subtitle=\(subtitle) show=\(request.showRatingKey ?? "-") season=\(request.seasonRatingKey ?? "-")"
        presenter.presentAlert(title: "Play \(request.ratingKey)", message: message)
    }
    #endif
}

extension TVDetailViewController {
    /// Checks in to `ratingKey` on Trakt, offering to replace a check-in still running.
    func checkIn(ratingKey: String, durationSecs: Double?, replacing: Bool = false, done: @escaping @MainActor () -> Void = {}) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if TraktCheckin.isCheckedIn(to: ratingKey), !replacing {
                    try await TraktCheckin.cancel()
                    presentAlert(title: TraktCopy.checkInCancelled)
                    done()
                    return
                }
                if replacing { try await TraktCheckin.cancel() }
                switch try await TraktCheckin.checkIn(ratingKey: ratingKey, durationSecs: durationSecs, api: env.api) {
                case .checkedIn:
                    presentAlert(title: TraktCopy.checkedIn)
                    done()
                case .notMatched:
                    presentAlert(title: TraktCopy.checkIn, message: TraktCopy.checkInNotMatched)
                case .alreadyWatching(let until):
                    let time = until.map { $0.formatted(date: .omitted, time: .shortened) }
                    presentConfirmation(title: TraktCopy.checkIn, message: TraktCopy.alreadyCheckedIn(until: time), confirmTitle: TraktCopy.replaceCheckIn) { [weak self] in
                        self?.checkIn(ratingKey: ratingKey, durationSecs: durationSecs, replacing: true, done: done)
                    }
                }
            } catch {
                presentAlert(title: TraktCopy.checkIn, message: error.localizedDescription)
            }
        }
    }
}
