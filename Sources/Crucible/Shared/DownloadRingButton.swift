import UIKit

/// The single download affordance used by episode rows, detail screens and the Downloads list:
/// an idle arrow, a queued clock, a progress ring, a completed check or a retry arrow.
final class DownloadRingButton: UIButton {
    enum State: Equatable {
        case idle
        case queued
        case progress(Double)
        case paused(Double)
        case completed
        case failed
    }

    private let trackLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private var currentState: State = .idle

    var diameter: CGFloat = 36 {
        didSet { invalidateIntrinsicContentSize() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.lineWidth = 3
        trackLayer.strokeColor = Theme.Color.surfaceHigh.cgColor
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.lineWidth = 3
        ringLayer.lineCap = .round
        ringLayer.strokeColor = Theme.Color.accent.cgColor
        ringLayer.strokeEnd = 0
        layer.addSublayer(trackLayer)
        layer.addSublayer(ringLayer)
        set(.idle, animated: false)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DownloadRingButton, _: UITraitCollection) in
            view.trackLayer.strokeColor = Theme.Color.surfaceHigh.cgColor
            view.ringLayer.strokeColor = Theme.Color.accent.cgColor
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: max(diameter, Theme.Size.minTarget), height: max(diameter, Theme.Size.minTarget))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            .offsetBy(dx: (bounds.width - diameter) / 2, dy: (bounds.height - diameter) / 2)
            .insetBy(dx: 1.5, dy: 1.5)
        let path = UIBezierPath(ovalIn: rect)
        let rotated = UIBezierPath(
            arcCenter: CGPoint(x: rect.midX, y: rect.midY),
            radius: rect.width / 2,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        trackLayer.path = path.cgPath
        ringLayer.path = rotated.cgPath
    }

    func set(_ state: State, animated: Bool = true) {
        guard state != currentState || configuration == nil else { return }
        currentState = state

        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        let (symbol, tint): (String, UIColor)
        switch state {
        case .idle:
            (symbol, tint) = ("arrow.down", Theme.Color.labelSecondary)
        case .queued:
            (symbol, tint) = ("clock", Theme.Color.labelSecondary)
        case .progress:
            (symbol, tint) = ("pause.fill", Theme.Color.accentText)
        case .paused:
            (symbol, tint) = ("arrow.down", Theme.Color.accentText)
        case .completed:
            (symbol, tint) = ("checkmark", Theme.Color.label)
        case .failed:
            (symbol, tint) = ("arrow.clockwise", Theme.Color.destructive)
        }
        let pointSize: CGFloat = state == .idle || state == .completed || state == .failed ? 15 : 12
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold))
        config.baseForegroundColor = tint
        configuration = config

        let showsRing: Bool
        let fraction: CGFloat
        switch state {
        case .progress(let value), .paused(let value):
            showsRing = true
            fraction = CGFloat(max(0.02, min(1, value)))
        case .idle, .queued:
            showsRing = true
            fraction = 0
        case .completed, .failed:
            showsRing = false
            fraction = 0
        }
        trackLayer.isHidden = !showsRing
        ringLayer.isHidden = !showsRing || fraction == 0
        if animated && !UIAccessibility.isReduceMotionEnabled {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = ringLayer.presentation()?.strokeEnd ?? ringLayer.strokeEnd
            animation.toValue = fraction
            animation.duration = 0.25
            ringLayer.add(animation, forKey: "progress")
        }
        ringLayer.strokeEnd = fraction
        accessibilityLabel = Self.spokenDescription(for: state)
    }

    private static func spokenDescription(for state: State) -> String {
        switch state {
        case .idle: return "Download"
        case .queued: return "Queued. Double tap to cancel"
        case .progress(let value): return "Downloading, \(Int(value * 100)) percent. Double tap to pause"
        case .paused(let value): return "Paused, \(Int(value * 100)) percent. Double tap to resume"
        case .completed: return "Downloaded"
        case .failed: return "Download failed. Double tap to retry"
        }
    }
}
