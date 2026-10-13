import CrucibleCore
import CrucibleDesign
import UIKit

/// The first screen of a new install: the crystal, the name, one line and the way in. Sign in with Plex is the main button; when
/// the build carries the demo, "Try the demo" sits below it with a line saying what it is.
final class TVWelcomeViewController: TVOnboardingViewController {
    private static let glyphSide: CGFloat = 280

    private let glyph = CrystalGlyphView()
    private lazy var signInButton = TVButton.make(.primary, title: "Sign in with Plex") { [weak self] in
        guard let self else { return }
        flow.beginSignIn(from: self)
    }
    private lazy var demoButton = makeDemoButton()
    private var isEnteringDemo = false

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [signInButton] }

    override func viewDidLoad() {
        super.viewDidLoad()
        installContent()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if allowsAmbientMotion { glyph.startBreathing() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        glyph.stopBreathing()
    }

    /// Only the sign-in route offers the demo, and only on a build that carries it.
    private var offersDemo: Bool {
        flow.mode == .signIn && DemoMode.shared.isAvailable
    }

    private func makeDemoButton() -> UIButton {
        let button = TVButton.make(.glass, title: DemoCopy.welcomeButton) { [weak self] in self?.startDemo() }
        button.accessibilityIdentifier = "onboarding.demo"
        return button
    }

    private func makeDemoCaption() -> UIView {
        let caption = UILabel()
        caption.text = DemoCopy.welcomeCaption
        caption.font = TVFont.cardSubtitle
        caption.textColor = Theme.Color.labelSecondary
        caption.textAlignment = .center
        caption.numberOfLines = 2
        let panel = TVReadOnlyPanel(wrapping: caption) { DemoCopy.welcomeCaption }
        panel.accessibilityIdentifier = "onboarding.demoCaption"
        return panel
    }

    /// Starts the demo library and signs in to it, with the button showing progress; a second press while it starts does nothing. When
    /// the library cannot start nothing has changed, and an alert says so.
    private func startDemo() {
        guard !isEnteringDemo else { return }
        setEnteringDemo(true)
        Task { @MainActor [weak self] in
            do {
                try await DemoMode.shared.enter()
                guard let connection = ServerBootstrap.connection() else { throw DemoError.unavailable }
                TVDemoState.markIntroPending()
                self?.flow.didConnect(connection)
            } catch {
                AppLogger.error("The demo could not start: \(String(describing: error))", .lifecycle)
                self?.setEnteringDemo(false)
                self?.presentAlert(
                    title: "Couldn\u{2019}t Start the Demo",
                    message: "The demo library could not start on this Apple TV. Try again, or sign in with Plex."
                )
            }
        }
    }

    private func setEnteringDemo(_ entering: Bool) {
        isEnteringDemo = entering
        demoButton.configuration?.title = entering ? "Starting the demo\u{2026}" : DemoCopy.welcomeButton
        demoButton.configuration?.showsActivityIndicator = entering
        demoButton.accessibilityLabel = entering ? "Starting the demo" : DemoCopy.welcomeButton
        demoButton.accessibilityTraits = entering ? [.button, .notEnabled] : .button
    }

    private func installContent() {
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "Crucible"
        title.font = Theme.Font.largeTitle
        title.textColor = Theme.Color.label
        title.textAlignment = .center
        title.accessibilityTraits = .header

        let tagline = UILabel()
        tagline.text = "Your Plex library, beautifully on Apple TV."
        tagline.font = Theme.Font.callout
        tagline.textColor = Theme.Color.labelSecondary
        tagline.textAlignment = .center
        tagline.numberOfLines = 2

        signInButton.accessibilityIdentifier = "onboarding.signIn"

        var views: [UIView] = [glyph, title, tagline, signInButton]
        if offersDemo { views += [demoButton, makeDemoCaption()] }
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Space.s
        stack.setCustomSpacing(Theme.Space.m, after: glyph)
        stack.setCustomSpacing(Theme.Space.xl, after: tagline)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: Self.glyphSide),
            glyph.heightAnchor.constraint(equalToConstant: Self.glyphSide),
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor),
        ])
    }
}
