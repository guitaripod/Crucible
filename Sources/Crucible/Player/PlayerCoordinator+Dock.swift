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

    /// The system player's full screen is going away. Swiping it down shrinks it into the bar above the tab bar and it plays on;
    /// its close button stops playback there and then, so nothing is left playing to close a second time.
    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        MainActor.assumeIsolated {
            let wasPlaying = (session.player?.rate ?? 0) > 0
            let swipedDown = coordinator.initiallyInteractive
            MidgarLog.notice("Player full screen ending swipedDown=\(swipedDown) playing=\(wasPlaying)", category: .playback)
            if !isInPiP, swipedDown {
                coordinator.notifyWhenInteractionChanges { [weak self] context in
                    guard !context.isCancelled else { return }
                    MainActor.assumeIsolated { self?.revealDock() }
                }
            } else if !isInPiP {
                session.player?.pause()
            }
            _ = coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard !context.isCancelled else { return }
                Task { @MainActor [weak self] in
                    guard let self, !self.isFinishing else { return }
                    guard !self.isInPiP else { return self.withdrawDock() }
                    if swipedDown, self.dockAfterDismissal(resuming: wasPlaying) { return }
                    await self.finishAfterDismissal()
                }
            }
        }
    }

    /// Brings the bar up, live, as soon as a swipe lets go of the full player, so the shrinking picture slides down into a bar that
    /// is already there instead of vanishing before the bar appears.
    private func revealDock() {
        guard let dock, dock.active === self, let player = session.player, !isFinishing,
              dock.tabBarController.view.window != nil else { return }
        dock.dock(self, player: player)
        MidgarLog.notice("Player dock revealed ratingKey=\(request.ratingKey)", category: .playback)
    }

    /// Takes the bar a swipe brought up back down when the player went into Picture in Picture instead of docking.
    private func withdrawDock() {
        guard !isDocked else { return }
        dock?.withdraw(self)
    }

    /// Shrinks the player into the bar above the tab bar after its full screen was swiped down, instead of ending playback. It
    /// plays on if it was playing; the system player may pause it on the way out. False when this window has no bar to dock in (a
    /// player opened outside the main app), so the caller ends playback as before.
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
