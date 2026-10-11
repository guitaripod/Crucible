import CrucibleDesign
import CrucibleStats
import UIKit

/// A gradient "wrapped"-style hero card that presents a single ``Superlative`` inside a
/// paged carousel cell (roughly full-width by 150pt). Configure it with ``configure(_:)``.
package final class SuperlativeCardView: UIView {
    private let metrics: StatsMetrics.WrappedCard
    private let gradientLayer = CAGradientLayer()
    private let symbolView = UIImageView()
    private let headlineLabel = UILabel()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let contentStack = UIStackView()

    package init(metrics: StatsMetrics = .platform) {
        self.metrics = metrics.wrappedCard
        super.init(frame: .zero)

        configureViews()

        layer.cornerRadius = StatsStyle.cornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        applyGradientColors()
        layer.insertSublayer(gradientLayer, at: 0)

        contentStack.addArrangedSubview(symbolView)
        contentStack.setCustomSpacing(self.metrics.spacingAfterSymbol, after: symbolView)
        contentStack.addArrangedSubview(headlineLabel)
        contentStack.setCustomSpacing(self.metrics.spacingAfterHeadline, after: headlineLabel)
        contentStack.addArrangedSubview(titleLabel)
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentStack.addArrangedSubview(spacer)
        contentStack.addArrangedSubview(captionLabel)
        addSubview(contentStack)

        let padding = self.metrics.padding
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

    package override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: metrics.intrinsicHeight)
    }

    private func configureViews() {
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = Theme.Color.onArt
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: metrics.symbolPointSize, weight: .semibold)
        symbolView.setContentHuggingPriority(.required, for: .vertical)
        symbolView.setContentCompressionResistancePriority(.required, for: .vertical)

        headlineLabel.font = metrics.headlineFont.uiFont
        headlineLabel.textColor = Theme.Color.onArt
        headlineLabel.adjustsFontSizeToFitWidth = true
        headlineLabel.minimumScaleFactor = 0.5
        headlineLabel.numberOfLines = 1
        headlineLabel.lineBreakMode = .byTruncatingTail

        titleLabel.font = metrics.titleFont.uiFont
        titleLabel.textColor = Theme.Color.onArt
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        captionLabel.font = metrics.captionFont.uiFont
        captionLabel.textColor = Theme.Color.onArtSecondary
        captionLabel.numberOfLines = 2
        captionLabel.lineBreakMode = .byTruncatingTail

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = metrics.stackSpacing
    }

    package override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        CATransaction.commit()
    }

    /// Populates the card with a superlative and, unless Reduce Motion is on, gently fades the content in.
    package func configure(_ superlative: Superlative) {
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
}
