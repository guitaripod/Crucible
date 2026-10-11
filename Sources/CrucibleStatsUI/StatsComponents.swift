import CrucibleDesign
import CrucibleStats
import UIKit

/// The shared card language of the Statistics screen: a surface card with a hairline, a headline
/// title, an optional trailing accessory and one content view.
package final class StatsCardView: UIView {
    package init(title: String?, accessory: UIView? = nil, content: UIView, contentHeight: CGFloat? = nil, accessibilityLabelText: String? = nil, metrics: StatsMetrics = .platform) {
        super.init(frame: .zero)
        backgroundColor = StatsStyle.cardBackground
        layer.cornerRadius = StatsStyle.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderWidth = metrics.card.borderWidth
        applyBorderColor()

        var arranged = [UIView]()
        if let title {
            let titleLabel = UILabel()
            titleLabel.text = title
            titleLabel.font = Theme.Font.headline
            titleLabel.adjustsFontForContentSizeCategory = true
            titleLabel.textColor = Theme.Color.label
            titleLabel.numberOfLines = 0
            titleLabel.accessibilityTraits = .header
            titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

            let header = UIStackView(arrangedSubviews: [titleLabel] + (accessory.map { [$0] } ?? []))
            header.axis = .horizontal
            header.alignment = .firstBaseline
            header.spacing = metrics.card.headerSpacing
            arranged.append(header)
        }
        arranged.append(content)
        let slack = UIView()
        slack.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
        slack.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
        arranged.append(slack)

        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.spacing = metrics.card.spacing
        stack.setCustomSpacing(0, after: content)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: metrics.card.inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -metrics.card.inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.card.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.card.inset),
        ])
        if let contentHeight {
            content.heightAnchor.constraint(equalToConstant: contentHeight).isActive = true
        }
        if let accessibilityLabelText {
            isAccessibilityElement = true
            accessibilityTraits = .image
            accessibilityLabel = accessibilityLabelText
        }

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: StatsCardView, _: UITraitCollection) in
            view.applyBorderColor()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applyBorderColor() {
        layer.borderColor = StatsStyle.hairline.resolvedColor(with: traitCollection).cgColor
    }
}

/// Full-width Week / Month / Year / All segmented control on raised surface tokens.
package final class StatsRangeControl: UIView {
    package var onRange: ((StatsRange) -> Void)?

    private let segmented = UISegmentedControl(items: StatsRange.allCases.map(\.title))

    package init(metrics: StatsMetrics = .platform) {
        super.init(frame: .zero)
        let font = metrics.rangeControl.font.uiFont
        segmented.backgroundColor = Theme.Color.surfaceRaised
        segmented.selectedSegmentTintColor = Theme.Color.surfaceHigh
        segmented.setTitleTextAttributes([
            .foregroundColor: Theme.Color.labelSecondary,
            .font: font,
        ], for: .normal)
        segmented.setTitleTextAttributes([
            .foregroundColor: Theme.Color.label,
            .font: font,
        ], for: .selected)
        segmented.accessibilityLabel = "Time range"
        segmented.addAction(UIAction { [weak self] _ in
            guard let self, let selected = StatsRange(rawValue: segmented.selectedSegmentIndex) else { return }
            Haptics.selection()
            onRange?(selected)
        }, for: .valueChanged)

        segmented.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segmented)
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: topAnchor),
            segmented.bottomAnchor.constraint(equalTo: bottomAnchor),
            segmented.leadingAnchor.constraint(equalTo: leadingAnchor),
            segmented.trailingAnchor.constraint(equalTo: trailingAnchor),
            segmented.heightAnchor.constraint(greaterThanOrEqualToConstant: metrics.rangeControl.minHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    package func select(_ range: StatsRange) {
        segmented.selectedSegmentIndex = range.rawValue
    }
}

/// The ember hero: verdict eyebrow, a huge count-up number with its unit, and two quiet lines.
package final class StatsHeroView: UIView {
    private let gradient = CAGradientLayer()
    private let eyebrowLabel = UILabel()
    private let odometer = CountUpOdometerView()
    private let unitLabel = UILabel()
    private let detailLabel = UILabel()
    private let sinceLabel = UILabel()

    package init(metrics: StatsMetrics = .platform) {
        super.init(frame: .zero)
        layer.cornerRadius = StatsStyle.heroCornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = metrics.hero.borderWidth
        layer.borderColor = Theme.Color.artHairline.cgColor

        gradient.colors = [UIColor(hex: 0x2B1708).cgColor, UIColor(hex: 0x6E3510).cgColor, UIColor(hex: 0xC96A14).cgColor]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradient, at: 0)

        eyebrowLabel.font = Theme.Font.caption2
        eyebrowLabel.textColor = UIColor(hex: 0xFFD08A)
        eyebrowLabel.numberOfLines = 0

        odometer.font = metrics.hero.odometerFont.uiFont
        odometer.textColor = Theme.Color.onArt
        odometer.setContentHuggingPriority(.required, for: .horizontal)
        odometer.setContentCompressionResistancePriority(.required, for: .horizontal)

        unitLabel.font = metrics.hero.unitFont.uiFont
        unitLabel.adjustsFontForContentSizeCategory = true
        unitLabel.textColor = UIColor.white.withAlphaComponent(0.85)

        detailLabel.font = Theme.Font.subheadline
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        detailLabel.numberOfLines = 0

        sinceLabel.font = Theme.Font.footnote
        sinceLabel.adjustsFontForContentSizeCategory = true
        sinceLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        sinceLabel.numberOfLines = 0

        let numberRow = UIView()
        for view in [odometer, unitLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            numberRow.addSubview(view)
        }
        NSLayoutConstraint.activate([
            odometer.topAnchor.constraint(equalTo: numberRow.topAnchor),
            odometer.bottomAnchor.constraint(equalTo: numberRow.bottomAnchor),
            odometer.leadingAnchor.constraint(equalTo: numberRow.leadingAnchor),
            unitLabel.leadingAnchor.constraint(equalTo: odometer.trailingAnchor, constant: metrics.hero.unitSpacing),
            unitLabel.trailingAnchor.constraint(lessThanOrEqualTo: numberRow.trailingAnchor),
            unitLabel.lastBaselineAnchor.constraint(equalTo: odometer.textBaselineAnchor),
        ])

        let stack = UIStackView(arrangedSubviews: [eyebrowLabel, numberRow, detailLabel, sinceLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = metrics.hero.stackSpacing
        stack.setCustomSpacing(metrics.hero.eyebrowSpacing, after: eyebrowLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: metrics.hero.inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -metrics.hero.inset),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.hero.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -metrics.hero.inset),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    package override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }

    /// Fills the hero and, unless Reduce Motion is on or `animate` is false, counts the number up.
    package func configure(eyebrow: String, value: Int, unit: String, detail: String, since: String, animate: Bool) {
        eyebrowLabel.attributedText = NSAttributedString(string: eyebrow.uppercased(), attributes: [.kern: 1.0])
        eyebrowLabel.isHidden = eyebrow.isEmpty
        unitLabel.text = unit
        detailLabel.text = detail
        sinceLabel.text = since
        odometer.setValue(value, animated: animate)
        accessibilityLabel = [eyebrow, "\(value) \(unit)", detail, since].filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

/// "less ▪▪▪ more" legend that sits on the right of the Activity card title.
package final class StatsHeatLegendView: UIView {
    package init(metrics: StatsMetrics = .platform) {
        super.init(frame: .zero)

        let less = Self.caption("less")
        let more = Self.caption("more")
        let swatches = [StatsStyle.heatColor(level: 0), StatsStyle.heatColor(level: 2), StatsStyle.heatColor(level: 5)].map { Self.swatch($0, metrics: metrics.heatLegend) }

        let stack = UIStackView(arrangedSubviews: [less] + swatches + [more])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = metrics.heatLegend.spacing
        stack.setCustomSpacing(metrics.heatLegend.captionGap, after: less)
        stack.setCustomSpacing(metrics.heatLegend.captionGap, after: swatches[2])
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Font.caption1Regular
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.labelSecondary
        return label
    }

    private static func swatch(_ color: UIColor, metrics: StatsMetrics.HeatLegend) -> UIView {
        let view = UIView()
        view.backgroundColor = color
        view.layer.cornerRadius = metrics.swatchCorner
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: metrics.swatch),
            view.heightAnchor.constraint(equalToConstant: metrics.swatch),
        ])
        return view
    }
}
