@preconcurrency import UIKit

/// Home when the server can't be reached at launch but completed downloads exist: an offline
/// banner with Retry, a hero for the newest download and a rail of everything ready to watch.
final class OfflineHomeViewController: UICollectionViewController {
    private enum Section: Hashable {
        case banner, hero, ready, footer
    }

    private enum Item: Hashable {
        case banner
        case hero(String)
        case download(String)
        case footer
    }

    private let api: APIClient
    private let connection: PlexConnection
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var downloads: [String: DownloadItem] = [:]
    private var observerToken: UUID?
    private var playerCoordinator: PlayerCoordinator?

    init(api: APIClient, connection: PlexConnection) {
        self.api = api
        self.connection = connection
        super.init(collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observerToken {
            Task { @MainActor in DownloadManager.shared.removeObserver(observerToken) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.canvas
        collectionView.backgroundColor = Theme.Color.canvas
        configureNavItems()
        configureDataSource()
        collectionView.collectionViewLayout = createLayout()
        DownloadManager.shared.bootstrap()
        reload(animated: false)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        if observerToken == nil {
            observerToken = DownloadManager.shared.addObserver { [weak self] event in
                if case .progress = event { return }
                self?.reload(animated: true)
            }
        }
        reload(animated: false)
    }

    // MARK: - Navigation bar

    private func configureNavItems() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        let downloadsItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.down.circle"),
            primaryAction: UIAction { [weak self] _ in self?.openDownloads() }
        )
        downloadsItem.accessibilityLabel = "All Downloads"
        navigationItem.rightBarButtonItem = downloadsItem
    }

    private func openDownloads() {
        navigationController?.pushViewController(DownloadsViewController(api: api), animated: true)
    }

    private func retry() {
        Haptics.light()
        let scene = view.window?.windowScene?.delegate as? SceneDelegate
        dismiss(animated: true) {
            scene?.reconfigureRoot()
        }
    }

    // MARK: - Data

    /// Completed downloads, most recently finished first.
    private static func completedDownloads() -> [DownloadItem] {
        DownloadManager.shared.items
            .filter { $0.state == .completed }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
    }

    private func reload(animated: Bool) {
        let items = Self.completedDownloads()
        downloads = Dictionary(items.map { ($0.ratingKey, $0) }, uniquingKeysWith: { _, latest in latest })

        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if let newest = items.first {
            snapshot.appendSections([.banner, .hero, .ready, .footer])
            snapshot.appendItems([.banner], toSection: .banner)
            snapshot.appendItems([.hero(newest.ratingKey)], toSection: .hero)
            snapshot.appendItems(items.map { .download($0.ratingKey) }, toSection: .ready)
            snapshot.appendItems([.footer], toSection: .footer)
        }
        let current = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { current.indexOfItem($0) != nil })
        dataSource.apply(snapshot, animatingDifferences: animated && view.window != nil)
        updateEmptyState(isEmpty: items.isEmpty)
    }

    private func updateEmptyState(isEmpty: Bool) {
        guard isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "wifi.slash")
        config.text = "No Downloads"
        config.secondaryText = "You're offline and nothing is saved on this iPhone yet."
        config.button = ThemeButton.primaryConfiguration(title: "Retry")
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.retry() }
        contentUnavailableConfiguration = config
    }

    private func footerText() -> String {
        guard let snapshot = HomeSnapshotStore.loadSync(),
              snapshot.machineIdentifier == connection.machineIdentifier,
              snapshot.savedAt > 0 else { return connection.serverName }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let synced = Date(timeIntervalSince1970: TimeInterval(snapshot.savedAt))
        return "Last synced \(formatter.localizedString(for: synced, relativeTo: Date())) · \(connection.serverName)"
    }

    private static func subtitle(for item: DownloadItem) -> String? {
        let runtime = HomeFormat.runtime(item.durationSecs)
        if item.mediaType == "episode" {
            return HomeFormat.episodeLine(season: item.seasonNumber, episode: item.episodeNumber, tail: runtime)
        }
        return HomeFormat.joined([item.year.map(String.init), runtime])
    }

    // MARK: - Layout

    private func createLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self, let section = dataSource.snapshot().sectionIdentifiers[safe: sectionIndex] else { return nil }
            switch section {
            case .banner:
                return Self.fullWidthSection(estimatedHeight: 64, insets: NSDirectionalEdgeInsets(top: 6, leading: Theme.Space.m, bottom: 0, trailing: Theme.Space.m))
            case .hero:
                return Self.fullWidthSection(estimatedHeight: 220, insets: NSDirectionalEdgeInsets(top: Theme.Space.m, leading: Theme.Space.m, bottom: Theme.Space.xs, trailing: Theme.Space.m))
            case .footer:
                return Self.fullWidthSection(estimatedHeight: 32, insets: NSDirectionalEdgeInsets(top: Theme.Space.l, leading: Theme.Space.m, bottom: Theme.Space.l, trailing: Theme.Space.m))
            case .ready:
                return Self.railSection(hugeType: environment.traitCollection.preferredContentSizeCategory >= .accessibilityExtraLarge)
            }
        }
    }

    private static func fullWidthSection(estimatedHeight: CGFloat, insets: NSDirectionalEdgeInsets) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(estimatedHeight))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = insets
        return section
    }

    private static func railSection(hugeType: Bool) -> NSCollectionLayoutSection {
        let height = Theme.Size.posterRailWidth * Theme.Size.posterAspect + Theme.Size.captionBlockHeight
        let section: NSCollectionLayoutSection
        if hugeType {
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(0.5), heightDimension: .estimated(height)))
            let groupSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(height))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, repeatingSubitem: item, count: 2)
            group.interItemSpacing = .fixed(Theme.Space.s)
            section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = Theme.Space.m
        } else {
            let size = NSCollectionLayoutSize(widthDimension: .absolute(Theme.Size.posterRailWidth), heightDimension: .estimated(height))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
            section = NSCollectionLayoutSection(group: group)
            section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
            section.interGroupSpacing = Theme.Space.s
        }
        section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: Theme.Space.m, bottom: 0, trailing: Theme.Space.m)
        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(51))
        section.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top),
        ]
        return section
    }

    // MARK: - Cells

    private func configureDataSource() {
        let bannerReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            var config = OfflineBannerConfiguration()
            config.onRetry = { [weak self] in self?.retry() }
            cell.contentConfiguration = config
        }

        let heroReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, ratingKey in
            guard let self, let item = downloads[ratingKey] else { return }
            cell.contentConfiguration = heroConfiguration(for: item)
        }

        let posterReg = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, ratingKey in
            guard let item = self?.downloads[ratingKey] else { return }
            cell.contentConfiguration = OfflinePosterConfiguration(
                ratingKey: item.ratingKey,
                title: item.displayTitle,
                subtitle: Self.subtitle(for: item),
                placeholderIcon: item.mediaType == "episode" ? "tv" : "film"
            )
        }

        let footerReg = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            var config = UIListContentConfiguration.cell()
            config.text = self?.footerText()
            config.textProperties.alignment = .center
            config.textProperties.font = Theme.Font.caption1Regular
            config.textProperties.color = Theme.Color.labelTertiary
            config.directionalLayoutMargins = .zero
            cell.contentConfiguration = config
            cell.backgroundConfiguration = .clear()
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .banner:
                return collectionView.dequeueConfiguredReusableCell(using: bannerReg, for: indexPath, item: item)
            case .hero(let key):
                return collectionView.dequeueConfiguredReusableCell(using: heroReg, for: indexPath, item: key)
            case .download(let key):
                return collectionView.dequeueConfiguredReusableCell(using: posterReg, for: indexPath, item: key)
            case .footer:
                return collectionView.dequeueConfiguredReusableCell(using: footerReg, for: indexPath, item: item)
            }
        }

        let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewCell>(elementKind: UICollectionView.elementKindSectionHeader) { cell, _, _ in
            var config = SectionHeaderConfiguration()
            config.title = "Ready to Watch"
            cell.contentConfiguration = config
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
        }
    }

    private func heroConfiguration(for item: DownloadItem) -> HomeHeroConfiguration {
        var config = HomeHeroConfiguration()
        let ratingKey = item.ratingKey
        let resuming = item.resumeSecs > 0
        config.artwork = .offlinePoster(ratingKey)
        config.eyebrow = "Downloaded"
        config.title = item.displayTitle
        config.subtitle = Self.subtitle(for: item)
        config.actionTitle = resuming ? "Resume" : "Play"
        config.progress = resuming ? item.watchProgress : nil
        config.showsInfoButton = false
        config.minimumHeight = 220
        let episode = item.mediaType == "episode" ? HomeFormat.spokenEpisode(season: item.seasonNumber, episode: item.episodeNumber) : nil
        config.spokenLabel = ["\(config.actionTitle) \(item.displayTitle)", episode, "downloaded"]
            .compactMap { $0 }
            .joined(separator: ", ")
        config.onPrimary = { [weak self] in self?.play(ratingKey: ratingKey) }
        return config
    }

    // MARK: - Interaction

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .hero(let key), .download(let key):
            openDetail(ratingKey: key)
        default:
            break
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .hero, .download: return true
        default: return false
        }
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
              case .download(let key)? = dataSource.itemIdentifier(for: indexPath),
              let item = downloads[key] else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let play = UIAction(title: item.resumeSecs > 0 ? "Resume" : "Play", image: UIImage(systemName: "play.fill")) { _ in
                self?.play(ratingKey: key)
            }
            let details = UIAction(title: "View Details", image: UIImage(systemName: "info.circle")) { _ in
                self?.openDetail(ratingKey: key)
            }
            let remove = UIAction(title: "Remove Download", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                DownloadManager.shared.delete(key)
            }
            return UIMenu(children: [play, details, remove])
        })
    }

    private func openDetail(ratingKey: String) {
        guard let item = downloads[ratingKey] else { return }
        let detail = MediaDetailViewController(
            api: api,
            ratingKey: item.ratingKey,
            mediaType: item.mediaType,
            showRatingKey: item.grandparentRatingKey,
            seasonRatingKey: item.parentRatingKey
        )
        navigationController?.pushViewController(detail, animated: true)
    }

    /// Plays strictly from disk; a download whose files vanished reports that instead of
    /// attempting a stream the offline server can't serve.
    private func play(ratingKey: String) {
        guard let item = downloads[ratingKey] else { return }
        guard DownloadManager.shared.offlineAsset(for: ratingKey) != nil else {
            Haptics.error()
            let alert = UIAlertController(title: "File Missing", message: "This download could not be found on disk. Try downloading it again.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        Haptics.light()
        playerCoordinator = Theme.quickPlay(api: api, item: item.asPlexMetadata, from: self)
    }
}

/// The glass "Offline" notice with a Retry action.
struct OfflineBannerConfiguration: UIContentConfiguration, Hashable {
    var onRetry: (() -> Void)?

    static func == (lhs: OfflineBannerConfiguration, rhs: OfflineBannerConfiguration) -> Bool { true }
    func hash(into hasher: inout Hasher) {}

    func makeContentView() -> UIView & UIContentView {
        OfflineBannerContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> OfflineBannerConfiguration {
        self
    }
}

final class OfflineBannerContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { onRetry = (configuration as? OfflineBannerConfiguration)?.onRetry }
    }

    private var onRetry: (() -> Void)?

    init(configuration: OfflineBannerConfiguration) {
        self.configuration = configuration
        self.onRetry = configuration.onRetry
        super.init(frame: .zero)

        let glass = Glass.effectView(fallback: .systemThinMaterial)
        glass.layer.cornerRadius = 20
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true

        let glyph = UIImageView(image: UIImage(systemName: "wifi.slash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)))
        glyph.tintColor = Theme.Color.accentText
        glyph.contentMode = .center
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.isAccessibilityElement = false

        let titleLabel = UILabel()
        titleLabel.text = "Offline"
        titleLabel.font = Theme.Font.subheadlineSemibold
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label

        let detailLabel = UILabel()
        detailLabel.text = "Showing what's on this iPhone"
        detailLabel.font = Theme.Font.footnote
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.labelSecondary
        detailLabel.numberOfLines = 0

        let textStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 1
        textStack.isAccessibilityElement = true
        textStack.accessibilityLabel = "Offline. Showing what's on this iPhone"

        var retryConfig = UIButton.Configuration.filled()
        retryConfig.title = "Retry"
        retryConfig.baseBackgroundColor = Theme.Color.accentTint
        retryConfig.baseForegroundColor = Theme.Color.accentText
        retryConfig.cornerStyle = .capsule
        retryConfig.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        retryConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = Theme.Font.scaled(.subheadline, 14, .semibold, maximum: 22)
            return outgoing
        }
        let retryButton = ExpandedHitButton(configuration: retryConfig)
        retryButton.accessibilityHint = "Tries to reconnect to the server"
        retryButton.setContentHuggingPriority(.required, for: .horizontal)
        retryButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)

        let row = UIStackView(arrangedSubviews: [glyph, textStack, retryButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Space.s
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        glass.contentView.addSubview(row)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: Theme.Space.s),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -Theme.Space.s),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A downloaded title's poster, read from the copy saved beside the download so it renders offline.
struct OfflinePosterConfiguration: UIContentConfiguration, Hashable {
    var ratingKey: String
    var title: String
    var subtitle: String?
    var placeholderIcon: String = "film"

    func makeContentView() -> UIView & UIContentView {
        OfflinePosterContentView(configuration: self)
    }

    func updated(for state: UIConfigurationState) -> OfflinePosterConfiguration {
        self
    }
}

final class OfflinePosterContentView: UIView, UIContentView {
    var configuration: UIContentConfiguration {
        didSet { apply() }
    }

    private let cardView = UIView()
    private let imageView = UIImageView()
    private let placeholderView = UIImageView()
    private let downloadChip = Glass.effectView(fallback: .systemThinMaterialDark)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var imageTask: Task<Void, Never>?
    private var currentKey: String?

    init(configuration: OfflinePosterConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        setupViews()
        apply()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: OfflinePosterContentView, _: UITraitCollection) in
            view.updateLineLimits()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { imageTask?.cancel() }

    private func setupViews() {
        cardView.backgroundColor = Theme.Color.surfaceRaised
        cardView.layer.cornerRadius = Theme.Radius.s
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = Theme.Color.artHairline.cgColor
        cardView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true

        placeholderView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .light)
        placeholderView.tintColor = Theme.Color.labelTertiary
        placeholderView.contentMode = .center

        downloadChip.layer.cornerRadius = 12
        downloadChip.layer.cornerCurve = .continuous
        downloadChip.clipsToBounds = true
        let glyph = UIImageView(image: UIImage(systemName: "arrow.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)))
        glyph.tintColor = Theme.Color.onArt
        glyph.translatesAutoresizingMaskIntoConstraints = false
        downloadChip.contentView.addSubview(glyph)

        titleLabel.font = Theme.Font.caption1
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        subtitleLabel.font = Theme.Font.caption2Regular
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = Theme.Color.labelSecondary

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 1

        let mainStack = UIStackView(arrangedSubviews: [cardView, textStack])
        mainStack.axis = .vertical
        mainStack.spacing = 7
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        [imageView, placeholderView, downloadChip].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            cardView.addSubview($0)
        }

        let aspect = cardView.heightAnchor.constraint(equalTo: cardView.widthAnchor, multiplier: Theme.Size.posterAspect)
        aspect.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            aspect,

            imageView.topAnchor.constraint(equalTo: cardView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            placeholderView.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),

            downloadChip.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 7),
            downloadChip.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -7),
            downloadChip.widthAnchor.constraint(equalToConstant: 24),
            downloadChip.heightAnchor.constraint(equalToConstant: 24),
            glyph.centerXAnchor.constraint(equalTo: downloadChip.contentView.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: downloadChip.contentView.centerYAnchor),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        updateLineLimits()
    }

    private func updateLineLimits() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        titleLabel.numberOfLines = large ? 3 : 1
        subtitleLabel.numberOfLines = large ? 2 : 1
    }

    private func apply() {
        guard let config = configuration as? OfflinePosterConfiguration else { return }
        titleLabel.text = config.title
        subtitleLabel.text = config.subtitle
        subtitleLabel.isHidden = (config.subtitle ?? "").isEmpty
        accessibilityLabel = HomeFormat.joined([config.title, config.subtitle, "downloaded"])?
            .replacingOccurrences(of: " · ", with: ", ")

        guard config.ratingKey != currentKey else { return }
        currentKey = config.ratingKey
        imageTask?.cancel()
        imageView.image = nil
        placeholderView.image = UIImage(systemName: config.placeholderIcon)
        placeholderView.isHidden = false
        let key = config.ratingKey
        imageTask = Task { [weak self] in
            let image = await OfflinePoster.image(ratingKey: key)
            guard !Task.isCancelled, let self, let image else { return }
            self.placeholderView.isHidden = true
            self.imageView.image = image
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
