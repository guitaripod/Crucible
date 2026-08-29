import UIKit

/// A filled area/line chart with a gradient wash under a smoothed curve.
///
/// Renders in two modes: a compact axis-less sparkline (default) or a fuller
/// chart (`showsAxes == true`) that adds a baseline, a highlighted peak dot and
/// an optional annotation. Feed it via `setValues(_:animated:)`.
final class TrendAreaView: UIView {
    /// When `true`, draws a baseline and a highlighted dot + annotation at the peak.
    var showsAxes: Bool = false {
        didSet {
            guard showsAxes != oldValue else { return }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    /// Stroke colour of the curve and hue of the gradient fill.
    var lineColor: UIColor = StatsStyle.accent {
        didSet {
            applyColors()
            setNeedsLayout()
        }
    }

    /// Text shown near the peak dot; only rendered when `showsAxes` is on and data exists.
    var peakAnnotation: String? {
        didSet {
            peakLabel.text = peakAnnotation
            setNeedsLayout()
        }
    }

    private var values: [Double] = []
    private var pendingAnimate = false

    private let fillGradientLayer = CAGradientLayer()
    private let fillMaskLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()
    private let peakLabel = UILabel()

    private let lineWidth: CGFloat = 2
    private let dotRadius: CGFloat = 4
    private let lineDrawDuration: CFTimeInterval = 0.9

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw

        fillGradientLayer.startPoint = CGPoint(x: 0.5, y: 0)
        fillGradientLayer.endPoint = CGPoint(x: 0.5, y: 1)
        fillGradientLayer.mask = fillMaskLayer
        fillMaskLayer.fillColor = UIColor.black.cgColor
        layer.addSublayer(fillGradientLayer)

        lineLayer.fillColor = UIColor.clear.cgColor
        lineLayer.lineWidth = lineWidth
        lineLayer.lineJoin = .round
        lineLayer.lineCap = .round
        lineLayer.strokeEnd = 1
        layer.addSublayer(lineLayer)

        dotLayer.lineWidth = 1.5
        dotLayer.shadowOpacity = 0.5
        dotLayer.shadowRadius = 3
        dotLayer.shadowOffset = CGSize(width: 0, height: 1)
        dotLayer.isHidden = true
        layer.addSublayer(dotLayer)

        peakLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        peakLabel.textColor = .label
        peakLabel.textAlignment = .center
        peakLabel.isHidden = true
        addSubview(peakLabel)

        applyColors()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TrendAreaView, _: UITraitCollection) in
            view.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    convenience init() { self.init(frame: .zero) }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: showsAxes ? 160 : 44)
    }

    /// Replaces the plotted series, animating the stroke and fill in unless Reduce Motion is on.
    func setValues(_ values: [Double], animated: Bool) {
        self.values = values
        pendingAnimate = animated
        setNeedsLayout()
        setNeedsDisplay()
    }

    private func applyColors() {
        lineLayer.strokeColor = lineColor.cgColor
        fillGradientLayer.colors = [
            lineColor.withAlphaComponent(0.35).cgColor,
            lineColor.withAlphaComponent(0.0).cgColor,
        ]
        dotLayer.fillColor = lineColor.cgColor
        dotLayer.strokeColor = UIColor.systemBackground.cgColor
        dotLayer.shadowColor = lineColor.cgColor
        setNeedsDisplay()
    }

    private func plotRect() -> CGRect {
        let hInset: CGFloat = showsAxes ? 6 : lineWidth
        let topInset: CGFloat = showsAxes ? 14 : lineWidth
        let bottomInset: CGFloat = showsAxes ? 8 : lineWidth
        let w = max(0, bounds.width - hInset * 2)
        let h = max(0, bounds.height - topInset - bottomInset)
        return CGRect(x: hInset, y: topInset, width: w, height: h)
    }

    private func makePoints(in rect: CGRect) -> (line: [CGPoint], peak: CGPoint)? {
        guard !values.isEmpty, rect.width > 0 else { return nil }
        let maxValue = values.max() ?? 0

        func y(for value: Double) -> CGFloat {
            guard maxValue > 0 else { return rect.maxY }
            let norm = min(1, max(0, value / maxValue))
            return rect.maxY - rect.height * CGFloat(norm)
        }

        if values.count == 1 {
            let yy = y(for: values[0])
            let line = [CGPoint(x: rect.minX, y: yy), CGPoint(x: rect.maxX, y: yy)]
            return (line, CGPoint(x: rect.midX, y: yy))
        }

        let step = rect.width / CGFloat(values.count - 1)
        var line: [CGPoint] = []
        line.reserveCapacity(values.count)
        for (i, v) in values.enumerated() {
            line.append(CGPoint(x: rect.minX + step * CGFloat(i), y: y(for: v)))
        }
        let peakIndex = values.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        return (line, line[peakIndex])
    }

    private func smoothPath(through points: [CGPoint], clampY: ClosedRange<CGFloat>) -> UIBezierPath {
        let path = UIBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count >= 3 else {
            for p in points.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 0 ..< (points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6.0,
                y: min(clampY.upperBound, max(clampY.lowerBound, p1.y + (p2.y - p0.y) / 6.0))
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6.0,
                y: min(clampY.upperBound, max(clampY.lowerBound, p2.y - (p3.y - p1.y) / 6.0))
            )
            path.addCurve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        return path
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
        for sublayer in [fillGradientLayer, fillMaskLayer, lineLayer, dotLayer] {
            sublayer.contentsScale = scale
        }

        let rect = plotRect()
        guard let geometry = makePoints(in: rect) else {
            clearContent()
            pendingAnimate = false
            return
        }

        let animate = pendingAnimate && !UIAccessibility.isReduceMotionEnabled
        pendingAnimate = false

        let linePath = smoothPath(through: geometry.line, clampY: rect.minY ... rect.maxY)
        let fillPath = UIBezierPath(cgPath: linePath.cgPath)
        fillPath.addLine(to: CGPoint(x: geometry.line[geometry.line.count - 1].x, y: rect.maxY))
        fillPath.addLine(to: CGPoint(x: geometry.line[0].x, y: rect.maxY))
        fillPath.close()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillGradientLayer.frame = bounds
        fillMaskLayer.frame = bounds
        lineLayer.frame = bounds
        fillMaskLayer.path = fillPath.cgPath
        lineLayer.path = linePath.cgPath
        lineLayer.strokeEnd = 1
        fillGradientLayer.opacity = 1
        layoutDot(at: geometry.peak)
        CATransaction.commit()

        layoutPeakLabel(at: geometry.peak)

        if animate {
            runEntranceAnimations()
        } else {
            lineLayer.removeAllAnimations()
            fillGradientLayer.removeAllAnimations()
            dotLayer.removeAllAnimations()
        }
    }

    private func layoutDot(at peak: CGPoint) {
        let showDot = showsAxes
        dotLayer.isHidden = !showDot
        guard showDot else { return }
        let padding: CGFloat = 4
        let side = dotRadius * 2 + padding * 2
        dotLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        dotLayer.position = peak
        let circle = CGRect(x: padding, y: padding, width: dotRadius * 2, height: dotRadius * 2)
        let ovalPath = UIBezierPath(ovalIn: circle).cgPath
        dotLayer.path = ovalPath
        dotLayer.shadowPath = ovalPath
        dotLayer.opacity = 1
    }

    private func layoutPeakLabel(at peak: CGPoint) {
        let showLabel = showsAxes && (peakAnnotation?.isEmpty == false)
        peakLabel.isHidden = !showLabel
        guard showLabel else { return }
        peakLabel.sizeToFit()
        let size = peakLabel.bounds.size
        let halfW = size.width / 2
        let minX = halfW + 2
        let maxX = max(minX, bounds.width - halfW - 2)
        let centerX = min(maxX, max(minX, peak.x))
        var centerY = peak.y - dotRadius - 4 - size.height / 2
        if centerY - size.height / 2 < 0 {
            centerY = peak.y + dotRadius + 4 + size.height / 2
        }
        peakLabel.center = CGPoint(x: centerX, y: centerY)
    }

    private func runEntranceAnimations() {
        let stroke = CABasicAnimation(keyPath: "strokeEnd")
        stroke.fromValue = 0
        stroke.toValue = 1
        stroke.duration = lineDrawDuration
        stroke.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lineLayer.add(stroke, forKey: "strokeEnd")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = lineDrawDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fillGradientLayer.add(fade, forKey: "opacity")

        if !dotLayer.isHidden {
            let begin = CACurrentMediaTime() + lineDrawDuration * 0.55
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.3
            pop.toValue = 1
            pop.duration = 0.35
            pop.beginTime = begin
            pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pop.fillMode = .backwards
            dotLayer.add(pop, forKey: "dotScale")

            let dotFade = CABasicAnimation(keyPath: "opacity")
            dotFade.fromValue = 0
            dotFade.toValue = 1
            dotFade.duration = 0.3
            dotFade.beginTime = begin
            dotFade.fillMode = .backwards
            dotLayer.add(dotFade, forKey: "dotFade")
        }

        if !peakLabel.isHidden {
            peakLabel.alpha = 0
            UIView.animate(withDuration: 0.3, delay: lineDrawDuration * 0.6, options: [.curveEaseOut]) {
                self.peakLabel.alpha = 1
            }
        }
    }

    private func clearContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lineLayer.path = nil
        fillMaskLayer.path = nil
        CATransaction.commit()
        lineLayer.removeAllAnimations()
        fillGradientLayer.removeAllAnimations()
        dotLayer.removeAllAnimations()
        dotLayer.isHidden = true
        peakLabel.isHidden = true
    }

    override func draw(_ rect: CGRect) {
        guard showsAxes, !values.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
        let plot = plotRect()
        guard plot.width > 0 else { return }
        ctx.setStrokeColor(UIColor.separator.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.strokePath()
    }
}
