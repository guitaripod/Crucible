import UIKit

/// A gradient "wrapped"-style hero card that presents a single ``Superlative`` inside a
/// paged carousel cell (roughly full-width by 150pt). Configure it with ``configure(_:)``.
final class SuperlativeCardView: UIView {
    private let gradientLayer = CAGradientLayer()

    private let symbolView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.tintColor = .white
        view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }()

    private let headlineLabel: UILabel = {
        let label = UILabel()
        label.font = SuperlativeCardView.roundedFont(size: 40, weight: .heavy)
        label.textColor = .white
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.95)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let captionLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = UIColor.white.withAlphaComponent(0.75)
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        layer.cornerRadius = StatsStyle.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        applyGradientColors()
        layer.insertSublayer(gradientLayer, at: 0)

        contentStack.addArrangedSubview(symbolView)
        contentStack.setCustomSpacing(10, after: symbolView)
        contentStack.addArrangedSubview(headlineLabel)
        contentStack.setCustomSpacing(2, after: headlineLabel)
        contentStack.addArrangedSubview(titleLabel)
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentStack.addArrangedSubview(spacer)
        contentStack.addArrangedSubview(captionLabel)
        addSubview(contentStack)

        let padding: CGFloat = 18
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SuperlativeCardView, _) in
            view.applyGradientColors()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    convenience init() { self.init(frame: .zero) }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 150)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        CATransaction.commit()
    }

    /// Populates the card with a superlative and, unless Reduce Motion is on, gently fades the content in.
    func configure(_ superlative: Superlative) {
        symbolView.image = UIImage(systemName: superlative.symbol)
        headlineLabel.text = superlative.headline
        titleLabel.text = superlative.title
        captionLabel.text = superlative.caption
        titleLabel.isHidden = superlative.title.isEmpty
        captionLabel.isHidden = superlative.caption.isEmpty

        guard !UIAccessibility.isReduceMotionEnabled else {
            contentStack.alpha = 1
            return
        }
        contentStack.alpha = 0
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.contentStack.alpha = 1
        }
    }

    private func applyGradientColors() {
        let bottomTrailing = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.18, green: 0.07, blue: 0.0, alpha: 1.0)
                : UIColor(red: 0.62, green: 0.24, blue: 0.05, alpha: 1.0)
        }
        gradientLayer.colors = [
            StatsStyle.accentBright.resolvedColor(with: traitCollection).cgColor,
            bottomTrailing.resolvedColor(with: traitCollection).cgColor,
        ]
    }

    private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
