import CrucibleDesign
import CrucibleStats
import UIKit

extension CAGradientLayer {
    /// The ember gradient behind the Statistics hero and the Year in Review card.
    package static func ember() -> CAGradientLayer {
        let gradient = CAGradientLayer()
        gradient.colors = [Theme.Color.emberTop.cgColor, Theme.Color.emberMid.cgColor, Theme.Color.emberBottom.cgColor]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        return gradient
    }
}

/// The Year in Review card on the ember gradient: caption, a "Statistics" link, this year's number with
/// its unit, a one-line detail and the heat strip of the last 78 days. The same view serves the iPhone
/// You tab and the Apple TV You tab; the host supplies the corner, the border and the interaction.
package final class YearInReviewCardView: UIView {
    private let metrics: StatsMetrics.YearCard
    private let gradient = CAGradientLayer.ember()
    private let captionLabel = UILabel()
    private let primaryLabel = UILabel()
    private let unitLabel = UILabel()
    private let detailLabel = UILabel()
    private let strip: HeatStripView

    package init(metrics: StatsMetrics = .platform) {
        self.metrics = metrics.yearCard
        strip = HeatStripView(strip: metrics.yearStrip)
        super.init(frame: .zero)
        layer.insertSublayer(gradient, at: 0)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    package override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    package func configure(_ summary: YearInReviewSummary) {
        captionLabel.attributedText = NSAttributedString(string: summary.caption, attributes: [.kern: metrics.captionKern])
        primaryLabel.text = summary.primary
        unitLabel.text = summary.unit
        detailLabel.text = summary.detail
        detailLabel.isHidden = summary.detail.isEmpty
        strip.levels = summary.strip
    }

    private func build() {
        captionLabel.font = metrics.captionFont.uiFont
        captionLabel.textColor = Theme.Color.emberEyebrow
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let linkLabel = UILabel()
        linkLabel.text = "Statistics"
        linkLabel.font = metrics.linkFont.uiFont
        linkLabel.textColor = Theme.Color.onArtSecondary
        linkLabel.adjustsFontForContentSizeCategory = true
        let chevronConfiguration = UIImage.SymbolConfiguration(pointSize: metrics.chevronPointSize, weight: .semibold)
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: chevronConfiguration))
        chevron.tintColor = Theme.Color.onArtSecondary
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let linkRow = UIStackView(arrangedSubviews: [linkLabel, chevron])
        linkRow.axis = .horizontal
        linkRow.spacing = metrics.linkSpacing
        linkRow.alignment = .center

        let spacer = UIView()
        spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        let topRow = UIStackView(arrangedSubviews: [captionLabel, spacer, linkRow])
        topRow.axis = .horizontal
        topRow.alignment = .center

        primaryLabel.font = metrics.primaryFont.uiFont
        primaryLabel.textColor = Theme.Color.onArt
        primaryLabel.adjustsFontForContentSizeCategory = true
        primaryLabel.setContentHuggingPriority(.required, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        unitLabel.font = metrics.unitFont.uiFont
        unitLabel.textColor = Theme.Color.onArtMuted
        unitLabel.adjustsFontForContentSizeCategory = true
        let unitSpacer = UIView()
        unitSpacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        let bigRow = UIStackView(arrangedSubviews: [primaryLabel, unitLabel, unitSpacer])
        bigRow.axis = .horizontal
        bigRow.spacing = metrics.bigRowSpacing
        bigRow.alignment = .firstBaseline

        detailLabel.font = metrics.detailFont.uiFont
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        detailLabel.numberOfLines = metrics.detailLines
        detailLabel.adjustsFontForContentSizeCategory = true

        let textStack = UIStackView(arrangedSubviews: [topRow, bigRow, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = metrics.lineSpacing
        textStack.setCustomSpacing(metrics.afterTopRow, after: topRow)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)
        addSubview(strip)

        let minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: metrics.minHeight)
        minimumHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            minimumHeight,
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: metrics.inset),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.inset),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.inset),
            strip.topAnchor.constraint(greaterThanOrEqualTo: textStack.bottomAnchor, constant: metrics.stripGap),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.inset),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.inset),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -metrics.stripBottomInset),
        ])
    }
}
