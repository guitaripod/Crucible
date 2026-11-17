import CrucibleDesign
@preconcurrency import UIKit

/// A loading state drawn by a `SkeletonCanvasView`, which `revealLoadedPage` dissolves into the content once it is in place.
protocol SkeletonConfiguration: UIContentConfiguration {}

extension UIViewController {
    /// Takes the loading state away from a screen whose first answer was just applied under it: a skeleton dissolves into the content,
    /// which already sits in its place, and any other state simply goes.
    func revealLoadedPage() {
        guard contentUnavailableConfiguration is any SkeletonConfiguration, view.window != nil else {
            contentUnavailableConfiguration = nil
            return
        }
        UIView.transition(with: view, duration: 0.35, options: [.transitionCrossDissolve, .allowUserInteraction, .curveEaseOut]) {
            self.contentUnavailableConfiguration = nil
        }
    }
}

/// A loading placeholder drawn as soft blocks under one light that sweeps across all of them together, so a page of placeholders reads
/// as a single surface warming up rather than many pieces blinking on their own. Subclasses lay their blocks out with `makeBlock` and,
/// for a full-bleed artwork area, `artworkArea`; the light follows whatever frames they end up with. Under Reduce Motion the light
/// rests and the blocks stay still.
class SkeletonCanvasView: UIView {
    private let light = CAGradientLayer()
    private let lightMask = CALayer()
    private let blockMask = CAShapeLayer()
    private let artworkMask = CAGradientLayer()
    private var blocks: [UIView] = []
    private var artwork: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.canvas
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Loading")
        accessibilityTraits = .updatesFrequently

        light.startPoint = CGPoint(x: 0, y: 0.35)
        light.endPoint = CGPoint(x: 1, y: 0.65)
        light.locations = [0, 0.5, 1]
        blockMask.fillColor = UIColor.black.cgColor
        artworkMask.colors = [UIColor.black.withAlphaComponent(0.7).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        artworkMask.locations = [0.35, 1]
        lightMask.addSublayer(artworkMask)
        lightMask.addSublayer(blockMask)
        light.mask = lightMask
        layer.addSublayer(light)
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SkeletonCanvasView, _: UITraitCollection) in
            view.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A block the light passes over, `width` and `height` points when given and otherwise sized by the caller's constraints.
    func makeBlock(width: CGFloat? = nil, height: CGFloat? = nil, cornerRadius: CGFloat) -> UIView {
        let block = UIView()
        block.backgroundColor = Theme.Color.surfaceRaised
        block.layer.cornerRadius = cornerRadius
        block.layer.cornerCurve = .continuous
        block.translatesAutoresizingMaskIntoConstraints = false
        if let height { block.heightAnchor.constraint(equalToConstant: height).isActive = true }
        if let width { block.widthAnchor.constraint(equalToConstant: width).isActive = true }
        blocks.append(block)
        return block
    }

    /// Forgets every block made so far, for a canvas that lays itself out again from scratch; the caller removes their views.
    func forgetBlocks() {
        blocks.removeAll()
    }

    /// Adds to `stack` a block whose width is a share of the stack's, for lines of text that end at different places.
    @discardableResult
    func addLine(_ share: CGFloat, to stack: UIStackView, height: CGFloat, cornerRadius: CGFloat = 5) -> UIView {
        let line = makeBlock(height: height, cornerRadius: cornerRadius)
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: share).isActive = true
        return line
    }

    /// The full-bleed place of a page's artwork: the raised surface, darkened at the top under the bars and fading into the canvas at
    /// the bottom, the way the artwork's own placeholder looks, with the light fading out as it goes down.
    func artworkArea() -> UIView {
        let area = SkeletonArtworkView()
        area.translatesAutoresizingMaskIntoConstraints = false
        artwork = area
        return area
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.forEach { $0.layoutIfNeeded() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer.sublayers?.last !== light { layer.addSublayer(light) }
        light.frame = bounds
        lightMask.frame = bounds
        blockMask.frame = bounds
        let path = UIBezierPath()
        for block in blocks where !block.isHidden {
            let rect = block.convert(block.bounds, to: self)
            path.append(UIBezierPath(roundedRect: rect, cornerRadius: block.layer.cornerRadius))
        }
        blockMask.path = path.cgPath
        artworkMask.frame = artwork.map { $0.convert($0.bounds, to: self) } ?? .zero
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        light.removeAllAnimations()
        guard window != nil else { return }
        setNeedsLayout()
        startSweeping()
    }

    private func startSweeping() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            light.isHidden = true
            return
        }
        light.isHidden = false
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.6, -0.3, 0]
        sweep.toValue = [1, 1.3, 1.6]
        sweep.duration = 1.5
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let cycle = CAAnimationGroup()
        cycle.animations = [sweep]
        cycle.duration = 2.1
        cycle.repeatCount = .infinity
        light.add(cycle, forKey: "sweep")
    }

    private func applyColors() {
        traitCollection.performAsCurrent {
            let glow = Theme.Color.surfaceHigh.cgColor
            light.colors = [Theme.Color.surfaceHigh.withAlphaComponent(0).cgColor, glow, Theme.Color.surfaceHigh.withAlphaComponent(0).cgColor]
        }
    }
}

/// The artwork's place on a skeleton: the raised surface with the scrim under the bars and the fade into the canvas that the real
/// artwork's placeholder has, so the dissolve into the page changes nothing but what has loaded.
private final class SkeletonArtworkView: UIView {
    private let topScrim = CAGradientLayer()
    private let bottomFade = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(topScrim)
        layer.addSublayer(bottomFade)
        topScrim.colors = [UIColor.black.withAlphaComponent(0.45).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SkeletonArtworkView, _: UITraitCollection) in
            view.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        topScrim.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.26)
        let fade = bounds.height * 0.74
        bottomFade.frame = CGRect(x: 0, y: bounds.height - fade, width: bounds.width, height: fade)
        CATransaction.commit()
    }

    private func applyColors() {
        backgroundColor = Theme.Color.surfaceRaised
        let canvas = Theme.Color.canvas.resolvedColor(with: traitCollection)
        bottomFade.colors = [
            canvas.withAlphaComponent(0).cgColor,
            canvas.withAlphaComponent(0.35).cgColor,
            canvas.withAlphaComponent(0.82).cgColor,
            canvas.cgColor,
        ]
        bottomFade.locations = [0, 0.4, 0.75, 1]
    }
}
