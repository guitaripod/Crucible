import CrucibleCore
import CrucibleDesign
import UIKit

/// The split layout of the You tab and every settings sub-screen: a context column on the left
/// (who or what this screen is about) and a list of `TVRowItem`s on the right, the way Apple TV's own
/// Settings and Library screens are laid out. It is a `TVScreenViewController`, so loading, empty and
/// error states, focus memory and Back-while-loading come from the shared host. Subclasses fill the
/// context column (`installContext(_:)`, `installHeading(_:)`), call `setRows(_:)` and override
/// `rowDidSelect(_:)`.
class TVSettingsScaffold: TVScreenViewController {
    enum Layout {
        static let contextWidth: CGFloat = 640
        static let columnGap: CGFloat = 100
        static let contentTop = TVMetrics.tabBarClearance
    }

    let contextColumn = UIView()
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var items: [String: TVRowItem] = [:]

    init() {
        super.init(layout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        configureDataSource()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = TVMetrics.tabBarClearance - TVMetrics.shelfVerticalInset
        let bottom = TVMetrics.topInset - TVMetrics.shelfVerticalInset
        if collectionView.contentInset.top != top || collectionView.contentInset.bottom != bottom {
            collectionView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        }
    }

    override func installViews() {
        super.installViews()
        contextColumn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contextColumn)
        NSLayoutConstraint.activate([
            contextColumn.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            contextColumn.widthAnchor.constraint(equalToConstant: Layout.contextWidth),
            contextColumn.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.contentTop),
            contextColumn.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -TVMetrics.topInset),
        ])
    }

    func setRows(_ rows: [TVRowItem]) {
        loadViewIfNeeded()
        let rows = rows.uniqued(by: \.id)
        items = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.id))
        dataSource.applyReconfiguringExisting(snapshot)
    }

    /// Replaces the list with a loading, empty or error state, or brings the list back with nil. The
    /// context column steps aside while a state shows, because a state fills the whole screen.
    func presentState(_ state: TVStateView.State?) {
        loadViewIfNeeded()
        contextColumn.isHidden = state != nil
        if let state {
            show(state: state)
        } else {
            showContent()
        }
    }

    /// The row that takes the focus when the screen appears; nil lets the system pick the first.
    var preferredFocusRowID: String? { nil }

    override func initialFocusIndexPath() -> IndexPath? {
        preferredFocusRowID.flatMap { dataSource.indexPath(for: $0) }
    }

    /// Puts `content` in the context column, top-aligned and as tall as it needs to be, so the
    /// column's accessibility frame covers it.
    func installContext(_ content: UIView) {
        loadViewIfNeeded()
        content.translatesAutoresizingMaskIntoConstraints = false
        contextColumn.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contextColumn.topAnchor),
            content.leadingAnchor.constraint(equalTo: contextColumn.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contextColumn.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: contextColumn.bottomAnchor),
        ])
    }

    func installHeading(_ heading: TVSettingsHeading) {
        installContext(heading)
    }

    func rowDidSelect(_ id: String) {}

    func rowDidFocus(_ id: String?) {}

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, environment in
            let section = TVRowList.section(environment: environment)
            let safe = self?.view.safeAreaInsets ?? .zero
            section.contentInsets.leading = safe.left + Layout.contextWidth + Layout.columnGap
            section.contentInsets.trailing = safe.right
            return section
        }
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<TVRowCell, String> { [weak self] cell, _, id in
            guard let item = self?.items[id] else { return }
            cell.configure(with: item)
            cell.accessibilityIdentifier = id
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        adopt(dataSource)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), items[id]?.isEnabled ?? false else { return }
        rowDidSelect(id)
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.collectionView(collectionView, didUpdateFocusIn: context, with: coordinator)
        rowDidFocus(context.nextFocusedIndexPath.flatMap { dataSource.itemIdentifier(for: $0) })
    }
}

/// The title of a settings sub-screen with its description, as one VoiceOver-readable panel in the
/// context column (a `TVScreenTitleView` inside a `TVReadOnlyPanel`).
final class TVSettingsHeading: TVReadOnlyPanel {
    private let titleView = TVScreenTitleView(clearsTabBar: false, column: TVSettingsScaffold.Layout.contextWidth)
    private var content: TVScreenTitleContent

    init(title: String, body: String? = nil) {
        content = TVScreenTitleContent(title: title, detail: body)
        super.init(frame: .zero)
        titleView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleView)
        NSLayoutConstraint.activate([
            titleView.topAnchor.constraint(equalTo: contentView.topAnchor),
            titleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            titleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            titleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        spokenLabel = { [weak self] in self?.content.spokenText }
        accessibilityIdentifier = "settings.context"
        titleView.configure(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setBody(_ body: String?) {
        content.detail = body
        titleView.configure(content)
    }
}
