import CrucibleDesign
import UIKit

/// What a pushed screen's title shows: the title, an optional summary on the same line (a count, a
/// weekly total) and an optional description below.
struct TVScreenTitleContent: Hashable, Sendable {
    var title: String
    var summary: String?
    var detail: String?

    init(title: String, summary: String? = nil, detail: String? = nil) {
        self.title = title
        self.summary = summary
        self.detail = detail
    }

    var spokenText: String {
        [title, summary, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }
}

/// The one title of a pushed screen: title2 with an optional summary on its baseline and an optional
/// description below, limited to a `TVMetrics.Column`, and read by VoiceOver as one header element.
/// Host it as a non-focusable collection cell (`TVScreenTitleView.registration()` with
/// `section()`), as a section header (`headerRegistration()` with `headerItem()`), or put the view
/// anywhere else. With `clearsTabBar` it keeps `TVMetrics.tabBarClearance` free above the title, so
/// every pushed screen starts at the same y under the floating tab bar.
final class TVScreenTitleView: UIView {
    static let headerKind = "tv.screenTitle.header"

    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let detailLabel = UILabel()
    private var content = TVScreenTitleContent(title: "")

    init(clearsTabBar: Bool = true, column: CGFloat = TVMetrics.Column.wide) {
        super.init(frame: .zero)
        titleLabel.font = TVFont.screenTitle
        titleLabel.textColor = Theme.Color.label
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        summaryLabel.font = TVFont.screenSummary
        summaryLabel.textColor = Theme.Color.labelSecondary
        summaryLabel.adjustsFontSizeToFitWidth = true
        summaryLabel.minimumScaleFactor = 0.8
        detailLabel.font = TVFont.screenDetail
        detailLabel.textColor = Theme.Color.labelSecondary
        detailLabel.numberOfLines = 0

        let line = UIStackView(arrangedSubviews: [titleLabel, summaryLabel, UIView()])
        line.axis = .horizontal
        line.alignment = .lastBaseline
        line.spacing = Theme.Space.m

        let stack = UIStackView(arrangedSubviews: [line, detailLabel])
        stack.axis = .vertical
        stack.spacing = Theme.Space.s
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: clearsTabBar ? TVMetrics.tabBarClearance : 0),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Space.xs),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: column),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ content: TVScreenTitleContent) {
        self.content = content
        titleLabel.text = content.title
        summaryLabel.text = content.summary
        summaryLabel.isHidden = (content.summary ?? "").isEmpty
        detailLabel.text = content.detail
        detailLabel.isHidden = (content.detail ?? "").isEmpty
        accessibilityLabel = content.spokenText
    }

    override var canBecomeFocused: Bool { false }

    /// A non-focusable cell hosting the title; the identifier of the cell is `tv.screenTitle`.
    static func registration(clearsTabBar: Bool = true, column: CGFloat = TVMetrics.Column.wide) -> UICollectionView.CellRegistration<TVHostCell, TVScreenTitleContent> {
        TVHostCell.registration { (content: TVScreenTitleContent) -> UIView in
            let view = TVScreenTitleView(clearsTabBar: clearsTabBar, column: column)
            view.configure(content)
            return view
        }
    }

    /// A full-width section for the title cell; the cell sizes itself to its text.
    static func section(clearsTabBar: Bool = true) -> NSCollectionLayoutSection {
        let height = NSCollectionLayoutDimension.estimated((clearsTabBar ? TVMetrics.tabBarClearance : 0) + 100)
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: height)
        let item = NSCollectionLayoutItem(layoutSize: size)
        let section = NSCollectionLayoutSection(group: NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item]))
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: TVMetrics.shelfTopInset, trailing: 0)
        return section
    }

    /// The title as a section header: attach `headerItem()` to a section's `boundarySupplementaryItems`.
    static func headerRegistration(
        clearsTabBar: Bool = true,
        content: @escaping @MainActor (IndexPath) -> TVScreenTitleContent?
    ) -> UICollectionView.SupplementaryRegistration<TVScreenTitleHeaderView> {
        UICollectionView.SupplementaryRegistration<TVScreenTitleHeaderView>(elementKind: headerKind) { header, _, indexPath in
            header.configure(content(indexPath), clearsTabBar: clearsTabBar)
        }
    }

    static func headerItem(clearsTabBar: Bool = true) -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated((clearsTabBar ? TVMetrics.tabBarClearance : 0) + 100)
            ),
            elementKind: headerKind,
            alignment: .top
        )
    }
}

/// The supplementary view that hosts a `TVScreenTitleView`.
final class TVScreenTitleHeaderView: UICollectionReusableView {
    private var title: TVScreenTitleView?

    func configure(_ content: TVScreenTitleContent?, clearsTabBar: Bool) {
        title?.removeFromSuperview()
        guard let content else {
            title = nil
            return
        }
        let view = TVScreenTitleView(clearsTabBar: clearsTabBar)
        view.configure(content)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        title = view
    }
}
