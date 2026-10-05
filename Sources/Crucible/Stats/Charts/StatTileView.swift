import UIKit

/// A KPI tile: a surface card with an icon-led caption on top, a bold value on the bottom-left,
/// an optional inline suffix ("days · best 31") and an optional sparkline on the bottom-right.
final class StatTileView: UIView {

    /// The content a `StatTileView` renders. `caption` is the inline suffix next to the value.
    struct Model {
        var title: String
        var value: String
        var systemImage: String
        var caption: String?
    }

    private let valueLabel = UILabel()
    private let titleLabel = UILabel()
    private let suffixLabel = UILabel()
    private let symbolImageView = UIImageView()
    private let sparkline = SparklineView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = StatsStyle.cardBackground
        layer.cornerRadius = StatsStyle.tileCornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        applyLayerColors()

        configureLabels()
        configureLayout()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StatTileView, _: UITraitCollection) in
            view.applyLayerColors()
        }
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ model: Model) {
        valueLabel.text = model.value
        titleLabel.attributedText = Self.kernedTitle(model.title)
        symbolImageView.image = UIImage(systemName: model.systemImage)

        if let caption = model.caption, !caption.isEmpty {
            suffixLabel.text = caption
            suffixLabel.isHidden = false
        } else {
            suffixLabel.text = nil
            suffixLabel.isHidden = true
        }

        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = [model.title, model.value, model.caption]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    func setSparkline(_ values: [Int]) {
        sparkline.setValues(values)
    }

    private func applyLayerColors() {
        layer.borderColor = StatsStyle.hairline.resolvedColor(with: traitCollection).cgColor
    }

    private func configureLabels() {
        valueLabel.font = Theme.Font.scaled(.title1, 30, .bold, maximum: 40)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.textColor = Theme.Color.label
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = Theme.Font.caption2
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.labelTertiary
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        suffixLabel.font = Theme.Font.subheadline
        suffixLabel.adjustsFontForContentSizeCategory = true
        suffixLabel.textColor = Theme.Color.labelSecondary
        suffixLabel.numberOfLines = 1
        suffixLabel.isHidden = true

        symbolImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        symbolImageView.contentMode = .scaleAspectFit
        symbolImageView.tintColor = Theme.Color.labelTertiary
        symbolImageView.setContentHuggingPriority(.required, for: .horizontal)
        symbolImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureLayout() {
        let captionRow = UIStackView(arrangedSubviews: [symbolImageView, titleLabel])
        captionRow.axis = .horizontal
        captionRow.spacing = 6
        captionRow.alignment = .center

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let valueRow = UIStackView(arrangedSubviews: [valueLabel, suffixLabel, spacer, sparkline])
        valueRow.axis = .horizontal
        valueRow.spacing = 6
        valueRow.alignment = .lastBaseline

        let stack = UIStackView(arrangedSubviews: [captionRow, valueRow])
        stack.axis = .vertical
        stack.distribution = .equalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        sparkline.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 96),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            sparkline.widthAnchor.constraint(equalToConstant: 64),
            sparkline.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    private static func kernedTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title.uppercased(), attributes: [.kern: 0.9])
    }
}

/// A 64x26 ember polyline that draws itself in unless Reduce Motion is on. Hidden when the series
/// is empty, flat-zero, or too short to form a line.
private final class SparklineView: UIView {
    private let shape = CAShapeLayer()
    private var values: [Int] = []
    private var pendingAnimation = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        shape.fillColor = nil
        shape.lineWidth = 2
        shape.lineCap = .round
        shape.lineJoin = .round
        layer.addSublayer(shape)
        isHidden = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SparklineView, _: UITraitCollection) in
            view.applyColor()
        }
        applyColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setValues(_ newValues: [Int]) {
        values = newValues
        let hasShape = newValues.count >= 2 && newValues.contains { $0 != 0 }
        isHidden = !hasShape
        pendingAnimation = hasShape && !UIAccessibility.isReduceMotionEnabled
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isHidden, bounds.width > 4, bounds.height > 4 else { return }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let low = values.min() ?? 0
        let span = Double((values.max() ?? 0) - low)
        let denominator = CGFloat(values.count - 1)
        let path = UIBezierPath()
        for (index, value) in values.enumerated() {
            let normalized = span == 0 ? 0.5 : (Double(value - low) / span)
            let point = CGPoint(
                x: rect.minX + rect.width * CGFloat(index) / denominator,
                y: rect.maxY - rect.height * CGFloat(normalized)
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = path.cgPath
        CATransaction.commit()

        if pendingAnimation {
            pendingAnimation = false
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = 0.55
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shape.add(animation, forKey: "draw")
        }
    }

    private func applyColor() {
        shape.strokeColor = Theme.Color.accent.resolvedColor(with: traitCollection).cgColor
    }
}
