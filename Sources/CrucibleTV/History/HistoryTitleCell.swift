import CrucibleDesign
import UIKit

struct HistoryTitle: Hashable, Sendable {
    var summary: String?
}

/// The screen's title with the weekly summary beside it. Not focusable.
final class HistoryTitleCell: UICollectionViewCell {
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false

        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.label
        titleLabel.text = "Watch History"
        titleLabel.accessibilityTraits = .header
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        summaryLabel.font = Theme.Font.callout
        summaryLabel.textColor = Theme.Color.labelSecondary
        summaryLabel.adjustsFontSizeToFitWidth = true
        summaryLabel.minimumScaleFactor = 0.8

        let stack = UIStackView(arrangedSubviews: [titleLabel, summaryLabel, UIView()])
        stack.axis = .horizontal
        stack.alignment = .lastBaseline
        stack.spacing = Theme.Space.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    static func registration() -> UICollectionView.CellRegistration<HistoryTitleCell, HistoryTitle> {
        UICollectionView.CellRegistration<HistoryTitleCell, HistoryTitle> { cell, _, item in
            cell.configure(with: item)
        }
    }

    func configure(with item: HistoryTitle) {
        summaryLabel.text = item.summary
        summaryLabel.isHidden = (item.summary ?? "").isEmpty
        summaryLabel.accessibilityIdentifier = "history.summary"
        titleLabel.accessibilityIdentifier = "history.title"
    }
}
