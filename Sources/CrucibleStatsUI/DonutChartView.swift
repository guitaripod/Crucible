import CrucibleDesign
import CrucibleStats
import UIKit

/// A ring/donut breakdown chart: proportional stroked arcs around a hole that holds
/// two centred labels. Slices sweep in clockwise from 12 o'clock unless Reduce Motion is on.
package final class DonutChartView: UIView {
    private static let widthFactor: CGFloat = 0.22
    private static let gapAngle: CGFloat = 2.2 * .pi / 180
    private static let sweepDuration: CFTimeInterval = 0.9
    private static let startAngle: CGFloat = -.pi / 2

    private let ringContainer = CALayer()
    private let trackLayer = CAShapeLayer()
    private var segmentLayers: [CAShapeLayer] = []

    private let metrics: StatsMetrics.Donut
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let labelStack = UIStackView()
    private var stackWidthConstraint: NSLayoutConstraint!

    private var drawSegments: [DonutSegment] = []
    private var totalValue: Double = 0
    private var pendingAnimation = false

    package init(metrics: StatsMetrics = .platform) {
        self.metrics = metrics.donut
        super.init(frame: .zero)
        backgroundColor = .clear

        layer.addSublayer(ringContainer)
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.lineCap = .round
        ringContainer.addSublayer(trackLayer)

        titleLabel.font = metrics.donut.titleFont.uiFont
        titleLabel.textColor = Theme.Color.label
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.5
        titleLabel.numberOfLines = 1

        subtitleLabel.font = metrics.donut.subtitleFont.uiFont
        subtitleLabel.textColor = Theme.Color.labelSecondary
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 2

        labelStack.axis = .vertical
        labelStack.alignment = .fill
        labelStack.spacing = metrics.donut.labelSpacing
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        labelStack.addArrangedSubview(titleLabel)
        labelStack.addArrangedSubview(subtitleLabel)
        addSubview(labelStack)

        stackWidthConstraint = labelStack.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            labelStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackWidthConstraint,
        ])

        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DonutChartView, _: UITraitCollection) in
            view.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    package override var intrinsicContentSize: CGSize {
        CGSize(width: metrics.intrinsicSide, height: metrics.intrinsicSide)
    }

    /// Replaces the ring's slices; zero-value segments are ignored and a zero total renders only
    /// the faint track. Slices animate in unless Reduce Motion is enabled.
    package func setSegments(_ segments: [DonutSegment]) {
        drawSegments = segments.filter { $0.value > 0 }
        totalValue = drawSegments.reduce(0.0) { $0 + Double($1.value) }
        rebuildSegmentLayers()
        applyColors()
        pendingAnimation = !UIAccessibility.isReduceMotionEnabled && !drawSegments.isEmpty
        setNeedsLayout()
    }

    /// Sets the two labels shown inside the ring's hole.
    package func setCenter(title: String, subtitle: String) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
    }

    package override func layoutSubviews() {
        super.layoutSubviews()
        updateGeometry()
        guard min(bounds.width, bounds.height) > 0 else { return }
        if pendingAnimation {
            pendingAnimation = false
            if totalValue > 0 { animateIn() }
        }
    }

    private func rebuildSegmentLayers() {
        for existing in segmentLayers {
            existing.removeAllAnimations()
            existing.removeFromSuperlayer()
        }
        segmentLayers.removeAll(keepingCapacity: true)
        for _ in drawSegments {
            let slice = CAShapeLayer()
            slice.fillColor = UIColor.clear.cgColor
            slice.lineCap = .butt
            slice.lineJoin = .round
            slice.strokeEnd = 1
            ringContainer.addSublayer(slice)
            segmentLayers.append(slice)
        }
    }

    private func applyColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.strokeColor = StatsStyle.heatColor(level: 0).resolvedColor(with: traitCollection).cgColor
        for (index, segment) in drawSegments.enumerated() where index < segmentLayers.count {
            let color = StatsStyle.categoricalColor(segment.colorIndex).resolvedColor(with: traitCollection)
            segmentLayers[index].strokeColor = color.cgColor
        }
        CATransaction.commit()
    }

    private func updateGeometry() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        ringContainer.frame = bounds
        let outer = side / 2 - metrics.edgePadding
        guard outer > 0 else { return }

        let radius = outer / (1 + Self.widthFactor / 2)
        let lineWidth = Self.widthFactor * radius
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        trackLayer.frame = bounds
        trackLayer.lineWidth = lineWidth
        trackLayer.path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: Self.startAngle,
            endAngle: Self.startAngle + 2 * .pi,
            clockwise: true
        ).cgPath

        if totalValue > 0 {
            let gap: CGFloat = drawSegments.count > 1 ? Self.gapAngle : 0
            var cumulative: CGFloat = 0
            for (index, segment) in drawSegments.enumerated() where index < segmentLayers.count {
                let fraction = CGFloat(Double(segment.value) / totalValue)
                let a0 = Self.startAngle + 2 * .pi * cumulative
                let a1 = Self.startAngle + 2 * .pi * (cumulative + fraction)
                let start = a0 + gap / 2
                var end = a1 - gap / 2
                if end < start { end = start }

                let slice = segmentLayers[index]
                slice.frame = bounds
                slice.lineWidth = lineWidth
                slice.path = UIBezierPath(
                    arcCenter: center,
                    radius: radius,
                    startAngle: start,
                    endAngle: end,
                    clockwise: true
                ).cgPath
                cumulative += fraction
            }
        }

        let innerRadius = max(0, radius - lineWidth / 2)
        stackWidthConstraint.constant = innerRadius * 2 * 0.82
    }

    private func animateIn() {
        guard totalValue > 0 else { return }
        let base = CACurrentMediaTime()
        var cumulative = 0.0
        for (index, segment) in drawSegments.enumerated() where index < segmentLayers.count {
            let fraction = Double(segment.value) / totalValue
            let slice = segmentLayers[index]
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = max(0.06, fraction * Self.sweepDuration)
            animation.beginTime = base + cumulative * Self.sweepDuration
            animation.fillMode = .backwards
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            slice.strokeEnd = 1
            slice.add(animation, forKey: "drawIn")
            cumulative += fraction
        }

        labelStack.alpha = 0
        UIView.animate(withDuration: 0.4, delay: Self.sweepDuration * 0.5, options: [.curveEaseOut]) {
            self.labelStack.alpha = 1
        }
    }
}
