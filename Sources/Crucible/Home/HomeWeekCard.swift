@preconcurrency import UIKit

/// The "This week" watch-time card: total, change against last week and seven daily bars.
struct HomeWeekConfiguration: UIContentConfiguration, Hashable {
    var summary: HomeWeekSummary?

    func makeContentView() -> UIView & UIContentView {
        HomeWeekContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> HomeWeekConfiguration {
        self
    }
}

final class HomeWeekContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private static let barAreaHeight: CGFloat = 56
    private static let minimumBarHeight: CGFloat = 4

    private let cardView = UIView()
    private let captionLabel = UILabel()
    private let totalLabel = UILabel()
    private let deltaLabel = UILabel()
    private let barsStack = UIStackView()
    private var bars: [UIView] = []
    private var barHeights: [NSLayoutConstraint] = []
    private let chevron = UIImageView()

    init(configuration: HomeWeekConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HomeWeekContentView, _: UITraitCollection) in
            view.applyBorderColor()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        cardView.backgroundColor = Theme.Color.surface
        cardView.layer.cornerRadius = 20
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1
        applyBorderColor()

        captionLabel.attributedText = NSAttributedString(string: "THIS WEEK", attributes: [.kern: 1.0])
        captionLabel.font = Theme.Font.scaled(.caption2, 11, .bold, maximum: 16)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = Theme.Color.labelTertiary

        totalLabel.font = Theme.Font.title1
        totalLabel.adjustsFontForContentSizeCategory = true
        totalLabel.textColor = Theme.Color.label
        totalLabel.adjustsFontSizeToFitWidth = true
        totalLabel.minimumScaleFactor = 0.7

        deltaLabel.font = Theme.Font.footnote
        deltaLabel.adjustsFontForContentSizeCategory = true
        deltaLabel.textColor = Theme.Color.labelSecondary
        deltaLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [captionLabel, totalLabel, deltaLabel])
        textStack.axis = .vertical
        textStack.spacing = 0

        barsStack.axis = .horizontal
        barsStack.alignment = .bottom
        barsStack.spacing = 6
        for _ in 0..<7 {
            let bar = UIView()
            bar.layer.cornerRadius = 4
            bar.layer.cornerCurve = .continuous
            bar.translatesAutoresizingMaskIntoConstraints = false
            let height = bar.heightAnchor.constraint(equalToConstant: Self.minimumBarHeight)
            NSLayoutConstraint.activate([bar.widthAnchor.constraint(equalToConstant: 10), height])
            barsStack.addArrangedSubview(bar)
            bars.append(bar)
            barHeights.append(height)
        }
        barsStack.translatesAutoresizingMaskIntoConstraints = false
        barsStack.heightAnchor.constraint(equalToConstant: Self.barAreaHeight).isActive = true
        barsStack.setContentHuggingPriority(.required, for: .horizontal)
        barsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        chevron.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        chevron.tintColor = Theme.Color.labelTertiary
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [textStack, barsStack, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.m
        row.translatesAutoresizingMaskIntoConstraints = false

        cardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)
        cardView.addSubview(row)
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardView.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),
            row.topAnchor.constraint(greaterThanOrEqualTo: cardView.topAnchor, constant: Theme.Space.m),
            row.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -Theme.Space.m),
            row.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Opens statistics"
    }

    private func applyBorderColor() {
        traitCollection.performAsCurrent {
            cardView.layer.borderColor = Theme.Color.separator.cgColor
        }
    }

    private func apply() {
        guard let config = configuration as? HomeWeekConfiguration, let summary = config.summary else { return }
        totalLabel.text = HomeFormat.weekTotal(summary.thisWeekSeconds)
        let delta = Self.deltaText(summary.deltaPercent)
        deltaLabel.text = delta
        deltaLabel.isHidden = delta == nil

        let peak = max(summary.dailySeconds.max() ?? 0, 1)
        for (index, bar) in bars.enumerated() {
            let seconds = summary.dailySeconds[safe: index] ?? 0
            let ratio = CGFloat(seconds) / CGFloat(peak)
            barHeights[index].constant = max(Self.minimumBarHeight, (Self.barAreaHeight * ratio).rounded())
            bar.backgroundColor = index == summary.todayIndex ? Theme.Color.accent : Theme.Color.surfaceHigh
        }

        accessibilityLabel = HomeFormat.joined([
            "This week",
            "\(HomeFormat.spoken(Double(summary.thisWeekSeconds))) watched",
            delta,
        ])
    }

    private static func deltaText(_ percent: Int?) -> String? {
        guard let percent else { return nil }
        if percent > 0 { return "\(percent)% more than last week" }
        if percent < 0 { return "\(-percent)% less than last week" }
        return "Same as last week"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
