import CrucibleDesign
import UIKit

/// The canvas with a soft ember glow behind the content, shared by every onboarding screen. The
/// glow is a little weaker in Light so text keeps its contrast.
final class TVOnboardingBackdrop: UIView {
    private let glow = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = Theme.Color.canvas
        glow.type = .radial
        glow.locations = [0, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.38)
        glow.endPoint = CGPoint(x: 1.1, y: 1.05)
        layer.addSublayer(glow)
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TVOnboardingBackdrop, _: UITraitCollection) in
            view.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        CATransaction.commit()
    }

    private func applyColors() {
        let alpha: CGFloat = traitCollection.userInterfaceStyle == .dark ? 0.30 : 0.18
        let ember = UIColor(red: 1, green: 140 / 255, blue: 20 / 255, alpha: alpha)
        glow.colors = [ember.cgColor, ember.withAlphaComponent(0).cgColor]
    }
}

/// Base of the onboarding screens: the backdrop behind everything, a hidden navigation bar and
/// the system appearance.
class TVOnboardingViewController: UIViewController {
    let flow: TVOnboardingFlow

    init(flow: TVOnboardingFlow) {
        self.flow = flow
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        let backdrop = TVOnboardingBackdrop()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Whether decorative, endless animation may run.
    var allowsAmbientMotion: Bool {
        !UIAccessibility.isReduceMotionEnabled && !TVDebugSession.disablesAmbientAnimation
    }

    /// Cross-dissolves `changes` unless Reduce Motion asks for instant updates.
    func transition(_ changes: @escaping () -> Void) {
        guard !UIAccessibility.isReduceMotionEnabled, view.window != nil else {
            changes()
            return
        }
        UIView.transition(with: view, duration: TVMetrics.Duration.fade, options: [.transitionCrossDissolve, .allowUserInteraction], animations: changes)
    }
}
