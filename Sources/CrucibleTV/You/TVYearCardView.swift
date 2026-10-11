import CrucibleDesign
import CrucibleStats
import UIKit

/// The Year in Review card of the You tab: this year's hours, a one-line detail and the heat strip
/// of the last 78 days on the ember gradient. A focusable surface; Select opens Statistics.
final class TVYearCardView: TVFocusableSurface {
    private let gradient = CAGradientLayer()
    private let captionLabel = UILabel()
    private let primaryLabel = UILabel()
    private let unitLabel = UILabel()
    private let detailLabel = UILabel()
    private let strip = TVHeatStripView()

    init() {
        super.init(cornerRadius: Theme.Radius.l)
        build()
        accessibilityIdentifier = "you.yearCard"
        accessibilityHint = "Opens Statistics"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ summary: YearInReviewSummary) {
        captionLabel.attributedText = NSAttributedString(string: summary.caption, attributes: [.kern: 1.5])
        primaryLabel.text = summary.primary
        unitLabel.text = summary.unit
        detailLabel.text = summary.detail
        detailLabel.isHidden = summary.detail.isEmpty
        strip.levels = summary.strip
        accessibilityLabel = summary.spokenText
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = contentView.bounds
    }

    private func build() {
        gradient.colors = [UIColor(hex: 0x2B1708).cgColor, UIColor(hex: 0x6E3510).cgColor, UIColor(hex: 0xC96A14).cgColor]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        contentView.layer.insertSublayer(gradient, at: 0)

        captionLabel.font = Theme.Font.scaled(.caption2, 23, .bold, maximum: 30)
        captionLabel.textColor = UIColor(hex: 0xFFD08A)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)))
        chevron.tintColor = Theme.Color.onArtSecondary
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let linkLabel = UILabel()
        linkLabel.text = "Statistics"
        linkLabel.font = Theme.Font.scaled(.caption1, 25, .regular, maximum: 32)
        linkLabel.textColor = Theme.Color.onArtSecondary
        let linkRow = UIStackView(arrangedSubviews: [linkLabel, chevron])
        linkRow.spacing = Theme.Space.xxs
        linkRow.alignment = .center

        let topRow = UIStackView(arrangedSubviews: [captionLabel, UIView(), linkRow])
        topRow.alignment = .center

        primaryLabel.font = Theme.Font.scaled(.title1, 76, .heavy, maximum: 96)
        primaryLabel.textColor = Theme.Color.onArt
        primaryLabel.setContentHuggingPriority(.required, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        unitLabel.font = Theme.Font.title3
        unitLabel.textColor = Theme.Color.onArt.withAlphaComponent(0.85)
        let bigRow = UIStackView(arrangedSubviews: [primaryLabel, unitLabel, UIView()])
        bigRow.spacing = Theme.Space.xs
        bigRow.alignment = .firstBaseline

        detailLabel.font = Theme.Font.callout
        detailLabel.textColor = Theme.Color.onArt.withAlphaComponent(0.85)
        detailLabel.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [topRow, bigRow, detailLabel, strip])
        stack.axis = .vertical
        stack.spacing = Theme.Space.xs
        stack.setCustomSpacing(Theme.Space.s, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: Theme.Space.m, leading: Theme.Space.m, bottom: Theme.Space.m, trailing: Theme.Space.m)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }
}

/// The last 78 days as a three-row strip of ember squares, one column per week-third.
final class TVHeatStripView: UIView {
    var levels: [Int] = [] {
        didSet { setNeedsDisplay() }
    }

    private static let ramp: [UIColor] = [
        Theme.Color.onArt.withAlphaComponent(0.16),
        UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 0.38),
        UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 0.56),
        UIColor(red: 1, green: 0.75, blue: 0.35, alpha: 0.76),
        UIColor(red: 1, green: 0.78, blue: 0.43, alpha: 0.92),
        UIColor(hex: 0xFFE0A6),
    ]

    private static let cellHeight: CGFloat = 14
    private static let gap: CGFloat = 5

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let rows = CGFloat(YearInReviewSummary.stripRows)
        return CGSize(width: UIView.noIntrinsicMetric, height: rows * Self.cellHeight + (rows - 1) * Self.gap)
    }

    override func draw(_ rect: CGRect) {
        let columns = CGFloat(YearInReviewSummary.stripColumns)
        let cellWidth = (bounds.width - (columns - 1) * Self.gap) / columns
        guard cellWidth > 0 else { return }
        for (index, level) in levels.enumerated() {
            let column = CGFloat(index / YearInReviewSummary.stripRows)
            let row = CGFloat(index % YearInReviewSummary.stripRows)
            let frame = CGRect(
                x: column * (cellWidth + Self.gap),
                y: row * (Self.cellHeight + Self.gap),
                width: cellWidth,
                height: Self.cellHeight
            )
            Self.ramp[max(0, min(Self.ramp.count - 1, level))].setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: 3).fill()
        }
    }
}
