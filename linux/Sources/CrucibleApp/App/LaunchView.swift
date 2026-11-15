import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The gate shown from the first frame until the main UI is loaded (`TVLaunchViewController`): the breathing crystal and
/// a status line while the launch pipeline runs, and the error state with its two actions when the server cannot be
/// reached or the Plex sign-in expired. Success flares the crystal, then the gate dissolves over the app.
@MainActor
final class LaunchView: View {
    var onRetry: (() -> Void)?
    var onSwitchServer: (() -> Void)?
    var onSignInAgain: (() -> Void)?
    var onSignOut: (() -> Void)?

    private let state = StateView()
    private let glyph = CrystalGlyphView()
    private let status = StatusLineView()
    private var showsFailure = false
    private var dissolve = Animated(1)
    private var isDissolving = false

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        status.isCentered = true
        [glyph, status, state].forEach(addSubview)
        state.isHidden = true
        glyph.startBreathing()
    }

    override var preferredFocusView: View? { showsFailure ? state : nil }

    func showLoading(_ text: String) {
        guard !showsFailure || text.isEmpty == false else { return }
        showsFailure = false
        status.show(text, busy: true)
        state.isHidden = true
        glyph.isHidden = false
        status.isHidden = false
        glyph.setDimmed(false)
        setNeedsLayout()
        setNeedsDisplay()
    }

    /// A late progress report never replaces a failure already showing.
    func showProgress(_ text: String) {
        guard !showsFailure else { return }
        showLoading(text)
    }

    func showSignInExpired() {
        show(.error(
            title: String(localized: "Your Plex sign-in expired"),
            message: String(localized: "Sign in again to keep using Crucible, or sign out to remove this account from this computer."),
            retryTitle: String(localized: "Sign In Again"),
            retry: { [weak self] in self?.onSignInAgain?() },
            secondary: StateView.Action(title: String(localized: "Sign Out")) { [weak self] in self?.onSignOut?() }
        ))
    }

    func showFailure(title: String, message: String) {
        show(.error(
            title: title,
            message: message,
            retryTitle: String(localized: "Try Again"),
            retry: { [weak self] in self?.onRetry?() },
            secondary: StateView.Action(title: String(localized: "Switch Server")) { [weak self] in self?.onSwitchServer?() }
        ))
    }

    /// Flares the crystal so the hand-off reads as ignition rather than a cut, then runs `completion`; at once under Reduce
    /// Motion.
    func playSuccess(completion: @escaping () -> Void) {
        status.show(nil)
        glyph.flare(completion: completion)
    }

    /// Fades the gate out over whatever now lies under it and takes it away, or at once under Reduce Motion.
    func dissolveAway() {
        isDissolving = true
        dissolve.set(0, animation: .timed(duration: 0.4, curve: .easeInOut))
        if !dissolve.isAnimating { removeFromSuperview() }
        startAnimating()
    }

    override func hitTest(_ point: Point) -> View? {
        isDissolving ? nil : super.hitTest(point)
    }

    override func advanceAnimations(_ dt: Float) -> Bool {
        let moving = dissolve.advance(dt)
        alpha = dissolve.value
        if isDissolving, !moving { removeFromSuperview() }
        return moving
    }

    private func show(_ newState: StateView.State) {
        showsFailure = true
        status.show(nil)
        glyph.isHidden = true
        glyph.stopBreathing()
        state.isHidden = false
        state.show(newState)
        window?.focus.focus(state, animated: false)
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        let metrics = Theme.current.metrics
        state.frame = bounds
        let side = metrics.tv(300)
        let column = min(metrics.messageColumn, frame.width - metrics.sideMargin * 2)
        let statusHeight = max(status.sizeThatFits(Size(width: column, height: 0)).height, metrics.tv(36))
        let top = ((frame.height - side - metrics.tv(48) - statusHeight) / 2).rounded()
        glyph.frame = Rect(x: ((frame.width - side) / 2).rounded(), y: top, width: side, height: side)
        status.frame = Rect(x: ((frame.width - column) / 2).rounded(), y: glyph.frame.maxY + metrics.tv(48), width: column, height: statusHeight)
    }

    override func draw(_ context: inout DrawContext) {
        context.fill(bounds, color: Theme.current.palette.canvas)
        context.glow(in: bounds, radius: 0, center: Point(x: bounds.midX, y: bounds.midY), glowRadius: bounds.width * 0.5,
                     color: Color(srgbRed: 0.16, green: 0.10, blue: 0.05).withAlpha(0.9))
    }
}
