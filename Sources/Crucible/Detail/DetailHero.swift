@preconcurrency import UIKit

/// Full-bleed artwork that lives in the collection view's `backgroundView`, behind clear cells.
/// It never scrolls itself: `update(restHeight:scrolled:)` clips it to the hero cell's current
/// bottom edge, stretches it on pull-down and parallaxes/dims it on scroll, so the canvas below the
/// hero always backs the content that scrolls over it.
final class DetailBackdropView: UIView {
    private let container = UIView()
    private let imageView = UIImageView()
    private let dimView = UIView()
    private let topScrim = CAGradientLayer()
    private let bottomFade = CAGradientLayer()
    private var imageTask: Task<Void, Never>?
    private var currentPath: String?
    private var restHeight: CGFloat = 0
    private var scrolled: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.canvas
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true

        container.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = Theme.Color.surfaceRaised
        dimView.backgroundColor = Theme.Color.canvas
        dimView.alpha = 0

        container.addSubview(imageView)
        container.addSubview(dimView)
        container.layer.addSublayer(topScrim)
        container.layer.addSublayer(bottomFade)
        addSubview(container)

        topScrim.colors = [UIColor.black.withAlphaComponent(0.45).cgColor, UIColor.black.withAlphaComponent(0).cgColor]
        updateFadeColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DetailBackdropView, _: UITraitCollection) in
            view.updateFadeColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    /// `restHeight` is the hero's bottom edge (in visible coordinates) when the content sits at rest;
    /// `scrolled` is how far the content moved up from rest (negative while pulling down).
    func update(restHeight: CGFloat, scrolled: CGFloat) {
        self.restHeight = max(0, restHeight)
        self.scrolled = scrolled
        layoutHero()
    }

    func loadImage(path: String?, isBackdrop: Bool, offlineRatingKey: String?) {
        let key = path ?? offlineRatingKey.map { "offline:\($0)" }
        guard key != currentPath || (imageView.image == nil && imageTask == nil) else { return }
        currentPath = key
        imageTask?.cancel()
        imageTask = Task { [weak self] in
            defer { self?.finishImageTask(for: key) }
            var image: UIImage?
            if let path, !path.isEmpty {
                image = isBackdrop
                    ? await ImageLoader.shared.loadBackdrop(path: path, width: 1280)
                    : await ImageLoader.shared.loadImage(path: path, width: 720)
            }
            if image == nil, let offlineRatingKey {
                image = await OfflinePoster.image(ratingKey: offlineRatingKey)
            }
            guard !Task.isCancelled, let self, let image else { return }
            let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.3
            UIView.transition(with: self.imageView, duration: duration, options: .transitionCrossDissolve) {
                self.imageView.image = image
            }
        }
    }

    private func finishImageTask(for key: String?) {
        guard key == currentPath else { return }
        imageTask = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutHero()
    }

    private func layoutHero() {
        let width = bounds.width
        let heroBottom = max(0, restHeight - scrolled)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = CGRect(x: 0, y: 0, width: width, height: heroBottom)
        if scrolled >= 0 {
            let shift = reduceMotion ? scrolled : scrolled * 0.5
            imageView.frame = CGRect(x: 0, y: -shift, width: width, height: restHeight)
            dimView.alpha = reduceMotion ? 0 : min(0.6, scrolled / max(restHeight, 1) * 0.9)
        } else {
            imageView.frame = CGRect(x: 0, y: 0, width: width, height: restHeight - scrolled)
            dimView.alpha = 0
        }
        dimView.frame = container.bounds
        topScrim.frame = CGRect(x: 0, y: 0, width: width, height: restHeight * 0.26)
        let fadeHeight = restHeight * 0.74
        bottomFade.frame = CGRect(x: 0, y: heroBottom - fadeHeight, width: width, height: fadeHeight)
        CATransaction.commit()
    }

    private func updateFadeColors() {
        let canvas = Theme.Color.canvas.resolvedColor(with: traitCollection)
        backgroundColor = Theme.Color.canvas
        bottomFade.colors = [
            canvas.withAlphaComponent(0).cgColor,
            canvas.withAlphaComponent(0.35).cgColor,
            canvas.withAlphaComponent(0.82).cgColor,
            canvas.cgColor,
        ]
        bottomFade.locations = [0, 0.4, 0.75, 1]
    }
}

/// Hero overlay that sits over the bottom of the artwork: eyebrow, title, meta line and badges.
/// The cell itself is transparent; its minimum height reserves the artwork area below the bar.
struct DetailHeroConfiguration: UIContentConfiguration {
    var eyebrow: String = ""
    var title: String = ""
    var meta: NSAttributedString?
    var badges: [String] = []
    var minimumHeight: CGFloat = 0
    var accessibilityText: String = ""

    func makeContentView() -> UIView & UIContentView {
        DetailHeroContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> DetailHeroConfiguration {
        self
    }
}

final class DetailHeroContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    let titleLabel = UILabel()
    private let eyebrowLabel = UILabel()
    private let metaLabel = UILabel()
    private let badgeHost = UIView()
    private var badgeRow: UIStackView?
    private var appliedBadges: [String]?
    private let stack = UIStackView()
    private var minimumHeightConstraint: NSLayoutConstraint!

    init(configuration: DetailHeroConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)

        eyebrowLabel.adjustsFontForContentSizeCategory = true
        eyebrowLabel.numberOfLines = 1

        titleLabel.font = Theme.Font.detailTitle
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail

        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.numberOfLines = 0

        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 2
        stack.addArrangedSubview(eyebrowLabel)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(metaLabel)
        stack.addArrangedSubview(badgeHost)
        stack.setCustomSpacing(12, after: metaLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        minimumHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        minimumHeightConstraint.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.m),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Theme.Space.xs),
            minimumHeightConstraint,
        ])

        isAccessibilityElement = true
        accessibilityTraits = .header
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let config = configuration as? DetailHeroConfiguration else { return }
        eyebrowLabel.attributedText = DetailFormat.eyebrow(config.eyebrow, color: Theme.Color.accentText)
        eyebrowLabel.isHidden = config.eyebrow.isEmpty
        titleLabel.text = config.title
        metaLabel.attributedText = config.meta
        metaLabel.isHidden = (config.meta?.length ?? 0) == 0
        minimumHeightConstraint.constant = config.minimumHeight
        applyBadges(config.badges)
        accessibilityLabel = config.accessibilityText
    }

    private func applyBadges(_ badges: [String]) {
        guard badges != appliedBadges else { return }
        appliedBadges = badges
        badgeRow?.removeFromSuperview()
        badgeRow = nil
        badgeHost.isHidden = badges.isEmpty
        guard !badges.isEmpty else { return }
        let row = BadgeChipView.row(badges)
        row.translatesAutoresizingMaskIntoConstraints = false
        badgeHost.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: badgeHost.topAnchor),
            row.leadingAnchor.constraint(equalTo: badgeHost.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: badgeHost.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: badgeHost.bottomAnchor),
        ])
        badgeRow = row
    }
}

/// Owns the sticky navigation state: a transparent bar over the artwork that gains the title and a
/// small ember play button once the hero title has scrolled under it.
@MainActor
final class DetailNavigationChrome {
    let playItem: UIBarButtonItem
    private let titleLabel = UILabel()
    private let playButton: UIButton
    private weak var navigationItem: UINavigationItem?
    private var progress: CGFloat = -1
    private var isCollapsed: Bool?
    private var isPlayAvailable = true

    init(navigationItem: UINavigationItem, onPlay: @escaping () -> Void) {
        self.navigationItem = navigationItem

        titleLabel.font = Theme.Font.headline
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.maximumContentSizeCategory = .accessibilityMedium
        titleLabel.textColor = Theme.Color.label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.alpha = 0
        titleLabel.accessibilityTraits = .header

        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = Theme.Color.accent
        config.baseForegroundColor = Theme.Color.onAccent
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        config.image = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        playButton = UIButton(configuration: config)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playButton.widthAnchor.constraint(equalToConstant: 32),
            playButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        playButton.accessibilityLabel = "Play"
        playButton.alpha = 0
        playButton.addAction(UIAction { _ in
            Haptics.light()
            onPlay()
        }, for: .primaryActionTriggered)

        playItem = UIBarButtonItem(customView: playButton)
        #if os(iOS)
        if #available(iOS 26.0, *) {
            playItem.hidesSharedBackground = true
        }
        #endif

        navigationItem.titleView = titleLabel
        navigationItem.largeTitleDisplayMode = .never
        update(progress: 0)
    }

    func setTitle(_ title: String) {
        titleLabel.text = title
        titleLabel.sizeToFit()
    }

    func setPlay(label: String, available: Bool) {
        playButton.accessibilityLabel = label
        isPlayAvailable = available
        let current = progress
        progress = -1
        update(progress: max(0, current))
    }

    func update(progress newValue: CGFloat) {
        let clamped = min(1, max(0, newValue))
        guard abs(clamped - progress) > 0.001 else { return }
        progress = clamped
        titleLabel.alpha = clamped
        playButton.alpha = isPlayAvailable ? clamped : 0
        let interactive = clamped > 0.6 && isPlayAvailable
        playButton.isUserInteractionEnabled = interactive
        playButton.accessibilityElementsHidden = !interactive
        titleLabel.accessibilityElementsHidden = clamped < 0.6
        applyAppearance(collapsed: clamped > 0.6)
    }

    /// Before iOS 26 the bar draws its own material; keep it transparent over the artwork and only
    /// bring the material back once the title has docked into the bar.
    private func applyAppearance(collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        if #available(iOS 26.0, tvOS 26.0, *) { return }
        let appearance = UINavigationBarAppearance()
        if collapsed {
            appearance.configureWithDefaultBackground()
        } else {
            appearance.configureWithTransparentBackground()
        }
        navigationItem?.standardAppearance = appearance
        navigationItem?.scrollEdgeAppearance = appearance
        navigationItem?.compactAppearance = appearance
        navigationItem?.compactScrollEdgeAppearance = appearance
    }
}

/// Glue between a detail collection view, its backdrop and its sticky navigation chrome. The hero is
/// always item 0 of section 0.
@MainActor
final class DetailHeroCoordinator {
    let backdrop = DetailBackdropView()
    let chrome: DetailNavigationChrome
    private let heightRatio: CGFloat
    private(set) var minimumHeroCellHeight: CGFloat = 0

    init(navigationItem: UINavigationItem, heightRatio: CGFloat, onPlay: @escaping () -> Void) {
        self.heightRatio = heightRatio
        chrome = DetailNavigationChrome(navigationItem: navigationItem, onPlay: onPlay)
    }

    func install(on collectionView: UICollectionView) {
        collectionView.backgroundColor = .clear
        collectionView.backgroundView = backdrop
        minimumHeroCellHeight = computedMinimumHeroCellHeight(collectionView)
    }

    func restHeight(for collectionView: UICollectionView) -> CGFloat {
        let size = collectionView.bounds.size
        guard size.width > 0 else { return 0 }
        let byWidth = size.width * heightRatio
        let byHeight = size.height * 0.68
        return floor(min(byWidth, byHeight))
    }

    /// True when the hero cell's reserved height changed (rotation, bar height) and the hero item
    /// must be reconfigured.
    func refreshMinimumHeight(_ collectionView: UICollectionView) -> Bool {
        let value = computedMinimumHeroCellHeight(collectionView)
        guard abs(value - minimumHeroCellHeight) > 0.5 else { return false }
        minimumHeroCellHeight = value
        return true
    }

    func scrolled(_ collectionView: UICollectionView) {
        let top = collectionView.adjustedContentInset.top
        let offset = collectionView.contentOffset.y
        let delta = offset + top
        let heroIndexPath = IndexPath(item: 0, section: 0)
        let hasHero = collectionView.numberOfSections > 0 && collectionView.numberOfItems(inSection: 0) > 0
        var rest = restHeight(for: collectionView)
        if hasHero, let attributes = collectionView.layoutAttributesForItem(at: heroIndexPath) {
            rest = attributes.frame.maxY + top
        }
        backdrop.update(restHeight: rest, scrolled: delta)

        var progress: CGFloat = 0
        if hasHero {
            if let titleFrame = heroTitleFrame(in: collectionView, at: heroIndexPath) {
                let titleBottom = titleFrame.maxY - offset
                progress = (top + 20 - titleBottom) / 28
            } else if delta > rest * 0.5 {
                progress = 1
            }
        }
        chrome.update(progress: progress)
    }

    private func computedMinimumHeroCellHeight(_ collectionView: UICollectionView) -> CGFloat {
        max(160, restHeight(for: collectionView) - collectionView.adjustedContentInset.top)
    }

    private func heroTitleFrame(in collectionView: UICollectionView, at indexPath: IndexPath) -> CGRect? {
        guard let cell = collectionView.cellForItem(at: indexPath),
              let hero = Self.findHero(in: cell.contentView),
              hero.titleLabel.window != nil else { return nil }
        return hero.titleLabel.convert(hero.titleLabel.bounds, to: collectionView)
    }

    private static func findHero(in view: UIView) -> DetailHeroContentView? {
        if let hero = view as? DetailHeroContentView { return hero }
        for subview in view.subviews {
            if let hero = subview as? DetailHeroContentView { return hero }
        }
        return nil
    }
}
