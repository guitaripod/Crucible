#if DEBUG
import CrucibleDesign
import UIKit

/// `CRUCIBLE_GALLERY=hero-short|hero-long|hero-title1`: the hero info block over a backdrop with a
/// shelf below it, laid out like Home. `hero-long` is the worst case: a two-line title, facts, badges,
/// a long synopsis and a progress bar, which must fit the 420pt hero block without overlapping the shelf.
final class TVGalleryHeroViewController: TVScreenViewController {
    private let info: TVHeroInfo
    private let backdrop = TVBackdropView()
    private var dataSource: UICollectionViewDiffableDataSource<Int, TVCardItem>!

    init(mode: String) {
        info = Self.info(for: mode)
        super.init(layout: UICollectionViewLayout())
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { index, _ in
            guard index == 0 else { return TVShelf.poster() }
            let hero = TVShelf.hero()
            hero.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.topInset + 40, leading: 0, bottom: 0, trailing: 0)
            return hero
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func info(for mode: String) -> TVHeroInfo {
        let short = TVHeroInfo(
            eyebrow: "Continue Watching",
            title: "Salt Flats",
            metaParts: ["2024", "PG-13", "1h 58m", "★ 7.4"],
            badges: ["4K", "Dolby Vision", "Atmos"],
            synopsis: "Two surveyors cross the world's brightest desert to map a lake that is no longer there.",
            progress: 0.38
        )
        let long = TVHeroInfo(
            eyebrow: "Continue Watching",
            title: "The Extraordinarily Long and Winding Journey of the Last Lighthouse Keeper",
            metaParts: ["2024", "PG-13", "1h 58m", "★ 7.4"],
            badges: ["4K", "Dolby Vision", "Atmos"],
            synopsis: "Two surveyors cross the world's brightest desert to map a lake that is no longer there, and discover who has been moving the horizon, one salt pan at a time, for longer than anyone alive can remember.",
            progress: 0.38
        )
        switch mode {
        case "hero-long": return long
        case "hero-title1":
            var detail = long
            detail.titleStyle = .title1
            return detail
        default: return short
        }
    }

    override func installViews() {
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        super.installViews()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        TVImagePipeline.provider = TVGalleryArt.provider
        let info = info
        let hero = TVHeroCell.registration {
            $0.accessibilityIdentifier = "hero.info"
            $0.configure(info)
        }
        let poster = TVPosterCell.registration()
        dataSource = UICollectionViewDiffableDataSource<Int, TVCardItem>(collectionView: collectionView) { collectionView, indexPath, item in
            if indexPath.section == 0 {
                let cell = collectionView.dequeueConfiguredReusableCell(using: hero, for: indexPath, item: 0)
                cell.accessibilityIdentifier = "hero.cell"
                return cell
            }
            let cell = collectionView.dequeueConfiguredReusableCell(using: poster, for: indexPath, item: item)
            cell.accessibilityIdentifier = "hero.poster.\(indexPath.item)"
            return cell
        }
        let header = TVSectionHeaderView.registration { _ in TVSectionHeader(title: "Recently Added") }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, TVCardItem>()
        snapshot.appendSections([0, 1])
        snapshot.appendItems([TVCardItem(id: "hero", title: "")], toSection: 0)
        snapshot.appendItems(TVGalleryFixtures.posters, toSection: 1)
        dataSource.apply(snapshot, animatingDifferences: false)
        adopt(dataSource)
        backdrop.show(path: TVGalleryFixtures.continueWatching[1].backdropPath)
    }
}
#endif
