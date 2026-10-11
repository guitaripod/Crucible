import UIKit

/// A view backed by a `CAGradientLayer`, so a scrim resizes with its superview without layout work.
/// Colours may be dynamic; they are re-resolved whenever the interface style changes.
final class TVGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    private var colors: [UIColor] = []

    private var gradientLayer: CAGradientLayer {
        guard let gradient = layer as? CAGradientLayer else { fatalError("layerClass is CAGradientLayer") }
        return gradient
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TVGradientView, _: UITraitCollection) in
            view.resolveColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setColors(_ colors: [UIColor], locations: [Double]? = nil, from start: CGPoint, to end: CGPoint) {
        self.colors = colors
        gradientLayer.locations = locations?.map { NSNumber(value: $0) }
        gradientLayer.startPoint = start
        gradientLayer.endPoint = end
        resolveColors()
    }

    private func resolveColors() {
        gradientLayer.colors = colors.map { $0.resolvedColor(with: traitCollection).cgColor }
    }

    /// Darkens the lower part of artwork so progress bars and captions on it stay legible.
    static func bottomScrim(opacity: CGFloat = 0.6) -> TVGradientView {
        let view = TVGradientView()
        view.setColors(
            [UIColor.black.withAlphaComponent(0), UIColor.black.withAlphaComponent(opacity)],
            from: CGPoint(x: 0.5, y: 0),
            to: CGPoint(x: 0.5, y: 1)
        )
        return view
    }
}
