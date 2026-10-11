import CrucibleDesign
import CrucibleStatsUI
import UIKit

/// A Statistics card that takes focus, so the scroll view can bring every section into view with the
/// remote. It lifts like every `TVFocusableSurface`; the chart inside stays a plain view. Select does
/// nothing unless `onSelect` is set.
final class TVStatsPanel: TVFocusableSurface {
    var onSelect: (@MainActor () -> Void)? {
        didSet { accessibilityTraits = onSelect == nil ? .staticText : .button }
    }

    init(
        title: String? = nil,
        accessory: UIView? = nil,
        content: UIView,
        margins: NSDirectionalEdgeInsets = TVStatsPanel.defaultMargins,
        spacing: CGFloat = StatsMetrics.tv.card.spacing,
        summary: String?
    ) {
        super.init(cornerRadius: StatsStyle.cornerRadius)
        contentView.directionalLayoutMargins = margins
        accessibilityLabel = summary
        accessibilityTraits = .staticText

        var arranged = [UIView]()
        if let title {
            let titleLabel = UILabel()
            titleLabel.text = title
            titleLabel.font = Theme.Font.headline
            titleLabel.textColor = Theme.Color.label
            titleLabel.accessibilityTraits = .header
            titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
            let header = UIStackView(arrangedSubviews: [titleLabel] + (accessory.map { [UIView(), $0] } ?? []))
            header.axis = .horizontal
            header.alignment = .center
            header.spacing = StatsMetrics.tv.card.headerSpacing
            arranged.append(header)
        }
        arranged.append(content)

        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        let guide = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
        addAction(UIAction { [weak self] _ in self?.onSelect?() }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static let defaultMargins = NSDirectionalEdgeInsets(
        top: StatsMetrics.tv.card.inset,
        leading: StatsMetrics.tv.card.inset,
        bottom: StatsMetrics.tv.card.inset,
        trailing: StatsMetrics.tv.card.inset
    )

    static let flushMargins = NSDirectionalEdgeInsets.zero
}
