import CrucibleCore
import UIKit

extension TVScreens {
    /// Plays an item in the system player on top of `presenter` and returns to it, with fresh
    /// watched state, when the viewer leaves. A show picked at the end of playback opens on top of it.
    static func play(_ env: TVAppEnvironment, request: TVPlaybackRequest, from presenter: UIViewController) {
        TVPlayerCoordinator.start(api: env.api, request: request.playbackRequest, from: presenter) { route, screen in
            if !TVNavigation.push(TVScreens.screen(for: route, env: env), from: screen), case .show(let key, _) = route {
                env.router.open(ratingKey: key, mediaType: "show")
            }
        }
    }
}
