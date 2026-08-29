import UIKit

/// A compact KPI tile for the Year-in-Review stats screen: a rounded card with a
/// large value, an uppercased title, a top-trailing SF Symbol, an optional footnote
/// caption, and an optional sparkline drawn subtly in the lower band behind the value.
final class StatTileView: UIView {

    /// The content a `StatTileView` renders. `accent` tints the symbol and sparkline.
    struct Model {
        var title: String
        var value: String
        var systemImage: String
        var caption: String?
        var accent: UIColor = StatsStyle.accent
    }

    private let inset: CGFloat = 14
    private let bottomInset: CGFloat = 11
    private let sparklineBand: CGFloat = 30

    private let valueLabel = UILabel()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let symbolImageView = UIImageView()
    private let textStack = UIStackView()
    private let sparklineLayer = CAShapeLayer()

    private var accent: UIColor = StatsStyle.accent
    private var sparklineValues: [Int] = []
    private var pendingSparklineAnimation = false

    private let hairlineColor = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.07)
            : UIColor.black.withAlphaComponent(0.06)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = StatsStyle.cardBackground
        layer.cornerRadius = StatsStyle.tileCornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        sparklineLayer.fillColor = nil
        sparklineLayer.lineWidth = 1.5
        sparklineLayer.lineCap = .round
        sparklineLayer.lineJoin = .round
        sparklineLayer.opacity = 0
        layer.insertSublayer(sparklineLayer, at: 0)

        configureValueLabel()
        configureTitleLabel()
        configureCaptionLabel()
        configureSymbol()
        configureStack()
        setupConstraints()
        applyLayerColors()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StatTileView, _: UITraitCollection) in
            view.applyLayerColors()
        }
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 96)
    }

    /// Populates every label, the symbol, and the accent-derived layer colours.
    func configure(_ model: Model) {
        accent = model.accent
        valueLabel.text = model.value
        titleLabel.attributedText = Self.kernedTitle(model.title)
        symbolImageView.image = UIImage(systemName: model.systemImage)
        symbolImageView.tintColor = model.accent

        if let caption = model.caption, !caption.isEmpty {
            captionLabel.text = caption
            captionLabel.isHidden = false
        } else {
            captionLabel.text = nil
            captionLabel.isHidden = true
        }

        applyAccessibility(model)
        applyLayerColors()
        setNeedsLayout()
    }

    /// Renders a subtle polyline in the tile's lower band. Hidden when `values` is
    /// empty, all-zero, or too short to form a line.
    func setSparkline(_ values: [Int]) {
        sparklineValues = values
        let hasShape = values.count >= 2 && values.contains { $0 != 0 }
        if hasShape, !UIAccessibility.isReduceMotionEnabled {
            pendingSparklineAnimation = true
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        layer.borderWidth = 1 / scale
        updateSparkline()
    }

    private func updateSparkline() {
        let values = sparklineValues
        guard values.count >= 2, values.contains(where: { $0 != 0 }) else {
            hideSparkline()
            return
        }

        let width = bounds.width - inset * 2
        let sparkBottom = captionLabel.isHidden
            ? bounds.height - inset
            : captionLabel.frame.minY - 4
        let bandHeight = min(sparklineBand, sparkBottom - inset)
        guard width > 6, bandHeight > 6 else {
            hideSparkline()
            return
        }

        let rect = CGRect(x: inset, y: sparkBottom - bandHeight, width: width, height: bandHeight)
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 0
        let range = Double(maxV - minV)
        let denominator = CGFloat(values.count - 1)

        let path = UIBezierPath()
        for (index, value) in values.enumerated() {
            let progress = CGFloat(index) / denominator
            let x = rect.minX + rect.width * progress
            let normalized: CGFloat = range == 0 ? 0.5 : CGFloat((Double(value) - Double(minV)) / range)
            let clamped = max(0, min(1, normalized))
            let y = rect.maxY - clamped * rect.height
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sparklineLayer.frame = bounds
        sparklineLayer.path = path.cgPath
        sparklineLayer.opacity = 1
        CATransaction.commit()

        if pendingSparklineAnimation {
            pendingSparklineAnimation = false
            animateSparklineStroke()
        }
    }

    private func hideSparkline() {
        pendingSparklineAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sparklineLayer.path = nil
        sparklineLayer.opacity = 0
        CATransaction.commit()
    }

    private func animateSparklineStroke() {
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.55
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        sparklineLayer.add(animation, forKey: "draw")
    }

    private func applyLayerColors() {
        let resolved = traitCollection
        sparklineLayer.strokeColor = accent.resolvedColor(with: resolved).withAlphaComponent(0.5).cgColor
        layer.borderColor = hairlineColor.resolvedColor(with: resolved).cgColor
    }

    private func applyAccessibility(_ model: Model) {
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = [model.value, model.title, model.caption]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func configureValueLabel() {
        valueLabel.font = Self.roundedFont(size: 26, weight: .bold)
        valueLabel.textColor = .label
        valueLabel.numberOfLines = 1
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureTitleLabel() {
        titleLabel.font = Self.roundedFont(size: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureCaptionLabel() {
        captionLabel.font = .systemFont(ofSize: 10, weight: .regular)
        captionLabel.textColor = .tertiaryLabel
        captionLabel.numberOfLines = 1
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.isHidden = true
        addSubview(captionLabel)
    }

    private func configureSymbol() {
        symbolImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        symbolImageView.contentMode = .scaleAspectFit
        symbolImageView.tintColor = accent
        symbolImageView.translatesAutoresizingMaskIntoConstraints = false
        symbolImageView.setContentHuggingPriority(.required, for: .horizontal)
        symbolImageView.setContentHuggingPriority(.required, for: .vertical)
        symbolImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(symbolImageView)
    }

    private func configureStack() {
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(valueLabel)
        textStack.addArrangedSubview(titleLabel)
        addSubview(textStack)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            symbolImageView.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            symbolImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            textStack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: symbolImageView.leadingAnchor, constant: -6),

            captionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            captionLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomInset),
        ])
    }

    private static func kernedTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title.uppercased(), attributes: [.kern: 0.6])
    }

    private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
