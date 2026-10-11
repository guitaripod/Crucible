import UIKit

extension TVScreens {
    /// Plays an item in the system player on top of `presenter` and returns to it, with fresh
    /// watched state, when the viewer leaves.
    static func play(_ env: TVAppEnvironment, request: TVPlaybackRequest, from presenter: UIViewController) {
        TVPlayerCoordinator.start(api: env.api, request: request.playbackRequest, from: presenter)
    }
}
