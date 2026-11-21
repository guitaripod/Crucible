import CrucibleCore
import CrucibleMedia
import UIKit

/// What the Apple TV screens tell Instant Start (`PlaybackWarmUp`) about the viewer: focus came to rest on a card that plays
/// when clicked, or a title's page is open with focus on Play.
@MainActor
enum TVInstantStart {
    /// The viewer may be about to play `request`, exactly as `TVScreens.play` would start it.
    static func warm(_ env: TVAppEnvironment, request: TVPlaybackRequest, intent: PlayIntent) {
        PlaybackWarmUp.shared.warm(api: env.api, request: request.playbackRequest, intent: intent, installsRemoteCommands: false)
    }

    /// The viewer left the screen, or the card, that spoke for `ratingKey`.
    static func cool(_ ratingKey: String?) {
        guard let ratingKey else { return }
        PlaybackWarmUp.shared.cool(ratingKey: ratingKey)
    }

    /// Follows focus across cards for a screen: where it stops is what the viewer is thinking of playing.
    static func focusWatch() -> RestWatch {
        RestWatch { cool($0) }
    }
}
