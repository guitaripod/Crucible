import UIKit

package final class GradientHostView: UIView {
    private let hosted: CALayer

    package init(layer: CALayer) {
        hosted = layer
        super.init(frame: .zero)
        self.layer.addSublayer(layer)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
    }
}

/// The hexagonal crystal from the app icon: gradient body, luminous edges, X-and-spine facets and
/// a hot core, with a soft ambient glow behind it.
package final class CrystalGlyphView: UIView {
    package static let canvas = UIColor(red: 0.094, green: 0.094, blue: 0.094, alpha: 1)

    private let ambient = CAGradientLayer()
    private let body = CAGradientLayer()
    private let bodyMask = CAShapeLayer()
    private let facets = CAShapeLayer()
    private let edges = CAShapeLayer()
    private let core = CAGradientLayer()
    private let coreMask = CAShapeLayer()

    private static let outline: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.14), CGPoint(x: 0.707, y: 0.41), CGPoint(x: 0.707, y: 0.59),
        CGPoint(x: 0.5, y: 0.86), CGPoint(x: 0.293, y: 0.59), CGPoint(x: 0.293, y: 0.41),
    ]
    private static let center = CGPoint(x: 0.5, y: 0.5)

    package override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "Crucible"

        ambient.type = .radial
        ambient.colors = [
            UIColor(red: 1, green: 0.45, blue: 0.05, alpha: 0.55).cgColor,
            UIColor(red: 1, green: 0.45, blue: 0.05, alpha: 0.12).cgColor,
            UIColor.clear.cgColor,
        ]
        ambient.locations = [0, 0.45, 1]
        ambient.startPoint = CGPoint(x: 0.5, y: 0.5)
        ambient.endPoint = CGPoint(x: 1, y: 1)

        body.colors = [
            UIColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 1).cgColor,
            UIColor(red: 0.93, green: 0.45, blue: 0.10, alpha: 1).cgColor,
            UIColor(red: 0.55, green: 0.24, blue: 0.06, alpha: 1).cgColor,
        ]
        body.locations = [0, 0.5, 1]
        body.startPoint = CGPoint(x: 0.15, y: 0.1)
        body.endPoint = CGPoint(x: 0.85, y: 0.95)
        body.mask = bodyMask

        facets.fillColor = nil
        facets.strokeColor = UIColor(red: 1, green: 0.85, blue: 0.62, alpha: 0.55).cgColor
        facets.lineWidth = 1
        facets.lineCap = .round

        edges.fillColor = nil
        edges.strokeColor = UIColor(red: 1, green: 0.78, blue: 0.48, alpha: 1).cgColor
        edges.lineWidth = 2
        edges.lineJoin = .round
        edges.shadowColor = UIColor(red: 1, green: 0.6, blue: 0.2, alpha: 1).cgColor
        edges.shadowOpacity = 0.9
        edges.shadowRadius = 6
        edges.shadowOffset = .zero

        core.type = .radial
        core.colors = [
            UIColor.white.cgColor,
            UIColor(red: 1, green: 0.78, blue: 0.35, alpha: 1).cgColor,
            UIColor(red: 1, green: 0.4, blue: 0.0, alpha: 0.85).cgColor,
            UIColor(red: 1, green: 0.4, blue: 0.0, alpha: 0).cgColor,
        ]
        core.locations = [0, 0.12, 0.45, 1]
        core.startPoint = CGPoint(x: 0.5, y: 0.5)
        core.endPoint = CGPoint(x: 1, y: 1)
        core.mask = coreMask

        for sub in [ambient, body, facets, edges, core] {
            layer.addSublayer(sub)
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        let box = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let scaled = Self.outline.map { CGPoint(x: box.minX + $0.x * side, y: box.minY + $0.y * side) }
        let mid = CGPoint(x: box.minX + Self.center.x * side, y: box.minY + Self.center.y * side)

        let hex = UIBezierPath()
        hex.move(to: scaled[0])
        scaled.dropFirst().forEach { hex.addLine(to: $0) }
        hex.close()

        let ambientBox = box.insetBy(dx: -side * 0.35, dy: -side * 0.35)
        ambient.frame = ambientBox
        body.frame = box
        bodyMask.frame = body.bounds
        bodyMask.path = UIBezierPath(cgPath: hex.cgPath).offset(by: CGPoint(x: -box.minX, y: -box.minY)).cgPath
        edges.frame = bounds
        edges.path = hex.cgPath

        let lines = UIBezierPath()
        lines.move(to: scaled[0]); lines.addLine(to: scaled[3])
        lines.move(to: scaled[5]); lines.addLine(to: scaled[2])
        lines.move(to: scaled[1]); lines.addLine(to: scaled[4])
        facets.frame = bounds
        facets.path = lines.cgPath

        let coreSide = side * 0.34
        core.frame = CGRect(x: mid.x - coreSide / 2, y: mid.y - coreSide / 2, width: coreSide, height: coreSide)
        coreMask.frame = core.bounds
        coreMask.path = UIBezierPath(ovalIn: core.bounds).cgPath
        CATransaction.commit()
    }

    package func startBreathing() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.55
        pulse.toValue = 1.0
        pulse.duration = 1.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ambient.add(pulse, forKey: "breathe")

        let swell = CABasicAnimation(keyPath: "transform.scale")
        swell.fromValue = 0.92
        swell.toValue = 1.08
        swell.duration = 1.8
        swell.autoreverses = true
        swell.repeatCount = .infinity
        swell.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        core.add(swell, forKey: "swell")
    }

    package func stopBreathing() {
        ambient.removeAnimation(forKey: "breathe")
        core.removeAnimation(forKey: "swell")
    }

    package func setDimmed(_ dimmed: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        ambient.opacity = dimmed ? 0.25 : 1
        core.opacity = dimmed ? 0.5 : 1
        body.opacity = dimmed ? 0.7 : 1
        CATransaction.commit()
        if dimmed { stopBreathing() } else if window != nil { startBreathing() }
    }

    package func flare(completion: @escaping () -> Void) {
        stopBreathing()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.45)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        CATransaction.setCompletionBlock(completion)
        ambient.opacity = 1
        ambient.transform = CATransform3DMakeScale(1.35, 1.35, 1)
        core.transform = CATransform3DMakeScale(1.6, 1.6, 1)
        edges.shadowRadius = 14
        CATransaction.commit()
    }
}

private extension UIBezierPath {
    func offset(by delta: CGPoint) -> UIBezierPath {
        apply(CGAffineTransform(translationX: delta.x, y: delta.y))
        return self
    }
}
