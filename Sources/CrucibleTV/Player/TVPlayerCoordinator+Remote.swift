import AVKit
import CrucibleCore
import CrucibleMedia
import UIKit

extension TVPlayerCoordinator {
    /// A click on the left or right of the clickpad: the system player makes its own ten-second skip, which
    /// becomes the distance the viewer chose for that side. Scrubbing and scanning pass through untouched.
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        timeToSeekAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) -> CMTime {
        let old = oldTime.seconds
        let target = targetTime.seconds
        guard old.isFinite, target.isFinite, let session, let direction = SkipRule.click(from: old, to: target) else {
            return targetTime
        }
        viewerActed()
        return CMTime(seconds: session.click(direction, fromPlayerTime: old), preferredTimescale: 600)
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
        AppLogger.notice("Hold \(forward ? "right" : "left") ratingKey=\(request.ratingKey) action=\(action.title(forward: forward))", .playback)
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
