import AVKit
import CrucibleCore
import CrucibleMedia
import MidgarCore
@preconcurrency import UIKit

extension PlayerCoordinator {
    /// What the bar shows for the item playing now.
    var nowPlayingMetadata: PlaybackMetadata? { request.metadata }

    /// Where the item playing now is, on the title's own clock.
    var currentPosition: Double? { session.absolutePosition }

    /// The item this player plays, so starting the same title again opens this player instead of a second one.
    var playingRatingKey: String { request.ratingKey }

    /// Shrinks the player into the bar above the tab bar after its full screen was swiped down or closed, instead of ending
    /// playback. It plays on if it was playing; the system player may pause it on the way out. False when this window has no
    /// bar to dock in (a player opened outside the main app), so the caller ends playback as before.
    func dockAfterDismissal(resuming wasPlaying: Bool) -> Bool {
        guard let dock, dock.active === self, let player = session.player, let playerVC,
              dock.tabBarController.view.window != nil else { return false }
        isDocked = true
        playerVC.player = nil
        dock.dock(self, player: player)
        if wasPlaying, player.rate == 0 { player.play() }
        MidgarLog.notice("Player docked ratingKey=\(request.ratingKey) playing=\(wasPlaying)", category: .playback)
        return true
    }

    /// Opens the docked player full screen again, where Up Next waiting for the viewer is shown.
    func expand() {
        guard isDocked, let dock, let playerVC, !isFinishing else { return }
        let host = dock.presentationHost
        guard host.view.window != nil else { return }
        isDocked = false
        dock.expanding(self)
        playerVC.player = session.player
        MidgarLog.notice("Player expanded ratingKey=\(request.ratingKey)", category: .playback)
        host.present(playerVC, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self] in
            self?.flushPendingUpNext()
        }
    }

    /// The player docked in the window of `viewController` when it plays the same title as `request`, which then opens it instead
    /// of starting the title a second time from an older position.
    static func docked(playing request: PlaybackRequest, near viewController: UIViewController) -> PlayerCoordinator? {
        guard let docked = MiniPlayerDock.of(viewController)?.docked, docked.playingRatingKey == request.ratingKey else { return nil }
        return docked
    }
}
