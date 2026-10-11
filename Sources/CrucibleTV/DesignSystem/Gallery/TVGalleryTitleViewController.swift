#if DEBUG
import CrucibleDesign
import UIKit

/// `CRUCIBLE_GALLERY=title-cell|title-header`: the pushed-screen title hosted as a collection cell
/// (with a summary beside it) or as a section header (with a description below), above a poster shelf
/// that starts where a real pushed screen's first row starts.
final class TVGalleryTitleViewController: TVScreenViewController {
    private let usesHeader: Bool
    private var dataSource: UICollectionViewDiffableDataSource<Int, TVCardItem>!

    init(usesHeader: Bool) {
        self.usesHeader = usesHeader
        super.init(layout: UICollectionViewLayout())
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { [usesHeader] index, _ in
            if usesHeader {
                let section = TVShelf.poster(header: false)
                section.boundarySupplementaryItems = [TVScreenTitleView.headerItem()]
                return section
            }
            return index == 0 ? TVScreenTitleView.section() : TVShelf.poster(header: false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        TVImagePipeline.provider = TVGalleryArt.provider
        let poster = TVPosterCell.registration()
        let title = TVScreenTitleView.registration()
        let header = TVScreenTitleView.headerRegistration { _ in
            TVScreenTitleContent(
                title: "Genre: Documentary",
                summary: "94 titles",
                detail: "Everything in your libraries filed under Documentary, newest first."
            )
        }
        let usesHeader = usesHeader
        dataSource = UICollectionViewDiffableDataSource<Int, TVCardItem>(collectionView: collectionView) { collectionView, indexPath, item in
            if !usesHeader, indexPath.section == 0 {
                let cell = collectionView.dequeueConfiguredReusableCell(
                    using: title,
                    for: indexPath,
                    item: TVScreenTitleContent(title: "Watch History", summary: "12 plays this week · 8h 40m")
                )
                cell.accessibilityIdentifier = "title.cell"
                return cell
            }
            let cell = collectionView.dequeueConfiguredReusableCell(using: poster, for: indexPath, item: item)
            cell.accessibilityIdentifier = "title.poster.\(indexPath.item)"
            return cell
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, TVCardItem>()
        if usesHeader {
            snapshot.appendSections([0])
            snapshot.appendItems(TVGalleryFixtures.posters, toSection: 0)
        } else {
            snapshot.appendSections([0, 1])
            snapshot.appendItems([TVCardItem(id: "title", title: "")], toSection: 0)
            snapshot.appendItems(TVGalleryFixtures.posters, toSection: 1)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        adopt(dataSource)
    }
}

/// `CRUCIBLE_GALLERY=panel`: a read-only panel above a button. The panel is a focus stop only while
/// VoiceOver runs (or `CRUCIBLE_VOICEOVER=1` forces it), so a sighted user never meets a dead stop.
final class TVGalleryPanelViewController: UIViewController {
    private let button = TVButton.make(.primary, title: "Open Account", symbol: "person.crop.circle")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.canvas
        let lines = ["Marcus", "Local · Marcus-PC", "Plex Pass"].map { text -> UILabel in
            let label = UILabel()
            label.text = text
            label.font = TVFont.control
            label.textColor = Theme.Color.label
            return label
        }
        let stack = UIStackView(arrangedSubviews: lines)
        stack.axis = .vertical
        stack.spacing = Theme.Space.xs
        let panel = TVReadOnlyPanel(wrapping: stack) { "Marcus, connected locally to Marcus-PC, Plex Pass" }
        panel.accessibilityIdentifier = "panel.readonly"
        button.accessibilityIdentifier = "panel.button"

        let column = UIStackView(arrangedSubviews: [panel, button])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = TVMetrics.gutter + Theme.Space.l
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Space.l),
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: TVMetrics.tabBarClearance),
        ])
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { [button] }
}
#endif
