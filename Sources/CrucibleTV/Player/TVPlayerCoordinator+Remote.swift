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
    /// and ends an automatic skip's Undo. The one exception is a time the paused bar kept from the item a rebuild replaced,
    /// which it commits when Play is pressed: that lands where the rebuilt stream starts instead.
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        timeToSeekAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) -> CMTime {
        viewerActed()
        session?.viewerNavigated()
        let seconds = targetTime.seconds
        guard let session, seconds.isFinite else { return targetTime }
        let target = session.seekTarget(forPlayerSeconds: seconds)
        guard target != seconds else { return targetTime }
        MidgarLog.notice("Transport bar committed a carried-over time ratingKey=\(request.ratingKey) from=\(Int(seconds)) to=\(Int(target))", category: .playback)
        return CMTime(seconds: target, preferredTimescale: 600)
    }

    /// Press-and-hold on a side of the clickpad set to jump, start over or play the next episode. That side's presses go to
    /// the hold first: the system player only sees them once the hold has failed, so a click still skips and a hold does only
    /// what the viewer chose, without the system's fast-forward running on from it. A side left at the system's scan keeps
    /// the player's own rewind and fast forward and gets no recognizer at all.
    func installHoldGestures() {
        for (press, action, selector) in [
            (UIPress.PressType.leftArrow, Preferences.holdLeftAction, #selector(heldLeft(_:))),
            (.rightArrow, Preferences.holdRightAction, #selector(heldRight(_:))),
        ] where action != .scan {
            let hold = UILongPressGestureRecognizer(target: self, action: selector)
            hold.allowedPressTypes = [NSNumber(value: press.rawValue)]
            hold.minimumPressDuration = Self.holdDuration
            hold.delaysTouchesBegan = true
            hold.delegate = self
            holdRecognizers.append(hold)
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
        session.viewerNavigated()
        switch action {
        case .scan:
            break
        case .edge:
            if forward {
                session.requestUpNext()
            } else {
                showJump(action.title(forward: false), symbol: "backward.end.fill")
                session.startOver()
            }
        default:
            guard let seconds = action.jumpSeconds else { return }
            showJump(action.title(forward: forward), symbol: forward ? "goforward" : "gobackward")
            session.move(by: forward ? Double(seconds) : -Double(seconds), reason: "hold \(forward ? "right" : "left")")
        }
    }

    private func showJump(_ text: String, symbol: String) {
        guard let overlay = playerVC.contentOverlayView else { return }
        let indicator = jumpIndicator ?? TVPlayerJumpIndicator.install(in: overlay)
        jumpIndicator = indicator
        indicator.show(text, symbol: symbol)
    }
}

extension TVPlayerCoordinator: UIGestureRecognizerDelegate {
    /// A hold only watches the arrows while they move the playhead: the Up Next card and the transport bar's buttons and menus
    /// take them for moving focus, which a hold must neither delay nor turn into a jump.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        !isUpNextCardVisible && !isFocusOnPlayerControl
    }

    /// The player's own recognizers wait for a hold to fail, so they act on a click and never on the hold. Recognizers outside
    /// the player, such as the window's for Menu and focus, are left alone.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard holdRecognizers.contains(where: { $0 === gestureRecognizer }),
              !holdRecognizers.contains(where: { $0 === otherGestureRecognizer }),
              let view = otherGestureRecognizer.view else { return false }
        return view.isDescendant(of: playerVC.view)
    }

    /// Whether focus is on one of the transport bar's buttons or in one of its menus rather than on the picture.
    private var isFocusOnPlayerControl: Bool {
        let focused = UIFocusSystem.focusSystem(for: playerVC.view)?.focusedItem
        return focused is UIControl || focused is UICollectionViewCell
    }
}
