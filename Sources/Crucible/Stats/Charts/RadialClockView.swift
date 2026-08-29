import UIKit

/// A 24-spoke polar histogram rendered as a clock face: each hour is a tapered radial bar
/// growing from an inner hub ring, its length scaled by that hour's share of the busiest hour.
/// Hour 0 (midnight) sits at 12 o'clock and hours increase clockwise. Feed data via `setHours(_:)`.
final class RadialClockView: UIView {
    private let hourCount = 24
    private let innerRadiusRatio: CGFloat = 0.32
    private let outerRadiusRatio: CGFloat = 0.95
    private let inset: CGFloat = 6
    private let animationDuration: CFTimeInterval = 0.55

    private var counts = [Int](repeating: 0, count: 24)
    private var maxCount = 0
    private var animationProgress: CGFloat = 1

    private var displayLink: CADisplayLink?
    private var animationStart: CFTimeInterval = 0
    private var pendingGrow = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: RadialClockView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: 200, height: 200) }

    /// Supplies 24 hourly play counts (index 0 == midnight at 12 o'clock, increasing clockwise)
    /// and, unless Reduce Motion is on, animates the bars growing outward.
    func setHours(_ counts: [Int]) {
        var normalized = [Int](repeating: 0, count: hourCount)
        for i in 0..<min(hourCount, counts.count) {
            normalized[i] = max(0, counts[i])
        }
        self.counts = normalized
        maxCount = normalized.max() ?? 0

        if UIAccessibility.isReduceMotionEnabled || maxCount == 0 {
            displayLink?.invalidate()
            displayLink = nil
            pendingGrow = false
            animationProgress = 1
            setNeedsDisplay()
        } else if window != nil {
            startGrowAnimation()
        } else {
            pendingGrow = true
            animationProgress = 0
            setNeedsDisplay()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else if pendingGrow {
            pendingGrow = false
            startGrowAnimation()
        }
    }

    private func startGrowAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        animationProgress = 0
        animationStart = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepAnimation(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsDisplay()
    }

    @objc private func stepAnimation(_ link: CADisplayLink) {
        let elapsed = CACurrentMediaTime() - animationStart
        let t = min(1, max(0, elapsed / animationDuration))
        animationProgress = CGFloat(1 - pow(1 - t, 3))
        setNeedsDisplay()
        if t >= 1 {
            link.invalidate()
            displayLink = nil
            animationProgress = 1
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let w = bounds.width
        let h = bounds.height
        guard w > 1, h > 1 else { return }
        let center = CGPoint(x: w / 2, y: h / 2)
        let radius = min(w, h) / 2 - inset
        guard radius > 0 else { return }
        let innerR = radius * innerRadiusRatio
        let outerR = radius * outerRadiusRatio
        guard outerR > innerR else { return }

        drawGuides(ctx, center: center, innerR: innerR, outerR: outerR, radius: radius)
        guard maxCount > 0 else { return }
        drawBars(ctx, center: center, innerR: innerR, outerR: outerR, radius: radius)
    }

    private func drawGuides(_ ctx: CGContext, center: CGPoint, innerR: CGFloat, outerR: CGFloat, radius: CGFloat) {
        let step = CGFloat.pi * 2 / CGFloat(hourCount)
        let dark = traitCollection.userInterfaceStyle == .dark

        ctx.setFillColor(StatsStyle.cardBackground.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2))

        ctx.setLineWidth(1)
        ctx.setStrokeColor(UIColor.label.withAlphaComponent(dark ? 0.16 : 0.14).cgColor)
        ctx.strokeEllipse(in: CGRect(x: center.x - innerR, y: center.y - innerR, width: innerR * 2, height: innerR * 2))

        ctx.setStrokeColor(UIColor.label.withAlphaComponent(dark ? 0.06 : 0.05).cgColor)
        ctx.strokeEllipse(in: CGRect(x: center.x - outerR, y: center.y - outerR, width: outerR * 2, height: outerR * 2))

        ctx.setLineCap(.round)
        for i in 0..<hourCount {
            let angle = CGFloat(i) * step
            let cardinal = i % 6 == 0
            let length = cardinal ? radius * 0.055 : radius * 0.03
            let outerEnd = pointOnCircle(center: center, radius: innerR - radius * 0.015, angle: angle)
            let innerEnd = pointOnCircle(center: center, radius: innerR - radius * 0.015 - length, angle: angle)
            let color = cardinal ? StatsStyle.accent.withAlphaComponent(0.55) : UIColor.label.withAlphaComponent(0.22)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(cardinal ? 1.5 : 1)
            ctx.beginPath()
            ctx.move(to: outerEnd)
            ctx.addLine(to: innerEnd)
            ctx.strokePath()
        }

        let dotR = max(1.5, radius * 0.012)
        ctx.setFillColor(StatsStyle.accent.withAlphaComponent(0.7).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2))
    }

    private func drawBars(_ ctx: CGContext, center: CGPoint, innerR: CGFloat, outerR: CGFloat, radius: CGFloat) {
        let span = outerR - innerR
        guard span > 0 else { return }
        let step = CGFloat.pi * 2 / CGFloat(hourCount)
        let baseHW = max(1.5, radius * 0.026)
        let tipHW = max(1.0, radius * 0.015)
        let minStub = radius * 0.03

        for i in 0..<hourCount {
            let count = counts[i]
            guard count > 0 else { continue }
            let fraction = CGFloat(count) / CGFloat(maxCount)
            let barLength = max(minStub, span * fraction) * animationProgress
            guard barLength > 0 else { continue }
            let isPeak = count == maxCount
            let fill = isPeak
                ? StatsStyle.accentBright
                : StatsStyle.accent.withAlphaComponent(0.35 + 0.45 * fraction)

            let angle = CGFloat(i) * step
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: angle)
            if isPeak {
                ctx.setShadow(offset: .zero, blur: radius * 0.04, color: StatsStyle.accentBright.withAlphaComponent(0.7).cgColor)
            }
            fill.setFill()
            barPath(innerR: innerR, outerR: innerR + barLength, baseHW: baseHW, tipHW: tipHW).fill()
            ctx.restoreGState()
        }
    }

    /// Builds a tapered, round-capped bar in a spoke-local frame where outward points toward -y.
    private func barPath(innerR: CGFloat, outerR: CGFloat, baseHW: CGFloat, tipHW: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: baseHW, y: -innerR))
        path.addLine(to: CGPoint(x: tipHW, y: -outerR))
        path.addArc(withCenter: CGPoint(x: 0, y: -outerR), radius: tipHW, startAngle: 0, endAngle: .pi, clockwise: false)
        path.addLine(to: CGPoint(x: -baseHW, y: -innerR))
        path.addArc(withCenter: CGPoint(x: 0, y: -innerR), radius: baseHW, startAngle: .pi, endAngle: 0, clockwise: false)
        path.close()
        return path
    }

    private func pointOnCircle(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
    }
}
