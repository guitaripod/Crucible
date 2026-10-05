import UIKit

struct YouYearSummary: Equatable {
    var caption: String
    var primary: String
    var unit: String
    var detail: String
    var strip: [Int]

    static let stripColumns = 26
    static let stripRows = 3

    static var stripCount: Int { stripColumns * stripRows }

    var spokenText: String {
        "\(caption.capitalized). \(primary) \(unit). \(detail). Statistics"
    }

    /// Builds the card from the stats mirror; nil when there is no store or nothing watched yet.
    @MainActor static func load() async -> YouYearSummary? {
        guard let store = StatsManager.shared.store else { return nil }
        guard let snapshot = try? await store.snapshot(range: .year), !snapshot.isEmpty else { return nil }
        let overview = snapshot.overview
        let year = Calendar.current.component(.year, from: Date())

        let primary: String
        let unit: String
        if let hours = overview.estHours {
            let rounded = Int(hours.rounded())
            primary = rounded == 0 ? "<1" : "\(rounded)"
            unit = rounded == 1 ? "hour" : "hours"
        } else {
            primary = "\(overview.totalPlays)"
            unit = overview.totalPlays == 1 ? "play" : "plays"
        }

        var parts = [String]()
        if overview.moviesWatched > 0 { parts.append("\(overview.moviesWatched) \(overview.moviesWatched == 1 ? "movie" : "movies")") }
        if overview.episodes > 0 { parts.append("\(overview.episodes) \(overview.episodes == 1 ? "episode" : "episodes")") }
        if overview.currentStreak > 0 { parts.append("\(overview.currentStreak)-day streak") }

        return YouYearSummary(
            caption: "\(year) SO FAR",
            primary: primary,
            unit: unit,
            detail: parts.joined(separator: " · "),
            strip: stripLevels(from: snapshot.heatmap)
        )
    }

    /// Last 78 days, three days per column, bucketed into 0...5 by quantile so light watchers still get contrast.
    private static func stripLevels(from days: [DayCount]) -> [Int] {
        let today = StatsTime().todayDayEpoch()
        var counts = [Int: Int]()
        for day in days { counts[day.dayEpoch] = day.count }
        let window = (0..<stripCount).map { counts[today - (stripCount - 1) + $0] ?? 0 }
        let positives = window.filter { $0 > 0 }.sorted()
        guard !positives.isEmpty else { return Array(repeating: 0, count: stripCount) }
        let thresholds = [0.2, 0.4, 0.6, 0.8].map { positives[min(positives.count - 1, Int(Double(positives.count - 1) * $0))] }
        return window.map { count in
            count == 0 ? 0 : min(5, 1 + thresholds.filter { count > $0 }.count)
        }
    }
}

struct YouYearCardContentConfiguration: UIContentConfiguration {
    var summary: YouYearSummary

    func makeContentView() -> UIView & UIContentView {
        YouYearCardContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> YouYearCardContentConfiguration {
        self
    }
}

private final class HeatStripView: UIView {
    var levels: [Int] = [] {
        didSet { setNeedsDisplay() }
    }

    private static let ramp: [UIColor] = [
        Theme.Color.onArt.withAlphaComponent(0.14),
        UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 0.38),
        UIColor(red: 1, green: 0.72, blue: 0.30, alpha: 0.56),
        UIColor(red: 1, green: 0.75, blue: 0.35, alpha: 0.76),
        UIColor(red: 1, green: 0.78, blue: 0.43, alpha: 0.92),
        UIColor(hex: 0xFFE0A6),
    ]

    private let cellHeight: CGFloat = 8
    private let gap: CGFloat = 3

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let rows = CGFloat(YouYearSummary.stripRows)
        return CGSize(width: UIView.noIntrinsicMetric, height: rows * cellHeight + (rows - 1) * gap)
    }

    override func draw(_ rect: CGRect) {
        let columns = CGFloat(YouYearSummary.stripColumns)
        let cellWidth = (bounds.width - (columns - 1) * gap) / columns
        guard cellWidth > 0 else { return }
        for (index, level) in levels.enumerated() {
            let column = CGFloat(index / YouYearSummary.stripRows)
            let row = CGFloat(index % YouYearSummary.stripRows)
            let frame = CGRect(x: column * (cellWidth + gap), y: row * (cellHeight + gap), width: cellWidth, height: cellHeight)
            Self.ramp[max(0, min(5, level))].setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: 2).fill()
        }
    }
}

final class YouYearCardContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let gradient = CAGradientLayer()
    private let captionLabel = UILabel()
    private let linkLabel = UILabel()
    private let primaryLabel = UILabel()
    private let unitLabel = UILabel()
    private let detailLabel = UILabel()
    private let strip = HeatStripView()

    init(configuration: YouYearCardContentConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        build()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradient.frame = bounds
    }

    private func build() {
        layer.cornerRadius = Theme.Radius.l
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = Theme.Color.artHairline.cgColor
        gradient.colors = [UIColor(hex: 0x2B1708).cgColor, UIColor(hex: 0x6E3510).cgColor, UIColor(hex: 0xC96A14).cgColor]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradient, at: 0)

        captionLabel.font = Theme.Font.scaled(.caption2, 11, .bold, maximum: 16)
        captionLabel.textColor = UIColor(hex: 0xFFD08A)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        linkLabel.text = "Statistics"
        linkLabel.font = Theme.Font.footnote
        linkLabel.textColor = Theme.Color.onArtSecondary
        linkLabel.adjustsFontForContentSizeCategory = true
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)))
        chevron.tintColor = Theme.Color.onArtSecondary
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        let linkRow = UIStackView(arrangedSubviews: [linkLabel, chevron])
        linkRow.axis = .horizontal
        linkRow.spacing = 2
        linkRow.alignment = .center

        let spacer = UIView()
        spacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        let topRow = UIStackView(arrangedSubviews: [captionLabel, spacer, linkRow])
        topRow.axis = .horizontal
        topRow.alignment = .center

        primaryLabel.font = Theme.Font.scaled(.largeTitle, 52, .heavy, maximum: 72)
        primaryLabel.textColor = Theme.Color.onArt
        primaryLabel.adjustsFontForContentSizeCategory = true
        primaryLabel.setContentHuggingPriority(.required, for: .horizontal)
        primaryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        unitLabel.font = Theme.Font.scaled(.title2, 22, .semibold, maximum: 30)
        unitLabel.textColor = Theme.Color.onArt.withAlphaComponent(0.85)
        unitLabel.adjustsFontForContentSizeCategory = true
        let unitSpacer = UIView()
        unitSpacer.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        let bigRow = UIStackView(arrangedSubviews: [primaryLabel, unitLabel, unitSpacer])
        bigRow.axis = .horizontal
        bigRow.spacing = 6
        bigRow.alignment = .firstBaseline

        detailLabel.font = Theme.Font.scaled(.subheadline, 14, .regular)
        detailLabel.textColor = Theme.Color.onArt.withAlphaComponent(0.82)
        detailLabel.numberOfLines = 0
        detailLabel.adjustsFontForContentSizeCategory = true

        let textStack = UIStackView(arrangedSubviews: [topRow, bigRow, detailLabel])
        textStack.axis = .vertical
        textStack.setCustomSpacing(6, after: topRow)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)
        addSubview(strip)

        let minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: 176)
        minimumHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            minimumHeight,
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            strip.topAnchor.constraint(greaterThanOrEqualTo: textStack.bottomAnchor, constant: 12),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    private func apply() {
        guard let config = configuration as? YouYearCardContentConfiguration else { return }
        let summary = config.summary
        captionLabel.attributedText = NSAttributedString(string: summary.caption, attributes: [.kern: 1.0])
        primaryLabel.text = summary.primary
        unitLabel.text = summary.unit
        detailLabel.text = summary.detail
        detailLabel.isHidden = summary.detail.isEmpty
        strip.levels = summary.strip
        accessibilityLabel = summary.spokenText
    }
}
