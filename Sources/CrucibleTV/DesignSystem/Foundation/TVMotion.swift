import UIKit

/// The one place that decides whether a tvOS animation may run.
///
/// `animationsEnabled` follows Reduce Motion. `ambientAllowed` is stricter: endless decorative
/// animations (skeleton pulses, glows, breathing) also stay off under `CRUCIBLE_UITEST=1`, because a
/// running animation keeps XCUITest from reaching idle.
@MainActor
enum TVMotion {
    static let pulseKey = "tv.pulse"

    static var animationsEnabled: Bool { !UIAccessibility.isReduceMotionEnabled }

    static var ambientAllowed: Bool { animationsEnabled && !TVDebugSession.disablesAmbientAnimation }

    /// Animates `animations`, or applies them at once (completion with `true`) when motion is off.
    static func animate(
        _ duration: TimeInterval = TVMetrics.Duration.fade,
        delay: TimeInterval = 0,
        options: UIView.AnimationOptions = [.allowUserInteraction],
        animations: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard animationsEnabled else {
            animations()
            completion?(true)
            return
        }
        UIView.animate(withDuration: duration, delay: delay, options: options, animations: animations, completion: completion)
    }

    /// Cross-dissolves `view` through `animations`, or applies them at once when motion is off.
    static func dissolve(_ view: UIView, duration: TimeInterval = TVMetrics.Duration.fade, animations: @escaping () -> Void) {
        guard animationsEnabled else {
            animations()
            return
        }
        UIView.transition(with: view, duration: duration, options: [.transitionCrossDissolve, .allowUserInteraction], animations: animations)
    }

    /// Brings `views` in one after another, each fading in from a short rise `step` after the one before, the way a full-screen
    /// message settles in. Under Reduce Motion or the UI-test switch they simply show.
    static func stagger(_ views: [UIView], rise: CGFloat = 28, step: TimeInterval = 0.07, duration: TimeInterval = 0.6) {
        guard ambientAllowed else {
            views.forEach { $0.alpha = 1; $0.transform = .identity }
            return
        }
        for (index, view) in views.enumerated() {
            view.alpha = 0
            view.transform = CGAffineTransform(translationX: 0, y: rise)
            UIView.animate(
                withDuration: duration,
                delay: Double(index) * step,
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                view.alpha = 1
                view.transform = .identity
            }
        }
    }

    /// Starts the soft 1.2s opacity pulse on `layer` when ambient animation is allowed, and stops
    /// it otherwise; calling it again restarts nothing that is already running.
    static func setPulsing(_ layer: CALayer, active: Bool) {
        guard active, ambientAllowed else {
            layer.removeAnimation(forKey: pulseKey)
            layer.opacity = 1
            return
        }
        guard layer.animation(forKey: pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.55
        pulse.duration = TVMetrics.Duration.skeletonPulse
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: pulseKey)
    }

    /// Calls `handler` whenever the Reduce Motion setting changes, until the returned token is released.
    static func observeChanges(_ handler: @escaping @MainActor () -> Void) -> TVMotionObservation {
        nonisolated(unsafe) let handler = handler
        let token = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return TVMotionObservation(token: token)
    }
}

/// Keeps a `TVMotion.observeChanges` subscription alive; releasing it unsubscribes.
final class TVMotionObservation: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

/// A view whose `pulsingLayer` pulses while it is on screen and visible. It stops when hidden or
/// removed, honours Reduce Motion and the UI-test switch, and re-evaluates when Reduce Motion changes.
class TVPulsingView: UIView {
    private var observation: TVMotionObservation?

    var pulsingLayer: CALayer { layer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        observation = TVMotion.observeChanges { [weak self] in self?.refreshPulse() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHidden: Bool {
        didSet { refreshPulse() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshPulse()
    }

    private func refreshPulse() {
        TVMotion.setPulsing(pulsingLayer, active: window != nil && !isHidden)
    }
}
