import CrucibleCore
import CrucibleDesign
import UIKit

/// A focusable tile that reports Select straight from the remote press, so it does not depend on
/// control events reaching a control inside a collection cell.
class TVHomeTileSurface: TVFocusableSurface {
    var onSelect: (() -> Void)?

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }), let onSelect {
            onSelect()
        }
        super.pressesEnded(presses, with: event)
    }
}

/// The This Week tile: total watch time, the change against last week and seven daily bars. Select
/// opens Statistics.
final class TVHomeWeekSurface: TVHomeTileSurface {
    private static let barAreaHeight: CGFloat = 120
    private static let barWidth: CGFloat = 26
    private static let minimumBarHeight: CGFloat = 8
    private static let dayInitials = ["M", "T", "W", "T", "F", "S", "S"]

    private let totalLabel = UILabel()
    private let deltaLabel = UILabel()
    private var barViews: [UIView] = []
    private var barHeights: [NSLayoutConstraint] = []

    init() {
        super.init(cornerRadius: Theme.Radius.l)
        accessibilityHint = "Opens statistics"
        isContextMenuInteractionEnabled = false
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
        let columns = Self.dayInitials.map { initial -> UIView in
            let bar = UIView()
            bar.layer.cornerRadius = 6
            bar.layer.cornerCurve = .continuous
            bar.translatesAutoresizingMaskIntoConstraints = false
            let height = bar.heightAnchor.constraint(equalToConstant: Self.minimumBarHeight)
            NSLayoutConstraint.activate([bar.widthAnchor.constraint(equalToConstant: Self.barWidth), height])
            barViews.append(bar)
            barHeights.append(height)

            let label = UILabel()
            label.text = initial
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

/// Hosts the This Week tile in a collection cell; the tile is the focus target, never the cell.
final class TVHomeWeekCell: UICollectionViewCell {
    private let surface = TVHomeWeekSurface()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        surface.accessibilityIdentifier = "home.week"
        surface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: contentView.topAnchor),
            surface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    func configure(model: HomeWeekCardModel?, onSelect: @escaping () -> Void) {
        if let model { surface.configure(with: model) }
        surface.onSelect = onSelect
    }
}

/// The last tile of Recently Added: Select offers a random movie, show or either.
final class TVHomeSurpriseSurface: TVHomeTileSurface {
    init() {
        super.init(cornerRadius: TVMetrics.Card.cornerRadius)
        accessibilityLabel = "Surprise Me"
        accessibilityHint = "Picks something to watch"
        isContextMenuInteractionEnabled = false
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

/// Hosts the Surprise Me tile at poster height so it lines up with the posters beside it.
final class TVHomeSurpriseCell: UICollectionViewCell {
    private let surface = TVHomeSurpriseSurface()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false
        surface.accessibilityIdentifier = "home.surprise"
        surface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: contentView.topAnchor),
            surface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            surface.heightAnchor.constraint(equalToConstant: TVMetrics.Card.posterSize.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    func configure(onSelect: @escaping () -> Void) {
        surface.onSelect = onSelect
    }
}
