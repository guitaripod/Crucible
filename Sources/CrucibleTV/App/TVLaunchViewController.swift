import CrucibleDesign
import UIKit

/// Full-screen gate shown from the first frame until the main UI is fully loaded: the crystal
/// glyph and a status line while the launch pipeline runs, and the system-style error state with
/// its two actions when the server cannot be reached or the Plex sign-in expired.
final class TVLaunchViewController: UIViewController {
    var onRetry: (() -> Void)?
    var onSwitchServer: (() -> Void)?
    var onSignInAgain: (() -> Void)?
    var onSignOut: (() -> Void)?

    private static let glyphSide: CGFloat = 300

    private let glyph = CrystalGlyphView()
    private let statusRow = TVStatusRow()
    private let loadingStack = UIStackView()
    private let stateView = TVStateView()
    private var isShowingFailure = false

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        isShowingFailure ? [stateView] : []
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = CrystalGlyphView.canvas
        installBackdrop()
        installContent()
        showLoading(status: "Connecting…")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyAmbientAnimation()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        glyph.stopBreathing()
    }

    /// Updates the status line of a pipeline that is still running; a late progress report must
    /// never replace a failure that is already showing.
    func showProgress(_ status: String) {
        guard !isShowingFailure else { return }
        showLoading(status: status)
    }

    func showLoading(status: String) {
        isShowingFailure = false
        statusRow.show(status, isBusy: true)
        loadingStack.isHidden = false
        stateView.isHidden = true
        glyph.setDimmed(false)
        applyAmbientAnimation()
    }

    /// The saved Plex sign-in is no longer accepted: the way forward is to sign in again, or to
    /// sign out, not to retry.
    func showSignInExpired() {
        show(.error(
            title: "Your Plex sign-in expired",
            message: "Sign in again to keep using Crucible, or sign out to remove this account from this Apple TV.",
            retryTitle: "Sign In Again",
            retry: { [weak self] in self?.onSignInAgain?() },
            secondary: TVStateView.Action(title: "Sign Out") { [weak self] in self?.onSignOut?() }
        ))
    }

    func showFailure(title: String, message: String) {
        show(.error(
            title: title,
            message: message,
            retryTitle: "Try Again",
            retry: { [weak self] in self?.onRetry?() },
            secondary: TVStateView.Action(title: "Switch Server") { [weak self] in self?.onSwitchServer?() }
        ))
    }

    /// Flares the crystal before the cross-dissolve so the hand-off reads as ignition rather than a
    /// cut; with Reduce Motion the hand-off is immediate.
    func playSuccess(completion: @escaping () -> Void) {
        statusRow.show(nil)
        guard TVMotion.animationsEnabled else {
            completion()
            return
        }
        glyph.flare(completion: completion)
    }

    private func show(_ state: TVStateView.State) {
        isShowingFailure = true
        statusRow.show(nil)
        loadingStack.isHidden = true
        stateView.show(state)
        stateView.isHidden = false
        glyph.stopBreathing()
        view.layoutIfNeeded()
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    /// The glyph's breathing is decoration: it stays off under Reduce Motion and in UI tests, where
    /// an endless animation would keep the test runner from ever seeing the app idle.
    private func applyAmbientAnimation() {
        if TVMotion.ambientAllowed && !isShowingFailure && glyph.window != nil {
            glyph.startBreathing()
        } else {
            glyph.stopBreathing()
        }
    }

    private func installBackdrop() {
        let vignette = CAGradientLayer()
        vignette.type = .radial
        vignette.colors = [UIColor(red: 0.16, green: 0.10, blue: 0.05, alpha: 1).cgColor, CrystalGlyphView.canvas.cgColor]
        vignette.locations = [0, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.42)
        vignette.endPoint = CGPoint(x: 1.1, y: 1.1)
        let backdrop = GradientHostView(layer: vignette)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func installContent() {
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.isAccessibilityElement = true
        glyph.accessibilityLabel = "Crucible"
        glyph.accessibilityTraits = .image

        loadingStack.axis = .vertical
        loadingStack.alignment = .center
        loadingStack.spacing = Theme.Space.l
        loadingStack.addArrangedSubview(glyph)
        loadingStack.addArrangedSubview(statusRow)
        loadingStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingStack)

        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        view.addSubview(stateView)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: Self.glyphSide),
            glyph.heightAnchor.constraint(equalToConstant: Self.glyphSide),
            loadingStack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            loadingStack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            loadingStack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor),
            loadingStack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor),
            statusRow.widthAnchor.constraint(lessThanOrEqualToConstant: TVMetrics.Column.message),
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}
