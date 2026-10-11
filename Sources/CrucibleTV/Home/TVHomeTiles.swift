import CrucibleCore
import CrucibleDesign
import UIKit

/// The This Week tile: total watch time, the change against last week and seven daily bars. Select
/// opens Statistics.
final class TVHomeWeekSurface: TVFocusableSurface {
    private static let barAreaHeight: CGFloat = 120
    private static let barWidth: CGFloat = 26
    private static let minimumBarHeight: CGFloat = 8

    private let totalLabel = UILabel()
    private let deltaLabel = UILabel()
    private var barViews: [UIView] = []
    private var initialLabels: [UILabel] = []
    private var barHeights: [NSLayoutConstraint] = []

    init() {
        super.init(cornerRadius: Theme.Radius.l)
        accessibilityHint = "Opens statistics"
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(with model: HomeWeekCardModel) {
        totalLabel.text = model.total
        deltaLabel.text = model.delta
        deltaLabel.isHidden = model.delta == nil
        for (index, bar) in model.bars.enumerated() where index < barViews.count {
            barHeights[index].constant = max(Self.minimumBarHeight, (Self.barAreaHeight * CGFloat(bar.ratio)).rounded())
            initialLabels[index].text = bar.initial
            barViews[index].backgroundColor = bar.isToday ? Theme.Color.accent : Theme.Color.labelTertiary.withAlphaComponent(0.45)
        }
        accessibilityLabel = model.accessibilityLabel
    }

    private func buildHierarchy() {
        let eyebrow = UILabel()
        eyebrow.attributedText = NSAttributedString(string: "THIS WEEK", attributes: [.kern: 1.2])
        eyebrow.font = Theme.Font.caption1
        eyebrow.textColor = Theme.Color.accentText

        totalLabel.font = Theme.Font.title2
        totalLabel.textColor = Theme.Color.label
        totalLabel.adjustsFontSizeToFitWidth = true
        totalLabel.minimumScaleFactor = 0.7
        deltaLabel.font = Theme.Font.callout
        deltaLabel.textColor = Theme.Color.labelSecondary
        deltaLabel.numberOfLines = 2

        let text = UIStackView(arrangedSubviews: [eyebrow, totalLabel, deltaLabel])
        text.axis = .vertical
        text.spacing = Theme.Space.xxs
        text.alignment = .leading

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = Theme.Color.labelTertiary
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: Theme.Font.callout)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [text, UIView(), makeBars(), chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.l
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    private func makeBars() -> UIView {
        let columns = (0..<HomeWeekCardModel.barCount).map { _ -> UIView in
            let bar = UIView()
            bar.layer.cornerRadius = 6
            bar.layer.cornerCurve = .continuous
            bar.translatesAutoresizingMaskIntoConstraints = false
            let height = bar.heightAnchor.constraint(equalToConstant: Self.minimumBarHeight)
            NSLayoutConstraint.activate([bar.widthAnchor.constraint(equalToConstant: Self.barWidth), height])
            barViews.append(bar)
            barHeights.append(height)

            let label = UILabel()
            initialLabels.append(label)
            label.font = Theme.Font.caption2
            label.textColor = Theme.Color.labelTertiary
            label.textAlignment = .center

            let slot = UIView()
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(bar)
            NSLayoutConstraint.activate([
                slot.heightAnchor.constraint(equalToConstant: Self.barAreaHeight),
                bar.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
                bar.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                slot.widthAnchor.constraint(equalToConstant: Self.barWidth),
            ])
            let column = UIStackView(arrangedSubviews: [slot, label])
            column.axis = .vertical
            column.spacing = Theme.Space.xxs
            return column
        }
        let stack = UIStackView(arrangedSubviews: columns)
        stack.axis = .horizontal
        stack.alignment = .bottom
        stack.spacing = Theme.Space.xs
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }
}

/// The last tile of Recently Added: Select offers a random movie, show or either.
final class TVHomeSurpriseSurface: TVFocusableSurface {
    init() {
        super.init(cornerRadius: TVMetrics.Card.cornerRadius)
        accessibilityLabel = "Surprise Me"
        accessibilityHint = "Picks something to watch"
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildHierarchy() {
        let symbol = UIImageView(image: UIImage(systemName: "sparkles"))
        symbol.tintColor = Theme.Color.accent
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 72, weight: .light)
        symbol.contentMode = .scaleAspectFit

        let title = UILabel()
        title.text = "Surprise Me"
        title.font = Theme.Font.headline
        title.textColor = Theme.Color.label
        title.textAlignment = .center
        title.numberOfLines = 2

        let subtitle = UILabel()
        subtitle.text = "Random pick"
        subtitle.font = Theme.Font.subheadline
        subtitle.textColor = Theme.Color.labelSecondary
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [symbol, title, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Space.s
        stack.setCustomSpacing(Theme.Space.xxs, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Space.s),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Space.s),
        ])
    }
}
