import UIKit

/// An animated numeric reveal that counts a centred label from its currently displayed integer
/// up (or down) to a target with an ease-out curve, driven by a ``CADisplayLink``. Feed it via
/// ``setValue(_:animated:)``; it honours Reduce Motion by snapping instantly.
final class CountUpOdometerView: UIView {
    var textColor: UIColor = .label {
        didSet { label.textColor = textColor }
    }

    var font: UIFont = CountUpOdometerView.defaultFont {
        didSet {
            label.font = font
            invalidateIntrinsicContentSize()
        }
    }

    var valueFormatter: (Int) -> String = CountUpOdometerView.defaultFormatter {
        didSet {
            renderText(displayedValue)
            invalidateIntrinsicContentSize()
        }
    }

    private let label = UILabel()
    private var displayLink: CADisplayLink?
    private var displayedValue = 0
    private var startValue = 0
    private var targetValue = 0
    private var startTimestamp: CFTimeInterval = 0
    private let animationDuration: CFTimeInterval = 0.9

    override init(frame: CGRect) {
        super.init(frame: frame)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = textColor
        label.font = font
        label.textAlignment = .center
        label.numberOfLines = 1
        label.text = valueFormatter(0)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    convenience init() { self.init(frame: .zero) }

    override var intrinsicContentSize: CGSize {
        let widest = max(measuredWidth(startValue), measuredWidth(targetValue), measuredWidth(displayedValue))
        return CGSize(width: ceil(widest), height: ceil(font.lineHeight))
    }

    /// Animates the label from the currently displayed integer to `value` over ~0.9s (ease-out).
    /// Snaps instantly when `animated` is false, when Reduce Motion is enabled, or when already there.
    func setValue(_ value: Int, animated: Bool) {
        stopDisplayLink()
        startValue = displayedValue
        targetValue = value
        invalidateIntrinsicContentSize()

        guard animated, !UIAccessibility.isReduceMotionEnabled, value != displayedValue else {
            displayedValue = value
            renderText(value)
            return
        }

        startTimestamp = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, displayLink != nil {
            displayedValue = targetValue
            renderText(targetValue)
            stopDisplayLink()
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = link.timestamp - startTimestamp
        let progress = animationDuration > 0 ? min(1, max(0, elapsed / animationDuration)) : 1
        let eased = 1 - pow(1 - progress, 3)
        let span = Double(targetValue - startValue)
        displayedValue = startValue + Int((span * eased).rounded())
        renderText(displayedValue)

        if progress >= 1 {
            displayedValue = targetValue
            renderText(targetValue)
            stopDisplayLink()
            invalidateIntrinsicContentSize()
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func renderText(_ value: Int) {
        label.text = valueFormatter(value)
    }

    private func measuredWidth(_ value: Int) -> CGFloat {
        (valueFormatter(value) as NSString).size(withAttributes: [.font: font]).width
    }

    private static var defaultFont: UIFont {
        let base = UIFont.systemFont(ofSize: 44, weight: .heavy)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: 44)
    }

    private static var defaultFormatter: (Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        return { formatter.string(from: NSNumber(value: $0)) ?? "\($0)" }
    }
}
