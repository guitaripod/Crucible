import CrucibleCore
import UIKit

extension TVScreens {
    /// The Live TV tab: the guide of Plex's free channels, the server's tuners and the viewer's playlists.
    static func liveTV(_ env: TVAppEnvironment) -> UIViewController {
        TVLiveTVViewController(env: env)
    }
}
