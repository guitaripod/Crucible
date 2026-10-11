import CrucibleDesign
import UIKit

struct TVSectionHeader: Hashable {
    var title: String
    var secondaryText: String?
    var seeAllAction: (@MainActor () -> Void)?

    init(title: String, secondaryText: String? = nil, seeAllAction: (@MainActor () -> Void)? = nil) {
        self.title = title
        self.secondaryText = secondaryText
        self.seeAllAction = seeAllAction
    }

    static func == (lhs: TVSectionHeader, rhs: TVSectionHeader) -> Bool {
        lhs.title == rhs.title && lhs.secondaryText == rhs.secondaryText && (lhs.seeAllAction == nil) == (rhs.seeAllAction == nil)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(secondaryText)
        hasher.combine(seeAllAction == nil)
    }
}

/// The header above every shelf: a headline title, optional quiet secondary text and an optional
/// "See All" text button, which sits right after the title.
final class TVSectionHeaderView: UICollectionReusableView {
    private let titleLabel = UILabel()
    private let secondaryLabel = UILabel()
    private let seeAllButton = UIButton(type: .system)
    private var seeAllActionIdentifier: UIAction.Identifier?

    override init(frame: CGRect) {
        super.init(frame: frame)
        insetsLayoutMarginsFromSafeArea = false
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: TVMetrics.sectionSpacing, trailing: 0)

        titleLabel.font = Theme.Font.headline
        titleLabel.textColor = Theme.Color.label
        titleLabel.accessibilityTraits = .header
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        secondaryLabel.font = Theme.Font.callout
        secondaryLabel.textColor = Theme.Color.labelSecondary
        seeAllButton.configuration = TVButton.configuration(.plain, title: "See All", symbol: "chevron.right", symbolTrailing: true)
        seeAllButton.accessibilityIdentifier = "tv.sectionHeader.seeAll"

        let row = UIStackView(arrangedSubviews: [titleLabel, secondaryLabel, seeAllButton, UIView()])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.m
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func registration(
        headers: @escaping @MainActor (IndexPath) -> TVSectionHeader?
    ) -> UICollectionView.SupplementaryRegistration<TVSectionHeaderView> {
        UICollectionView.SupplementaryRegistration<TVSectionHeaderView>(elementKind: TVShelf.headerKind) { view, _, indexPath in
            view.configure(headers(indexPath))
        }
    }

    func configure(_ header: TVSectionHeader?) {
        titleLabel.text = header?.title
        secondaryLabel.text = header?.secondaryText
        secondaryLabel.isHidden = (header?.secondaryText ?? "").isEmpty
        seeAllButton.isHidden = header?.seeAllAction == nil
        if let identifier = seeAllActionIdentifier {
            seeAllButton.removeAction(identifiedBy: identifier, for: .primaryActionTriggered)
            seeAllActionIdentifier = nil
        }
        if let action = header?.seeAllAction {
            let seeAll = UIAction { _ in action() }
            seeAllActionIdentifier = seeAll.identifier
            seeAllButton.addAction(seeAll, for: .primaryActionTriggered)
        }
        seeAllButton.accessibilityLabel = header.map { "See all \($0.title)" }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configure(nil)
    }
}
