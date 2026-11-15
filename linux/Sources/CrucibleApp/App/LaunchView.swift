import CrucibleCore
import CrucibleUI
import Foundation
import Kiln

/// The gate shown from the first frame until the main UI is loaded (`TVLaunchViewController`): the wordmark and a status
/// line while the launch pipeline runs, and the error state with its two actions when the server cannot be reached or
/// the Plex sign-in expired.
@MainActor
final class LaunchView: View {
    var onRetry: (() -> Void)?
    var onSwitchServer: (() -> Void)?
    var onSignInAgain: (() -> Void)?
    var onSignOut: (() -> Void)?

    private let state = StateView()
    private var status: String?
    private var showsFailure = false
    private let spinner = SpinnerView()

    override init(frame: Rect = .zero) {
        super.init(frame: frame)
        addSubview(spinner)
        addSubview(state)
        state.isHidden = true
    }

    override var preferredFocusView: View? { showsFailure ? state : nil }

    func showLoading(_ text: String) {
        guard !showsFailure || text.isEmpty == false else { return }
        showsFailure = false
        status = text
        state.isHidden = true
        spinner.isHidden = false
        spinner.startAnimating()
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

    private func show(_ newState: StateView.State) {
        showsFailure = true
        status = nil
        spinner.isHidden = true
        state.isHidden = false
        state.show(newState)
        window?.focus.focus(state, animated: false)
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        state.frame = bounds
        let size = Theme.current.metrics.tv(56)
        spinner.frame = Rect(x: (frame.width - size) / 2, y: frame.height * 0.58, width: size, height: size)
    }

    override func draw(_ context: inout DrawContext) {
        let theme = Theme.current
        let canvas = theme.palette.canvas
        context.fill(bounds, color: canvas)
        context.glow(in: bounds, radius: 0, center: Point(x: bounds.midX, y: bounds.height * 0.42), glowRadius: bounds.width * 0.5,
                     color: Color(srgbRed: 0.16, green: 0.10, blue: 0.05).withAlpha(0.9))
        guard !showsFailure, let scale = window?.scale else { return }
        let wordmark = TextLayout("Crucible", font: Font(size: theme.type.largeTitle.size * 1.2, weight: .heavy), scale: scale)
        context.text(wordmark, at: Point(x: ((bounds.width - wordmark.size.width) / 2).rounded(), y: (bounds.height * 0.42 - wordmark.size.height / 2).rounded()),
                     color: theme.palette.label)
        if let status {
            let line = TextLayout(status, font: theme.type.callout, maxWidth: bounds.width * 0.8, alignment: .center, scale: scale)
            context.text(line, at: Point(x: ((bounds.width - line.size.width) / 2).rounded(), y: spinner.frame.maxY + theme.metrics.tv(28)),
                         color: theme.palette.labelSecondary)
        }
    }
}
