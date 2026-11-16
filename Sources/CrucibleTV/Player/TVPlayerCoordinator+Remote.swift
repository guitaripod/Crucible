import AVKit
import CrucibleCore
import CrucibleMedia
import MidgarCore
import UIKit

extension TVPlayerCoordinator {
    /// Clicks on the left and right of the clickpad skip the distances the viewer chose. The system player's own click is
    /// a fixed ten-second skip that it shows on the scrubber before any delegate can change it, so the scrubber went ten
    /// seconds and then came back to the chosen distance. Set to skip items instead, the player hands each click to the
    /// delegate untouched and the session moves the playhead once, straight to the chosen place. Press-and-hold still
    /// rewinds and fast-forwards.
    func configureSkipping() {
        playerVC.skippingBehavior = .skipItem
        playerVC.isSkipForwardEnabled = true
        playerVC.isSkipBackwardEnabled = true
    }

    func skipToNextItem(for playerViewController: AVPlayerViewController) {
        click(.forward)
    }

    func skipToPreviousItem(for playerViewController: AVPlayerViewController) {
        click(.back)
    }

    private func click(_ direction: SkipRule.Direction) {
        guard let session, !isUpNextCardVisible else { return }
        viewerActed()
        session.skip(direction)
    }

    /// Every other move the viewer makes on the transport bar: a scrub, the end of a scan, or the ten-second steps the arrows
    /// make on a paused scrubber. Each lands where the scrubber and its preview showed it, counts as the viewer at the remote
    /// and ends an automatic skip's Undo.
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        timeToSeekAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) -> CMTime {
        viewerActed()
        session?.viewerNavigated()
        return targetTime
    }

    /// Press-and-hold on each side of the clickpad. A side left at the system's scan keeps the player's own
    /// rewind and fast forward; a side set to jump, start over or play the next episode does that instead.
    func installHoldGestures() {
        for (press, action) in [(UIPress.PressType.leftArrow, #selector(heldLeft(_:))), (.rightArrow, #selector(heldRight(_:)))] {
            let hold = UILongPressGestureRecognizer(target: self, action: action)
            hold.allowedPressTypes = [NSNumber(value: press.rawValue)]
            hold.minimumPressDuration = 0.6
            hold.cancelsTouchesInView = false
            hold.delegate = self
            playerVC.view.addGestureRecognizer(hold)
        }
    }

    @objc private func heldLeft(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        performHold(Preferences.holdLeftAction, forward: false)
    }

    @objc private func heldRight(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        performHold(Preferences.holdRightAction, forward: true)
    }

    private func performHold(_ action: HoldAction, forward: Bool) {
        guard let session, action != .scan else { return }
        MidgarLog.notice("Hold \(forward ? "right" : "left") ratingKey=\(request.ratingKey) action=\(action.title(forward: forward))", category: .playback)
        viewerActed()
        switch action {
        case .scan:
            break
        case .edge:
            if forward { session.requestUpNext() } else { session.startOver() }
        default:
            guard let seconds = action.jumpSeconds else { return }
            session.move(by: forward ? Double(seconds) : -Double(seconds), reason: "hold \(forward ? "right" : "left")")
        }
    }
}

extension TVPlayerCoordinator: UIGestureRecognizerDelegate {
    /// The hold recognizers only watch; the player's own recognizers keep working beside them.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
