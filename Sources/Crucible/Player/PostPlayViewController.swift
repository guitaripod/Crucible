import CrucibleCore
import CrucibleDesign
@preconcurrency import UIKit

/// What covers the last frame once a movie, or the last episode of a show, has ended and nothing plays next: titles like it
/// in a row of posters, a button that makes a card of what just ended to share, and a button that closes the player. It is
/// presented over the player rather than drawn inside it, so every tap reaches it instead of the player's own controls.
/// Nothing plays on its own; picking a poster hands the title back.
@MainActor
final class PostPlayViewController: UIViewController, UICollectionViewDelegate {
    private static let posterWidth: CGFloat = 120

    private let heading: String
    private let items: [PlexMetadata]
    private let onPick: (PlexMetadata) -> Void
    private let onShare: (() -> Void)?
    private let onClose: () -> Void
    private var dataSource: UICollectionViewDiffableDataSource<Int, PlexMetadata>?
    private var hasAnswered = false

    init(heading: String, items: [PlexMetadata], onPick: @escaping (PlexMetadata) -> Void, onShare: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        self.heading = heading
        self.items = items
        self.onPick = onPick
        self.onShare = onShare
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "postPlay"
        view.accessibilityViewIsModal = true

        let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        let title = UILabel()
        title.text = heading
        title.font = Theme.Font.title3
        title.textColor = Theme.Color.onArt
        title.numberOfLines = 2
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let close = makeCloseButton()
        let share = makeShareButton()
        let header = UIStackView(arrangedSubviews: [title] + [share].compactMap { $0 } + [close])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Space.m
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.l, bottom: 0, trailing: Theme.Space.l)

        let rail = makeRail()
        let stack = UIStackView(arrangedSubviews: [header, rail])
        stack.axis = .vertical
        stack.spacing = Theme.Space.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let guide = view.safeAreaLayoutGuide
        let centered = stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: Theme.Space.m),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -Theme.Space.m),
            centered,
        ])
        view.accessibilityElements = [title, rail] + [share].compactMap { $0 } + [close]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: heading)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        presentingViewController?.supportedInterfaceOrientations ?? .all
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return }
        Haptics.light()
        answer { onPick(item) }
    }

    /// The first choice wins: a second tap while the screen is going away does nothing.
    private func answer(_ choice: () -> Void) {
        guard !hasAnswered else { return }
        hasAnswered = true
        choice()
    }

    private func makeCloseButton() -> UIButton {
        var config = Glass.glassButton {
            var fallback = UIButton.Configuration.filled()
            fallback.baseBackgroundColor = UIColor.white.withAlphaComponent(0.18)
            return fallback
        }
        config.title = PostPlay.closeTitle
        config.baseForegroundColor = Theme.Color.onArt
        config.cornerStyle = .capsule
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.buttonLabel
            return outgoing
        }
        let button = UIButton(configuration: config)
        button.isPointerInteractionEnabled = true
        button.accessibilityIdentifier = "postPlay.close"
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            answer(onClose)
        }, for: .primaryActionTriggered)
        return button
    }

    /// A glass circle that makes a card of what just ended, when there is something to make one of.
    private func makeShareButton() -> UIButton? {
        guard let onShare else { return nil }
        let button = ThemeButton.icon(symbol: WatchCardScreens.symbol, label: WatchCardScreens.title)
        button.accessibilityIdentifier = "postPlay.share"
        button.addAction(UIAction { [weak self] _ in
            Haptics.light()
            self?.answer(onShare)
        }, for: .primaryActionTriggered)
        return button
    }

    /// One row of posters that scrolls sideways, as tall as a poster and its two caption lines at the current text size.
    private func makeRail() -> UICollectionView {
        let width = Self.posterWidth
        let height = (width * Theme.Size.posterAspect + UIFontMetrics.default.scaledValue(for: Theme.Size.captionBlockHeight)).rounded(.up)
        let size = NSCollectionLayoutSize(widthDimension: .absolute(width), heightDimension: .absolute(height))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Theme.Space.s
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.l, bottom: 0, trailing: Theme.Space.l)
        section.contentInsetsReference = .none
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .horizontal
        let layout = UICollectionViewCompositionalLayout(section: section, configuration: configuration)

        let rail = UICollectionView(frame: .zero, collectionViewLayout: layout)
        rail.backgroundColor = .clear
        rail.showsHorizontalScrollIndicator = false
        rail.alwaysBounceVertical = false
        rail.contentInsetAdjustmentBehavior = .never // duo-audit:ignore the rail's stack is pinned to the safe area guide
        rail.accessibilityIdentifier = "postPlay.rail"
        rail.heightAnchor.constraint(equalToConstant: height).isActive = true
        rail.delegate = self
        rail.allowsKeyboardFocus()

        let registration = UICollectionView.CellRegistration<UICollectionViewCell, PlexMetadata> { cell, _, item in
            cell.contentConfiguration = DetailLayout.posterConfiguration(for: item)
            cell.contentView.accessibilityHint = PostPlay.hint(for: item)
        }
        let dataSource = UICollectionViewDiffableDataSource<Int, PlexMetadata>(collectionView: rail) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, PlexMetadata>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        dataSource.apply(snapshot, animatingDifferences: false)
        self.dataSource = dataSource
        return rail
    }
}
