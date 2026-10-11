import CrucibleDesign
import UIKit

/// The first screen of a new install: the crystal, the name, one line and one button.
final class TVWelcomeViewController: TVOnboardingViewController {
    private static let glyphSide: CGFloat = 280

    private let glyph = CrystalGlyphView()
    private lazy var signInButton = TVButton.make(.primary, title: "Sign in with Plex") { [weak self] in
        guard let self else { return }
        flow.beginSignIn(from: self)
    }

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

        let stack = UIStackView(arrangedSubviews: [glyph, title, tagline, signInButton])
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
