import CrucibleCore
import UIKit

/// How the detail screens leave themselves: into another detail screen or into playback.
@MainActor
enum TVDetailNavigation {
    static func viewController(for route: DetailRoute, env: TVAppEnvironment) -> UIViewController {
        switch route {
        case .show(let ratingKey, let initialSeasonKey):
            return TVScreens.showDetail(env, ratingKey: ratingKey, initialSeasonKey: initialSeasonKey)
        case .item(let ratingKey, let mediaType, _, _):
            return TVScreens.movieDetail(env, ratingKey: ratingKey, mediaType: mediaType)
        }
    }

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
        let alert = UIAlertController(title: "Play \(request.ratingKey)", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        presenter.present(alert, animated: false)
    }
    #endif
}
