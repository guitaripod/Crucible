import UIKit

/// An ember progress bar, 4pt thick on iPhone and 8pt on Apple TV. `.onArt` darkens the track for
/// use over artwork; `.onSurface` uses the raised-surface track for cards and rows.
package final class ProgressBar: UIView {
    package enum Style {
        case onArt
        case onSurface
    }

    package var progress: Double = 0 {
        didSet { setNeedsLayout() }
    }

    package var style: Style = .onArt {
        didSet { applyColors() }
    }

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    package override init(frame: CGRect) {
        super.init(frame: frame)
        trackLayer.cornerRadius = Theme.Metric.progressBarThickness / 2
        fillLayer.cornerRadius = Theme.Metric.progressBarThickness / 2
        layer.addSublayer(trackLayer)
        layer.addSublayer(fillLayer)
        applyColors()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ProgressBar, _: UITraitCollection) in
            view.applyColors()
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Theme.Metric.progressBarThickness)
    }

    package override func layoutSubviews() {
        super.layoutSubviews()
        trackLayer.frame = bounds
        let clamped = max(0, min(1, progress))
        fillLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
    }

    private func applyColors() {
        let resolved = traitCollection
        resolved.performAsCurrent {
            switch style {
            case .onArt:
                trackLayer.backgroundColor = UIColor.black.withAlphaComponent(0.5).cgColor
            case .onSurface:
                trackLayer.backgroundColor = Theme.Color.surfaceHigh.cgColor
            }
            fillLayer.backgroundColor = Theme.Color.accent.cgColor
        }
    }
}
