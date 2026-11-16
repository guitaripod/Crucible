import CrucibleCore
import CrucibleDesign
import CrucibleIntelligence
import UIKit

/// The shared body of the movie, episode and show detail screens: a backdrop with scrims, a hero
/// block, the synopsis with More, an action row and the shelves below, driven by one
/// `TVDetailContent` value. Subclasses fetch and map their model, then call `present(_:)`.
///
/// The screen is a `TVScreenViewController`: the host owns the state view, the loading focus anchor,
/// identifier-keyed focus memory and task slots; Detail adds the backdrop and a skeleton for the
/// first load, and lays the collection out with its own sections.
///
/// Items carry only stable identities; their content is looked up from the current `TVDetailContent`
/// when a cell is configured, so a refresh after playback or a watched change reconfigures cells in
/// place and never moves the focus.
@MainActor
class TVDetailViewController: TVScreenViewController {
    enum Section: Int, Hashable, Sendable {
        case header
        case synopsis
        case actions
        case seasons
        case episodes
        case extras
        case cast
        case communityPulse
        case communityAspects
        case communityComments
        case related
        case information
    }

    enum Item: Hashable, Sendable {
        case header
        case synopsis
        case action(TVDetailAction.Kind)
        case season(String)
        case episode(String)
        case extra(String)
        case person(String)
        case related(String)
        case information
        case emptyEpisodes
        case episodePlaceholder(Int)
        case episodesFailed
        case communityPulse
        case communityAspect(String)
        case communityComment(Int)
        case communityAction(String)
    }

    static let heroHeight: CGFloat = 400

    let env: TVAppEnvironment
    private(set) var content: TVDetailContent?
    private(set) var hasContent = false

    private let backdrop = TVBackdropView()
    private let skeleton = TVDetailSkeletonView()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private lazy var loadSlot = makeTaskSlot()
    /// The title's Trakt community, once Trakt answered; the page shows it after Cast & Crew.
    private(set) var community: TraktCommunity.Snapshot?
    private var revealedComments = Set<Int>()
    private var communityBarsAnimated = false
    private lazy var communitySlot = makeTaskSlot()
    private var serverState: ServerStateFollower?
    nonisolated(unsafe) private var communityObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var communityProObserver: UUID?
    /// Removed in deinit, which runs off the main actor; NotificationCenter takes removals from any thread.
    nonisolated(unsafe) private var aspectTranslationObserver: (any NSObjectProtocol)?

    init(env: TVAppEnvironment) {
        self.env = env
        super.init(layout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func installViews() {
        super.installViews()
        [backdrop, skeleton].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        view.insertSubview(backdrop, at: 0)
        view.insertSubview(skeleton, aboveSubview: collectionView)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeleton.topAnchor.constraint(equalTo: view.topAnchor),
            skeleton.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            skeleton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        collectionView.collectionViewLayout = makeLayout()
        configureDataSource()
        adopt(dataSource)
        showLoading()
        serverState = ServerStateFollower(matching: { [weak self] change in
            guard let self else { return false }
            return change.touches(followedRatingKeys, sectionID: followedSectionID)
        }, isOnScreen: { [weak self] in
            self?.viewIfLoaded?.window != nil
        }, refresh: { [weak self] in
            self?.reload()
        })
        communityObserver = NotificationCenter.default.addObserver(forName: .traktCommunityChanged, object: nil, queue: .main) { [weak self] note in
            guard let change = note.object as? TraktCommunity.Change else { return }
            MainActor.assumeIsolated { self?.communityChanged(change) }
        }
        communityProObserver = ProAccess.shared.observe { [weak self] _ in self?.refreshCommunity() }
        aspectTranslationObserver = NotificationCenter.default.addObserver(forName: .translationChanged, object: nil, queue: .main) { [weak self] note in
            let key = note.object as? String
            MainActor.assumeIsolated {
                guard let self, key == nil || key?.hasPrefix(TraktSentimentsTranslation.prefix) == true, let sentiments = self.community?.sentiments else { return }
                self.reconfigureCommunity(sentiments.good.indices.map { Item.communityAspect("good.\($0)") } + sentiments.bad.indices.map { Item.communityAspect("bad.\($0)") })
            }
        }
    }

    deinit {
        if let communityObserver { NotificationCenter.default.removeObserver(communityObserver) }
        if let aspectTranslationObserver { NotificationCenter.default.removeObserver(aspectTranslationObserver) }
        if let communityProObserver { Task { @MainActor in ProAccess.shared.stopObserving(communityProObserver) } }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    func fetch() async {}

    /// The rating key whose Trakt community the page shows, or nil for a page without one.
    var communityKey: String? { nil }

    /// The titles the page shows: one finished, paused or marked on any device reads the page again while it is on screen.
    var followedRatingKeys: [String] { [] }

    /// The library whose new titles the page lists, for a page that lists a show's episodes.
    var followedSectionID: String? { nil }

    func didSelect(_ item: Item) {}

    func contextMenu(for item: Item) -> UIMenu? { nil }

    func retryEpisodes() {}

    /// Starts a fresh load, cancelling one in flight. While content is on screen it is refreshed in place.
    func reload() {
        loadSlot.run { [weak self] in
            await self?.fetch()
            self?.loadCommunity()
        }
    }

    func showLoading() {
        hasContent = false
        collectionView.isHidden = true
        stateView.isHidden = true
        skeleton.isHidden = false
    }

    func showUnavailable(_ message: String) {
        hasContent = false
        skeleton.isHidden = true
        show(state: .empty(
            title: String(localized: "Not Available"),
            message: message,
            symbol: "questionmark.circle",
            action: TVStateView.Action(title: String(localized: "Go Back")) { [weak self] in
                guard let self else { return }
                TVNavigation.pop(from: self)
            }
        ))
    }

    func showFailure(title: String, message: String) {
        hasContent = false
        skeleton.isHidden = true
        show(state: .error(title: title, message: message, retryTitle: String(localized: "Retry", comment: "Button that retries loading the screen")) { [weak self] in
            self?.showLoading()
            self?.reload()
        })
    }

    func itemIdentifier(at indexPath: IndexPath) -> Item? {
        dataSource.itemIdentifier(for: indexPath)
    }

    func push(_ route: DetailRoute) {
        TVNavigation.push(TVScreens.screen(for: route, env: env), from: self)
    }

    func play(_ request: TVPlaybackRequest) {
        TVDetailNavigation.play(request, env: env, from: self)
    }

    /// Marks `ratingKey` (a movie, episode, season or show) watched or unwatched, then refreshes the screen.
    func markWatched(_ watched: Bool, ratingKey: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await WatchedService.setWatched(watched, ratingKey: ratingKey, api: env.api)
                reload()
            } catch {
                presentAlert(title: String(localized: "Couldn\u{2019}t Update"), message: error.localizedDescription)
            }
        }
    }

    /// Opens the star rating panel for `title`; `onSet` gets the viewer's choice, nil to clear it.
    func presentRating(title: String, rating: UserRating?, onSet: @escaping (UserRating?) -> Void) {
        present(TVRatingViewController(title: title, rating: rating, onSet: onSet), animated: TVMotion.animationsEnabled)
    }

    func presentSynopsis() {
        guard let content, let text = content.synopsis else { return }
        present(TVSynopsisViewController(title: content.synopsisTitle, text: text), animated: TVMotion.animationsEnabled)
    }

    /// Shows `content`, reconfiguring the cells already on screen. The first content moves focus to
    /// the primary action when focus was on this screen's loading state; later refreshes leave focus
    /// where the viewer put it.
    func present(_ content: TVDetailContent) {
        self.content = content
        let replacesSkeleton = !hasContent && !skeleton.isHidden && view.window != nil
        hasContent = true
        if replacesSkeleton {
            fadeOutSkeleton()
        } else {
            skeleton.isHidden = true
        }
        backdrop.show(path: content.artwork.path, kind: content.artwork.isBackdrop ? .backdrop : .poster, immediate: true)
        applySnapshot(for: content)
        showContent()
    }

    /// Fades the loading skeleton out under the first content, the way tvOS dissolves a placeholder into the page.
    private func fadeOutSkeleton() {
        collectionView.alpha = 0
        TVMotion.animate(TVMetrics.Duration.fade, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.skeleton.alpha = 0
            self.collectionView.alpha = 1
        } completion: { _ in
            self.skeleton.alpha = 1
            if self.hasContent { self.skeleton.isHidden = true }
        }
    }

    /// Runs a refresh that adds what arrived after the page appeared (Trakt's scores on the meta line, a button) as a short cross-fade, so nothing
    /// jumps into place.
    func easeIn(_ refresh: @escaping () -> Void) {
        guard hasContent, TVMotion.animationsEnabled else { return refresh() }
        UIView.transition(with: collectionView, duration: 0.3, options: [.transitionCrossDissolve, .allowUserInteraction], animations: refresh)
    }

    override func initialFocusIndexPath() -> IndexPath? {
        let snapshot = dataSource.snapshot()
        let enabled = snapshot.itemIdentifiers(inSection: .actions).first { item in
            guard case .action(let kind) = item else { return false }
            return content?.actions.first { $0.kind == kind }?.isEnabled == true
        }
        guard let first = enabled ?? snapshot.itemIdentifiers(inSection: .seasons).first else { return nil }
        return dataSource.indexPath(for: first)
    }

    private func applySnapshot(for content: TVDetailContent) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.header])
        snapshot.appendItems([.header], toSection: .header)
        if !(content.synopsis ?? "").isEmpty {
            snapshot.appendSections([.synopsis])
            snapshot.appendItems([.synopsis], toSection: .synopsis)
        }
        snapshot.appendSections([.actions])
        snapshot.appendItems(content.actions.map { .action($0.kind) }, toSection: .actions)
        if !content.seasons.isEmpty {
            snapshot.appendSections([.seasons])
            snapshot.appendItems(Self.unique(content.seasons.map { .season($0.id) }), toSection: .seasons)
        }
        if content.showsEpisodes {
            snapshot.appendSections([.episodes])
            snapshot.appendItems(Self.episodeItems(for: content), toSection: .episodes)
        }
        if !content.extras.isEmpty {
            snapshot.appendSections([.extras])
            snapshot.appendItems(Self.unique(content.extras.map { .extra($0.id) }), toSection: .extras)
        }
        if !content.cast.isEmpty {
            snapshot.appendSections([.cast])
            snapshot.appendItems(Self.unique(content.cast.map { .person($0.id) }), toSection: .cast)
        }
        for (section, items) in communitySections() {
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
        }
        if !content.related.isEmpty {
            snapshot.appendSections([.related])
            snapshot.appendItems(Self.unique(content.related.map { .related($0.id) }), toSection: .related)
        }
        if !content.facts.isEmpty {
            snapshot.appendSections([.information])
            snapshot.appendItems([.information], toSection: .information)
        }
        dataSource.applyReconfiguringExisting(snapshot)
        refreshHeaders()
    }

    private static func episodeItems(for content: TVDetailContent) -> [Item] {
        switch content.episodesState {
        case .loading: (0 ..< 4).map { .episodePlaceholder($0) }
        case .failed: [.episodesFailed]
        case .loaded: content.episodes.isEmpty ? [.emptyEpisodes] : unique(content.episodes.map { .episode($0.id) })
        }
    }

    /// A diffable snapshot traps on a repeated identifier, so a server that lists an item twice shows it once.
    private static func unique(_ items: [Item]) -> [Item] {
        var seen = Set<Item>()
        return items.filter { seen.insert($0).inserted }
    }

    /// Headers are supplementary views, which a snapshot does not reconfigure, so a new season title
    /// or episode count is pushed into the ones already on screen.
    private func refreshHeaders() {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: TVShelf.headerKind) {
            (collectionView.supplementaryView(forElementKind: TVShelf.headerKind, at: indexPath) as? TVSectionHeaderView)?
                .configure(sectionHeader(at: indexPath))
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] index, _ in
            guard let section = self?.dataSource?.sectionIdentifier(for: index) else { return Self.block(top: 0, bottom: 0) }
            switch section {
            case .header: return TVShelf.hero(height: Self.heroHeight)
            case .synopsis: return Self.block(top: 0, bottom: TVMetrics.shelfTopInset)
            case .actions: return Self.actionRow()
            case .seasons: return TVShelf.chips()
            case .episodes, .extras: return TVShelf.episode()
            case .cast: return TVShelf.person()
            case .communityPulse: return Self.communityPulseSection(header: self?.communityHeadedSection == .communityPulse)
            case .communityAspects: return TVShelf.chips(header: self?.communityHeadedSection == .communityAspects)
            case .communityComments: return Self.communityCommentsSection(header: self?.communityHeadedSection == .communityComments)
            case .related: return TVShelf.poster()
            case .information: return Self.informationSection()
            }
        }
    }

    private static func block(top: CGFloat, bottom: CGFloat) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(160))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0)
        return section
    }

    private static func actionRow() -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .estimated(260), heightDimension: .absolute(TVMetrics.Control.primaryHeight))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = Theme.Space.m
        section.contentInsets = NSDirectionalEdgeInsets(
            top: TVMetrics.shelfTopInset,
            leading: 0,
            bottom: TVMetrics.shelfVerticalInset,
            trailing: 0
        )
        return section
    }

    private static func informationSection() -> NSCollectionLayoutSection {
        headedBlock()
    }

    /// A full-width block under a shelf title, as the ratings strip and the information panel are.
    private static func headedBlock() -> NSCollectionLayoutSection {
        let section = block(top: 0, bottom: TVMetrics.shelfTopInset)
        section.boundarySupplementaryItems = [
            NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(TVMetrics.shelfHeaderHeight)),
                elementKind: TVShelf.headerKind,
                alignment: .top
            ),
        ]
        return section
    }

    private func configureDataSource() {
        let hero = TVHeroCell.registration { [weak self] info in
            info.configure(self?.content?.header)
        }
        let synopsis = TVDetailSynopsisCell.registration(
            text: { [weak self] in self?.content?.synopsis },
            onMore: { [weak self] in self?.presentSynopsis() }
        )
        let action = TVDetailActionCell.registration { [weak self] kind in
            self?.content?.actions.first { $0.kind == kind }
        }
        let season = TVChipCell.registration { [weak self] chip in
            self?.didSelect(.season(chip.id))
        }
        let episode = TVEpisodeCell.registration()
        let person = TVDetailPersonCell.registration()
        let related = TVPosterCell.registration()
        let information = TVDetailInformationCell.registration { [weak self] in self?.content?.facts ?? [] }
        let placeholder = UICollectionView.CellRegistration<TVDetailEpisodePlaceholderCell, Int> { cell, _, index in
            cell.configure(index: index)
        }
        let failed = TVDetailEpisodesFailedCell.registration { [weak self] in self?.retryEpisodes() }
        let communityHost = UICollectionView.CellRegistration<TVHostCell, Item> { [weak self] cell, _, item in
            self?.configureCommunity(cell, item: item)
        }
        let aspect = TVChipCell.registration { [weak self] chip in self?.selectAspect(chip.id) }
        let empty = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, _ in
            var configuration = UIListContentConfiguration.cell()
            configuration.text = String(localized: "No episodes in this season")
            configuration.textProperties.font = Theme.Font.body
            configuration.textProperties.color = Theme.Color.labelSecondary
            cell.contentConfiguration = configuration
            cell.backgroundConfiguration = .clear()
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, item in
            let content = self?.content
            switch item {
            case .header:
                return collectionView.dequeueConfiguredReusableCell(using: hero, for: indexPath, item: 0)
            case .synopsis:
                return collectionView.dequeueConfiguredReusableCell(using: synopsis, for: indexPath, item: 0)
            case .action(let kind):
                return collectionView.dequeueConfiguredReusableCell(using: action, for: indexPath, item: kind)
            case .season(let id):
                let chip = content?.seasons.first { $0.id == id } ?? TVChipItem(id: id, title: "")
                return collectionView.dequeueConfiguredReusableCell(using: season, for: indexPath, item: chip)
            case .episode(let id):
                let card = content?.episodes.first { $0.id == id } ?? TVCardItem(id: id, title: "")
                return Self.identified(collectionView.dequeueConfiguredReusableCell(using: episode, for: indexPath, item: card), id)
            case .extra(let id):
                let card = content?.extras.first { $0.id == id } ?? TVCardItem(id: id, title: "")
                return Self.identified(collectionView.dequeueConfiguredReusableCell(using: episode, for: indexPath, item: card), id)
            case .person(let id):
                let model = content?.cast.first { $0.id == id } ?? TVDetailPerson(id: id, name: "")
                return Self.identified(collectionView.dequeueConfiguredReusableCell(using: person, for: indexPath, item: model), id)
            case .related(let id):
                let card = content?.related.first { $0.id == id } ?? TVCardItem(id: id, title: "")
                return Self.identified(collectionView.dequeueConfiguredReusableCell(using: related, for: indexPath, item: card), id)
            case .information:
                return collectionView.dequeueConfiguredReusableCell(using: information, for: indexPath, item: 0)
            case .emptyEpisodes:
                return collectionView.dequeueConfiguredReusableCell(using: empty, for: indexPath, item: 0)
            case .episodePlaceholder(let index):
                return collectionView.dequeueConfiguredReusableCell(using: placeholder, for: indexPath, item: index)
            case .episodesFailed:
                return collectionView.dequeueConfiguredReusableCell(using: failed, for: indexPath, item: 0)
            case .communityPulse, .communityComment, .communityAction:
                return collectionView.dequeueConfiguredReusableCell(using: communityHost, for: indexPath, item: item)
            case .communityAspect(let id):
                return collectionView.dequeueConfiguredReusableCell(using: aspect, for: indexPath, item: self?.aspectChip(id) ?? TVChipItem(id: id, title: ""))
            }
        }

        let header = TVSectionHeaderView.registration { [weak self] indexPath in
            self?.sectionHeader(at: indexPath)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private static func identified(_ cell: UICollectionViewCell, _ id: String) -> UICollectionViewCell {
        cell.accessibilityIdentifier = "detail.\(id)"
        return cell
    }

    private func sectionHeader(at indexPath: IndexPath) -> TVSectionHeader? {
        guard let section = dataSource.sectionIdentifier(for: indexPath.section) else { return nil }
        switch section {
        case .episodes: return content?.episodesHeader
        case .extras: return TVSectionHeader(title: DetailExtras.title)
        case .cast: return TVSectionHeader(title: String(localized: "Cast & Crew"))
        case .related: return TVSectionHeader(title: String(localized: "More Like This"))
        case .information: return TVSectionHeader(title: String(localized: "Information"))
        case .communityPulse, .communityAspects, .communityComments:
            return section == communityHeadedSection ? TVSectionHeader(title: TraktCommunityCopy.title) : nil
        default: return nil
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .episode, .extra, .related: true
        case .person(let id): content?.cast.first { $0.id == id }?.isOpenable ?? false
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        didSelect(item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return TVContextMenu.configuration(menu: contextMenu(for: item))
    }

    override func collectionView(
        _ collectionView: UICollectionView,
        didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.collectionView(collectionView, didUpdateFocusIn: context, with: coordinator)
        guard let next = context.nextFocusedIndexPath,
              let section = dataSource.sectionIdentifier(for: next.section),
              section == .synopsis || section == .actions
        else { return }
        coordinator.addCoordinatedAnimations({
            collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: -collectionView.adjustedContentInset.top)
        })
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        backdrop.dimming = scrollView.contentOffset.y / Self.heroHeight
    }

    // MARK: - Trakt community

    /// Loads the title's Trakt community after the page's own data, from the cache at once when it is fresh.
    private func loadCommunity() {
        guard let key = communityKey, TraktCommunity.shared.isAvailable else {
            if community != nil {
                community = nil
                refreshCommunity()
            }
            return
        }
        if community == nil, let cached = TraktCommunity.shared.cachedSnapshot(ratingKey: key) {
            community = cached
            communityBarsAnimated = true
            refreshCommunity()
        }
        let api = env.api
        communitySlot.run { [weak self] in
            let loaded = await TraktCommunity.shared.snapshot(ratingKey: key, api: api)
            guard let self, let loaded, loaded != self.community else { return }
            self.community = loaded
            self.refreshCommunity()
        }
    }

    private func refreshCommunity() {
        guard let content else { return }
        easeIn { self.applySnapshot(for: content) }
    }

    private func communityChanged(_ change: TraktCommunity.Change) {
        guard let current = community, let result = current.applying(change, isBlocked: TraktCommunity.shared.isBlocked) else { return }
        community = result.snapshot
        guard let content else { return }
        applySnapshot(for: content)
    }

    private var communityTitle: String { content?.header.title ?? "" }

    private var hasPulse: Bool {
        guard let community else { return false }
        return community.score != nil || community.distribution != nil || !(community.stats?.isEmpty ?? true) || !community.watching.isEmpty
    }

    /// The community's sections with their items, each only when it has something to show.
    private func communitySections() -> [(Section, [Item])] {
        guard let community, TraktCommunity.shared.isAvailable else { return [] }
        var sections: [(Section, [Item])] = []
        if hasPulse { sections.append((.communityPulse, [.communityPulse])) }
        if let sentiments = community.sentiments, !sentiments.isEmpty {
            let aspects = sentiments.good.indices.map { Item.communityAspect("good.\($0)") } + sentiments.bad.indices.map { Item.communityAspect("bad.\($0)") }
            sections.append((.communityAspects, aspects))
        }
        var cards: [Item]
        let unlocked = TraktCommunity.shared.isUnlocked
        if unlocked {
            cards = community.comments.map { .communityComment($0.id) }
            if community.commentCount > community.comments.count { cards.append(.communityAction("more")) }
        } else {
            cards = community.comments.prefix(TraktCommunity.freeCommentCount).map { .communityComment($0.id) }
            if community.commentCount > cards.count { cards.append(.communityAction("more")) }
        }
        cards.append(.communityAction("write"))
        sections.append((.communityComments, Self.unique(cards)))
        return sections
    }

    /// The first community section, which carries the Community heading.
    private var communityHeadedSection: Section? {
        communitySections().first?.0
    }

    private static func communityPulseSection(header: Bool) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(340))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.shelfTopInset, leading: 0, bottom: TVMetrics.shelfTopInset, trailing: 0)
        if header { section.boundarySupplementaryItems = [communityHeader()] }
        return section
    }

    private static func communityCommentsSection(header: Bool) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .absolute(TVCommentCardView.size.width), heightDimension: .absolute(TVCommentCardView.size.height))
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
        section.interGroupSpacing = TVMetrics.gutter
        section.contentInsets = NSDirectionalEdgeInsets(top: TVMetrics.shelfTopInset, leading: 0, bottom: TVMetrics.shelfBottomInset, trailing: 0)
        if header { section.boundarySupplementaryItems = [communityHeader()] }
        return section
    }

    private static func communityHeader() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(TVMetrics.shelfHeaderHeight)),
            elementKind: TVShelf.headerKind,
            alignment: .top
        )
    }

    private func aspect(_ id: String) -> TraktSentiments.Aspect? {
        guard let sentiments = community?.sentiments else { return nil }
        let parts = id.split(separator: ".")
        guard parts.count == 2, let index = Int(parts[1]) else { return nil }
        let list = parts[0] == "good" ? sentiments.good : sentiments.bad
        return list.indices.contains(index) ? list[index] : nil
    }

    private func aspectChip(_ id: String) -> TVChipItem {
        let good = id.hasPrefix("good.")
        let text = aspect(id).map(TraktSentimentsTranslation.text) ?? ""
        return TVChipItem(
            id: id,
            title: "\(good ? "\u{1F44D}" : "\u{1F44E}")  \(text)",
            accessibilityLabel: "\(good ? TraktCommunityCopy.theGood : TraktCommunityCopy.theBad), \(text)"
        )
    }

    private func selectAspect(_ id: String) {
        guard let aspect = aspect(id), let subject = community?.subject else { return }
        TVCommunityScreens.openAspect(aspect, on: subject, titleName: communityTitle, from: self)
    }

    /// Fills a community cell, updating the view it already hosts when it is the same card, so a refresh never takes the focus
    /// off a focused card.
    private func configureCommunity(_ cell: TVHostCell, item: Item) {
        guard let community else { return }
        switch item {
        case .communityPulse:
            let pulse: TVCommunityPulseView
            if let existing = cell.hosted as? TVCommunityPulseView {
                pulse = existing
            } else {
                pulse = TVCommunityPulseView()
                pulse.addAction(UIAction { [weak self] _ in
                    guard let self, let watching = self.community?.watching, !watching.isEmpty else { return }
                    TVCommunityScreens.openWatching(watching, titleName: self.communityTitle, from: self)
                }, for: .primaryActionTriggered)
                cell.host(pulse)
            }
            pulse.apply(community, animatesBars: !communityBarsAnimated)
            communityBarsAnimated = true
        case .communityComment(let id):
            guard let comment = community.comments.first(where: { $0.id == id }) else { return }
            let card: TVCommentCardView
            if let existing = cell.hosted as? TVCommentCardView, existing.commentID == id {
                card = existing
            } else {
                card = TVCommentCardView(commentID: id)
                card.addAction(UIAction { [weak self] _ in self?.selectComment(id) }, for: .primaryActionTriggered)
                card.contextMenuProvider = { [weak self] in
                    guard let self, let current = self.community?.comments.first(where: { $0.id == id }) else { return nil }
                    return TVCommunityScreens.menu(for: current, from: self)
                }
                cell.host(card)
            }
            let shared = TraktCommunity.shared
            card.apply(comment: comment, isRevealed: revealedComments.contains(id), isLiked: shared.isLiked(id), summary: shared.cachedSummary(id), mine: shared.reactions(of: id), isMine: shared.isMine(comment))
            guard shared.cachedSummary(id) == nil else { return }
            Task { [weak self] in
                guard await shared.summary(for: id) != nil, let self else { return }
                self.reconfigureCommunity([.communityComment(id)])
            }
        case .communityAction(let kind):
            let shown: TVCommunityActionCard.Kind
            if kind == "more" {
                shown = TraktCommunity.shared.isUnlocked ? .seeAll(community.commentCount) : .unlock(community.commentCount)
            } else {
                shown = .write
            }
            if let existing = cell.hosted as? TVCommunityActionCard, existing.slot == kind {
                existing.apply(shown)
            } else {
                let card = TVCommunityActionCard(shown)
                card.slot = kind
                card.addAction(UIAction { [weak self] _ in self?.selectCommunityAction(kind) }, for: .primaryActionTriggered)
                cell.host(card)
            }
        default:
            break
        }
    }

    private func reconfigureCommunity(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func selectComment(_ id: Int) {
        guard let comment = community?.comments.first(where: { $0.id == id }) else { return }
        if comment.isSpoiler || TraktCommentText(comment.text).hasInlineSpoilers, !revealedComments.contains(id) {
            revealedComments.insert(id)
            reconfigureCommunity([.communityComment(id)])
            return
        }
        let isFree = community?.comments.prefix(TraktCommunity.freeCommentCount).contains { $0.id == id } ?? false
        TVCommunityScreens.openThread(comment, subject: community?.subject, titleName: communityTitle, isFree: isFree, from: self)
    }

    private func selectCommunityAction(_ kind: String) {
        guard let subject = community?.subject else { return }
        switch kind {
        case "more":
            if TraktCommunity.shared.isUnlocked {
                TVCommunityScreens.openComments(on: subject, titleName: communityTitle, from: self)
            } else {
                ProAccess.shared.requestUnlock(.traktCommunity)
            }
        default:
            TVCommunityScreens.compose(.new(subject, titleName: communityTitle), from: self)
        }
    }
}
