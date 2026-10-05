@preconcurrency import UIKit

/// A placeholder block for cold-start loading: a raised-surface fill with a 1.4s linear highlight
/// sweep. With Reduce Motion the block stays static.
final class ShimmerView: UIView {
    private let highlight = CAGradientLayer()

    init(cornerRadius: CGFloat = Theme.Radius.s) {
        super.init(frame: .zero)
        backgroundColor = Theme.Color.surfaceRaised
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = false

        highlight.startPoint = CGPoint(x: 0, y: 0.5)
        highlight.endPoint = CGPoint(x: 1, y: 0.5)
        highlight.locations = [0, 0.5, 1]
        layer.addSublayer(highlight)
        applyHighlightColors()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ShimmerView, _: UITraitCollection) in
            view.applyHighlightColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyHighlightColors() {
        traitCollection.performAsCurrent {
            let edge = Theme.Color.surfaceHigh.withAlphaComponent(0).cgColor
            let center = Theme.Color.surfaceHigh.cgColor
            highlight.colors = [edge, center, edge]
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        highlight.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        highlight.removeAllAnimations()
        if window != nil {
            startAnimating()
        }
    }

    private func startAnimating() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            highlight.isHidden = true
            return
        }
        highlight.isHidden = false
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-1.0, -0.5, 0.0]
        sweep.toValue = [1.0, 1.5, 2.0]
        sweep.duration = 1.4
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.repeatCount = .infinity
        highlight.add(sweep, forKey: "shimmer")
    }
}

/// Cold-start Home placeholder mirroring the real layout: hero block, a section title and two
/// landscape cards.
struct HomeSkeletonConfiguration: UIContentConfiguration, Hashable {
    func makeContentView() -> UIView & UIContentView {
        HomeSkeletonContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> HomeSkeletonConfiguration {
        self
    }
}

final class HomeSkeletonContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration

    init(configuration: HomeSkeletonConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Loading"
        accessibilityTraits = .updatesFrequently

        let hero = ShimmerView(cornerRadius: Theme.Radius.hero)
        let title = ShimmerView(cornerRadius: Theme.Radius.xs)
        let cards = (0..<2).map { _ in ShimmerView(cornerRadius: 12) }
        let rail = UIStackView(arrangedSubviews: cards)
        rail.axis = .horizontal
        rail.spacing = Theme.Space.s

        [hero, title, rail].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        var constraints = [
            hero.topAnchor.constraint(equalTo: topAnchor),
            hero.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            hero.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            hero.heightAnchor.constraint(equalToConstant: 240),
            title.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: Theme.Space.l),
            title.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            title.widthAnchor.constraint(equalToConstant: 170),
            title.heightAnchor.constraint(equalToConstant: 20),
            rail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Theme.Space.s),
            rail.leadingAnchor.constraint(equalTo: hero.leadingAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        for card in cards {
            constraints.append(card.widthAnchor.constraint(equalToConstant: Theme.Size.landscapeCardWidth))
            constraints.append(card.heightAnchor.constraint(equalToConstant: Theme.Size.landscapeCardHeight))
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
