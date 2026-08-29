import UIKit

/// Seven vertical bars (Sunday…Saturday) charting play counts per weekday, with
/// rounded tops, faint backing columns, per-bar value chips, and a staggered
/// grow-from-baseline entrance. Feed it via `setValues(_:)`.
final class WeekdayColumnChartView: UIView {
    private var values: [Int] = []
    private var trackLayers: [CALayer] = []
    private var barLayers: [CALayer] = []
    private var weekdayLabels: [UILabel] = []
    private var valueLabels: [UILabel] = []
    private var pendingGrowth = false
    private var baselineY: CGFloat = 0

    private let labelRowHeight: CGFloat = 18
    private let valueRowHeight: CGFloat = 15
    private let barCornerRadius: CGFloat = 6

    private let weekdayFont = WeekdayColumnChartView.roundedFont(size: 11, weight: .medium)
    private let valueFont = WeekdayColumnChartView.roundedFont(size: 10, weight: .semibold)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityLabel = "Plays by weekday"

        for i in 0..<7 {
            let track = CALayer()
            track.anchorPoint = CGPoint(x: 0.5, y: 1)
            track.masksToBounds = true
            track.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            track.isHidden = true
            layer.addSublayer(track)
            trackLayers.append(track)

            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 1)
            bar.masksToBounds = true
            bar.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            bar.isHidden = true
            layer.addSublayer(bar)
            barLayers.append(bar)

            let weekday = UILabel()
            weekday.font = weekdayFont
            weekday.textColor = .secondaryLabel
            weekday.textAlignment = .center
            weekday.text = String(StatsStyle.weekdayShort(i + 1).prefix(1))
            addSubview(weekday)
            weekdayLabels.append(weekday)

            let value = UILabel()
            value.font = valueFont
            value.textColor = .secondaryLabel
            value.textAlignment = .center
            value.isHidden = true
            addSubview(value)
            valueLabels.append(value)
        }

        applyLayerColors()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: WeekdayColumnChartView, _: UITraitCollection) in
            view.applyLayerColors()
            view.setNeedsDisplay()
        }
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 150)
    }

    /// Supplies the seven weekday counts (index 0 = Sunday … 6 = Saturday);
    /// any other length clears the chart. Re-animates the entrance unless Reduce Motion is on.
    func setValues(_ counts: [Int]) {
        guard counts.count == 7 else {
            values = []
            pendingGrowth = false
            updateAccessibility()
            setNeedsLayout()
            setNeedsDisplay()
            return
        }
        values = counts
        pendingGrowth = !UIAccessibility.isReduceMotionEnabled
        updateAccessibility()
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayerColors()

        guard values.count == 7, bounds.width > 0, bounds.height > 0 else {
            hideAll()
            baselineY = 0
            setNeedsDisplay()
            return
        }

        let baseline = bounds.height - labelRowHeight
        let plotHeight = max(0, baseline - valueRowHeight)
        baselineY = baseline

        let slotWidth = bounds.width / 7
        let barWidth = min(34, max(6, slotWidth * 0.58))
        let corner = min(barCornerRadius, barWidth / 2)

        let maxCount = values.max() ?? 0
        let animate = pendingGrowth && !UIAccessibility.isReduceMotionEnabled
        let now = CACurrentMediaTime()

        for i in 0..<7 {
            let slotMinX = slotWidth * CGFloat(i)
            let centerX = slotMinX + slotWidth / 2
            let count = values[i]

            setGeometry(trackLayers[i], width: barWidth, height: plotHeight, centerX: centerX, baseline: baseline, corner: corner)

            var barHeight: CGFloat = 0
            if maxCount > 0 {
                barHeight = plotHeight * (CGFloat(count) / CGFloat(maxCount))
                if count > 0 { barHeight = max(barHeight, 4) }
            }
            setGeometry(barLayers[i], width: barWidth, height: barHeight, centerX: centerX, baseline: baseline, corner: corner)

            if animate && barHeight > 0 {
                addGrowth(to: barLayers[i], target: barHeight, delay: Double(i) * 0.045, at: now)
            }

            let weekday = weekdayLabels[i]
            weekday.isHidden = false
            weekday.frame = CGRect(x: slotMinX, y: baseline + 3, width: slotWidth, height: labelRowHeight - 3)

            layoutValueLabel(valueLabels[i], count: count, slotMinX: slotMinX, slotWidth: slotWidth, barTop: baseline - barHeight, animate: animate, delay: Double(i) * 0.045, at: now)
        }

        pendingGrowth = false
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard values.count == 7, baselineY > 0, let context = UIGraphicsGetCurrentContext() else { return }
        let y = baselineY.rounded() + 0.5
        context.setStrokeColor(UIColor.separator.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 0, y: y))
        context.addLine(to: CGPoint(x: bounds.width, y: y))
        context.strokePath()
    }

    private func setGeometry(_ layer: CALayer, width: CGFloat, height: CGFloat, centerX: CGFloat, baseline: CGFloat, corner: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: max(0, height))
        layer.position = CGPoint(x: centerX, y: baseline)
        layer.cornerRadius = corner
        layer.isHidden = height <= 0
        CATransaction.commit()
    }

    private func addGrowth(to layer: CALayer, target: CGFloat, delay: Double, at now: CFTimeInterval) {
        let grow = CABasicAnimation(keyPath: "bounds.size.height")
        grow.fromValue = 0
        grow.toValue = target
        grow.duration = 0.55
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        grow.beginTime = now + delay
        grow.fillMode = .backwards
        layer.add(grow, forKey: "grow")
    }

    private func layoutValueLabel(_ label: UILabel, count: Int, slotMinX: CGFloat, slotWidth: CGFloat, barTop: CGFloat, animate: Bool, delay: Double, at now: CFTimeInterval) {
        guard count > 0 else {
            label.isHidden = true
            return
        }
        let text = StatsStyle.abbreviatedCount(count)
        let textWidth = (text as NSString).size(withAttributes: [.font: valueFont]).width
        guard textWidth + 2 <= slotWidth else {
            label.isHidden = true
            return
        }
        label.text = text
        label.isHidden = false
        label.frame = CGRect(x: slotMinX, y: max(0, barTop - valueRowHeight - 1), width: slotWidth, height: valueRowHeight)
        if animate {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.4
            fade.beginTime = now + delay + 0.15
            fade.fillMode = .backwards
            label.layer.add(fade, forKey: "fade")
        }
    }

    private func barColor(_ index: Int) -> UIColor {
        (index == 0 || index == 6) ? StatsStyle.accentBright : StatsStyle.accent.withAlphaComponent(0.7)
    }

    private func applyLayerColors() {
        let trait = traitCollection
        let trackColor = StatsStyle.cardBackground.resolvedColor(with: trait).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<barLayers.count {
            barLayers[i].backgroundColor = barColor(i).resolvedColor(with: trait).cgColor
            trackLayers[i].backgroundColor = trackColor
        }
        CATransaction.commit()
    }

    private func hideAll() {
        for layer in trackLayers { layer.isHidden = true }
        for layer in barLayers { layer.isHidden = true }
        for label in weekdayLabels { label.isHidden = true }
        for label in valueLabels { label.isHidden = true }
    }

    private func updateAccessibility() {
        guard values.count == 7, let maxCount = values.max(), maxCount > 0,
              let index = values.firstIndex(of: maxCount) else {
            accessibilityLabel = "Plays by weekday"
            return
        }
        accessibilityLabel = "Plays by weekday. Busiest \(StatsStyle.weekdayShort(index + 1)) with \(maxCount)."
    }

    private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
