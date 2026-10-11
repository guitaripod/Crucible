#if DEBUG
import CrucibleDesign
import UIKit

/// `CRUCIBLE_GALLERY=images`: three posters and a backdrop whose first load fails. Play/Pause reloads
/// the same items and the same backdrop path, which must now succeed. A second Play/Pause shows a poster as
/// the backdrop, whose request must stay poster-sized. The request log on screen shows what was asked for.
final class TVGalleryImagesViewController: TVScreenViewController {
    private let backdrop = TVBackdropView()
    private let logLabel = UILabel()
    private var dataSource: UICollectionViewDiffableDataSource<Int, TVCardItem>!
    private var presses = 0
    private lazy var logSlot = makeTaskSlot()

    private let items = ["dawn", "dusk", "noon"].map {
        TVCardItem(id: "flaky.\($0)", artworkPath: "\(TVGalleryArt.scheme)flaky-poster/\($0)", title: $0.capitalized, subtitle: "Flaky")
    }

    init() {
        super.init(layout: UICollectionViewLayout())
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, _ in
            let section = TVShelf.poster(header: false)
            section.contentInsets = NSDirectionalEdgeInsets(top: 300, leading: 0, bottom: TVMetrics.shelfBottomInset, trailing: 0)
            return section
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
        logLabel.font = TVFont.mono(size: 23)
        logLabel.textColor = Theme.Color.label
        logLabel.numberOfLines = 0
        logLabel.accessibilityIdentifier = "images.log"
        logLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(logLabel)
        NSLayoutConstraint.activate([
            logLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            logLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            logLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 1200),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        TVImagePipeline.provider = TVGalleryArt.provider
        let poster = TVPosterCell.registration()
        dataSource = UICollectionViewDiffableDataSource<Int, TVCardItem>(collectionView: collectionView) { collectionView, indexPath, item in
            let cell = collectionView.dequeueConfiguredReusableCell(using: poster, for: indexPath, item: item)
            cell.accessibilityIdentifier = "images.card.\(indexPath.item)"
            return cell
        }
        adopt(dataSource)
        applyItems()
        backdrop.show(path: "\(TVGalleryArt.scheme)flaky-backdrop/dawn", immediate: true)
        refreshLog()
    }

    override func playFocused(at indexPath: IndexPath) -> Bool {
        presses += 1
        applyItems()
        if presses == 1 {
            backdrop.show(path: "\(TVGalleryArt.scheme)flaky-backdrop/dawn", immediate: true)
        } else {
            backdrop.show(path: "\(TVGalleryArt.scheme)poster/solo", kind: .poster, immediate: true)
        }
        refreshLog()
        return true
    }

    private func applyItems() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, TVCardItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        dataSource.applyReconfiguringExisting(snapshot)
    }

    private func refreshLog() {
        logSlot.run { [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            let lines = await TVGalleryRequests.shared.lines
            self?.logLabel.text = lines.suffix(8).joined(separator: "\n")
        }
    }
}
#endif
