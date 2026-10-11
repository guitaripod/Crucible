import CrucibleCore
import CrucibleDesign
import UIKit

/// The split layout of the You tab and every settings sub-screen: a context column on the left
/// (who or what this screen is about) and a list of `TVRowItem`s on the right, the way Apple TV's own
/// Settings and Library screens are laid out. Subclasses fill `contextColumn`, call `setRows(_:)`
/// and override `rowDidSelect(_:)`; Back pops through the navigation controller.
class TVSettingsScaffold: UIViewController, UICollectionViewDelegate {
    enum Layout {
        static let contextWidth: CGFloat = 640
        static let columnGap: CGFloat = 100
        static let contentTop: CGFloat = 150
        static let contentBottom: CGFloat = 60
    }

    let contextColumn = UIView()
    private(set) lazy var collectionView = TVCollectionView(frame: .zero, collectionViewLayout: TVRowList.layout())
    private let stateView = TVStateView()
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var items: [String: TVRowItem] = [:]
    private var isShowingState = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        buildHierarchy()
        configureDataSource()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = Layout.contentTop - TVMetrics.shelfVerticalInset
        let bottom = Layout.contentBottom - TVMetrics.shelfVerticalInset
        if collectionView.contentInset.top != top || collectionView.contentInset.bottom != bottom {
            collectionView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        }
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        isShowingState ? [stateView] : [collectionView]
    }

    func setRows(_ rows: [TVRowItem]) {
        loadViewIfNeeded()
        let rows = rows.uniqued(by: \.id)
        let previous = items
        items = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map(\.id))
        let changed = rows.map(\.id).filter { previous[$0] != nil && previous[$0] != items[$0] }
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func row(withID id: String) -> TVRowItem? {
        items[id]
    }

    /// Replaces the list with a loading, empty or error state, or brings the list back with nil.
    func showState(_ state: TVStateView.State?) {
        loadViewIfNeeded()
        isShowingState = state != nil
        stateView.isHidden = state == nil
        collectionView.isHidden = state != nil
        if let state { stateView.show(state) }
        setNeedsFocusUpdate()
    }

    /// The row that takes the focus when the screen appears; nil lets the system pick the first.
    var preferredFocusRowID: String? { nil }

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

    /// Puts a heading in the context column as one VoiceOver-readable panel.
    func installHeading(_ heading: TVSettingsHeadingView) {
        let panel = TVReadOnlyPanel(wrapping: heading) { [weak heading] in heading?.spokenText }
        panel.accessibilityIdentifier = "settings.context"
        installContext(panel)
    }

    func rowDidSelect(_ id: String) {}

    func rowDidFocus(_ id: String?) {}

    private func buildHierarchy() {
        contextColumn.translatesAutoresizingMaskIntoConstraints = false
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.delegate = self
        collectionView.backgroundColor = .clear
        stateView.translatesAutoresizingMaskIntoConstraints = false
        stateView.isHidden = true
        view.addSubview(collectionView)
        view.addSubview(stateView)
        view.addSubview(contextColumn)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            contextColumn.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            contextColumn.widthAnchor.constraint(equalToConstant: Layout.contextWidth),
            contextColumn.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.contentTop),
            contextColumn.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -Layout.contentBottom),
            collectionView.leadingAnchor.constraint(equalTo: contextColumn.trailingAnchor, constant: Layout.columnGap),
            collectionView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: contextColumn.trailingAnchor, constant: Layout.columnGap),
            stateView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), items[id]?.isEnabled ?? false else { return }
        rowDidSelect(id)
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        preferredFocusRowID.flatMap { dataSource.indexPath(for: $0) }
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        rowDidFocus(context.nextFocusedIndexPath.flatMap { dataSource.itemIdentifier(for: $0) })
    }
}

/// A large title with a paragraph under it: the heading of a settings sub-screen's context column.
final class TVSettingsHeadingView: UIStackView {
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()

    init(title: String, body: String? = nil) {
        super.init(frame: .zero)
        axis = .vertical
        spacing = Theme.Space.s
        titleLabel.font = Theme.Font.title2
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityTraits = .header
        bodyLabel.font = Theme.Font.body
        bodyLabel.textColor = Theme.Color.labelSecondary
        bodyLabel.numberOfLines = 0
        addArrangedSubview(titleLabel)
        addArrangedSubview(bodyLabel)
        titleLabel.text = title
        setBody(body)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    var spokenText: String {
        [titleLabel.text, bodyLabel.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    func setBody(_ body: String?) {
        bodyLabel.text = body
        bodyLabel.isHidden = (body ?? "").isEmpty
    }
}
