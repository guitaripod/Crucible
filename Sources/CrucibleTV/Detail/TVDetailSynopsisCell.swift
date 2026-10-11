import CrucibleDesign
import UIKit

/// The synopsis under the hero: up to four lines of text and, when the text is longer, a focusable
/// "More" button that opens the full text.
final class TVDetailSynopsisCell: UICollectionViewCell {
    static let lineLimit = 4
    static let width = TVMetrics.Hero.textColumnWidth
    private static let moreButtonInset: CGFloat = 20

    private let label = UILabel()
    private let moreButton = UIButton(type: .system)
    private var moreBottom: NSLayoutConstraint?
    private var actionIdentifier: UIAction.Identifier?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        clipsToBounds = false
        contentView.clipsToBounds = false

        label.font = Theme.Font.body
        label.textColor = Theme.Color.labelSecondary
        label.numberOfLines = Self.lineLimit
        label.lineBreakMode = .byTruncatingTail

        moreButton.configuration = TVButton.configuration(.plain, title: "More")
        moreButton.accessibilityIdentifier = "detail.synopsis.more"
        moreButton.accessibilityLabel = "More"

        [label, moreButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        let bottomWithMore = moreButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        moreBottom = bottomWithMore
        let bottomWithoutMore = label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        bottomWithoutMore.priority = .defaultLow
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: Self.width),
            moreButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: Theme.Space.xs),
            moreButton.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: -Self.moreButtonInset),
            bottomWithoutMore,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFocused: Bool { false }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { moreButton.isHidden ? [] : [moreButton] }

    static func registration(
        text: @escaping @MainActor () -> String?,
        onMore: @escaping @MainActor () -> Void
    ) -> UICollectionView.CellRegistration<TVDetailSynopsisCell, Int> {
        UICollectionView.CellRegistration<TVDetailSynopsisCell, Int> { cell, _, _ in
            cell.configure(text: text() ?? "", onMore: onMore)
        }
    }

    func configure(text: String, onMore: @escaping @MainActor () -> Void) {
        label.text = text
        let truncated = Self.isTruncated(text)
        moreButton.isHidden = !truncated
        moreBottom?.isActive = truncated
        if let identifier = actionIdentifier {
            moreButton.removeAction(identifiedBy: identifier, for: .primaryActionTriggered)
        }
        let action = UIAction { _ in onMore() }
        actionIdentifier = action.identifier
        moreButton.addAction(action, for: .primaryActionTriggered)
        label.accessibilityLabel = text
    }

    /// Whether `text` needs more than four lines at the synopsis width, so More is offered only when it reveals something.
    static func isTruncated(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let font = Theme.Font.body
        let height = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
        return height > font.lineHeight * CGFloat(lineLimit) + 1
    }
}
