import UIKit

/// A 4pt ember progress bar. `.onArt` darkens the track for use over artwork; `.onSurface` uses the
/// raised-surface track for cards and rows.
final class ProgressBar: UIView {
    enum Style {
        case onArt
        case onSurface
    }

    var progress: Double = 0 {
        didSet { setNeedsLayout() }
    }

    var style: Style = .onArt {
        didSet { applyColors() }
    }

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        trackLayer.cornerRadius = 2
        fillLayer.cornerRadius = 2
        layer.addSublayer(trackLayer)
        layer.addSublayer(fillLayer)
        applyColors()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: ProgressBar, _: UITraitCollection) in
            view.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 4)
    }

    override func layoutSubviews() {
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
