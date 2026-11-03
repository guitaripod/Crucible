import CrucibleCore
import CrucibleDesign
import UIKit

/// The end of a movie, or of a show's last episode, on Apple TV: titles like it over the blurred last frame, the same choice
/// the iPhone offers. Select plays a movie in the same player or opens a show; Close and Menu close the player. Nothing
/// plays on its own.
@MainActor
final class TVPostPlayViewController: UIViewController, UICollectionViewDelegate {
    var onPick: ((PlexMetadata) -> Void)?
    var onClose: (() -> Void)?

    private let heading: String
    private let items: [PlexMetadata]
    private let itemsByCard: [String: PlexMetadata]
    private let collectionView = TVCollectionView(frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout { _, _ in
        TVShelf.poster(header: false)
    })
    private var dataSource: UICollectionViewDiffableDataSource<Int, TVCardItem>?
    private var hasAnswered = false

    init(heading: String, items: [PlexMetadata]) {
        self.heading = heading
        self.items = items
        let cards = TVDetailMapping.related(items)
        itemsByCard = Dictionary(zip(cards.map(\.id), items), uniquingKeysWith: { first, _ in first })
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "postPlay"
        overrideUserInterfaceStyle = .dark

        let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        let title = UILabel()
        title.text = heading
        title.font = Theme.Font.title2
        title.textColor = Theme.Color.onArt
        title.numberOfLines = 2
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header

        configureShelf()
        let close = TVButton.make(.glass, title: PostPlay.closeTitle, symbol: "xmark") { [weak self] in self?.close() }
        close.accessibilityIdentifier = "postPlay.close"
        let closeRow = UIStackView(arrangedSubviews: [close, UIView()])
        closeRow.axis = .horizontal

        let stack = UIStackView(arrangedSubviews: [title, collectionView, closeRow])
        stack.axis = .vertical
        stack.spacing = TVMetrics.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let guide = view.safeAreaLayoutGuide
        let shelfHeight = TVCardStyle.poster.itemSize.height + TVMetrics.shelfTopInset + TVMetrics.shelfBottomInset
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            collectionView.heightAnchor.constraint(equalToConstant: shelfHeight),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: heading)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [collectionView]
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.contains(where: { $0.type == .menu }) else {
            super.pressesBegan(presses, with: event)
            return
        }
        close()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard !hasAnswered, let card = dataSource?.itemIdentifier(for: indexPath), let item = itemsByCard[card.id] else { return }
        hasAnswered = true
        onPick?(item)
    }

    private func close() {
        guard !hasAnswered else { return }
        hasAnswered = true
        onClose?()
    }

    private func configureShelf() {
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "postPlay.shelf"
        let poster = TVPosterCell.registration()
        let dataSource = UICollectionViewDiffableDataSource<Int, TVCardItem>(collectionView: collectionView) { collectionView, indexPath, card in
            let cell = collectionView.dequeueConfiguredReusableCell(using: poster, for: indexPath, item: card)
            cell.accessibilityIdentifier = "postPlay.item.\(indexPath.item)"
            return cell
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, TVCardItem>()
        snapshot.appendSections([0])
        snapshot.appendItems(TVDetailMapping.related(items).map { card in
            var card = card
            card.accessibilityHint = itemsByCard[card.id].map(PostPlay.hint(for:))
            return card
        })
        dataSource.apply(snapshot, animatingDifferences: false)
        self.dataSource = dataSource
    }
}
