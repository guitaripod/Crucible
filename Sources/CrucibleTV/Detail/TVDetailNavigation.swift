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
